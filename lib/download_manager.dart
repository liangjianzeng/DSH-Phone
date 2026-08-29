import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'tunnel_service.dart';

/// 下载状态。
enum DownloadStatus {
  downloading, // 下载中
  paused, // 已暂停（可断点续传）
  completed, // 已完成
  failed, // 失败（可重试）
  cancelled, // 已取消
}

/// 下载进度快照（用于界面展示）。
class DownloadProgress {
  const DownloadProgress(this.downloaded, this.total);

  /// 已下载字节数（含断点续传前的部分）。
  final int downloaded;

  /// 文件总字节数（未知时为 0）。
  final int total;

  double get fraction => total <= 0 ? 0 : (downloaded / total).clamp(0.0, 1.0);
}

/// 会话级下载任务：一个资源对应一个任务。
///
/// 数据先缓存在内存（BytesBuilder），支持**会话内断点续传**：
/// 暂停时记下已下载量，恢复时以该 offset 重新打开 SFTP 继续读取，
/// 追加到已有缓冲区。完成时一次性取整字节供"另存为"。
///
/// 注意：全内存缓存的代价是超大文件会耗尽内存，故 [DownloadManager]
/// 对单任务下载量设上限（[DownloadManager.maxDownloadBytes]），
/// 超限即中止并提示，避免移动端 OOM 崩溃。
class DownloadTask {
  DownloadTask({required this.remotePath, required this.fileName});

  /// 云端主机上的文件路径。
  final String remotePath;

  /// 展示用的文件名（路径最后一段）。
  final String fileName;

  /// 已下载字节数（含续传前部分）。
  int downloadedBytes = 0;

  /// 文件总字节数（打开后才知道，未知为 null）。
  int? totalBytes;

  /// 失败原因（status == failed 时）。
  String? error;

  DownloadStatus status = DownloadStatus.downloading;

  /// 已完成时持有的完整字节（供"另存为"）。
  Uint8List? resultBytes;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  SftpFile? _file;

  /// 是否正在下载：防止 resume/retry 并发重复打开 SFTP 流，
  /// 导致同一段数据重复追加进缓冲区。
  bool _running = false;

  final StreamController<DownloadStatus> _statusCtl =
      StreamController<DownloadStatus>.broadcast();
  final StreamController<DownloadProgress> _progressCtl =
      StreamController<DownloadProgress>.broadcast();

  Stream<DownloadStatus> get statusStream => _statusCtl.stream;
  Stream<DownloadProgress> get progressStream => _progressCtl.stream;

  void _emitStatus(DownloadStatus s) {
    status = s;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  void _emitProgress(int downloaded, int? total) {
    downloadedBytes = downloaded;
    if (!_progressCtl.isClosed) {
      _progressCtl.add(DownloadProgress(downloaded, total ?? 0));
    }
  }

  void dispose() {
    _statusCtl.close();
    _progressCtl.close();
  }
}

/// 会话级下载管理器：负责打开 SFTP、分块读取、暂停/恢复/取消。
class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// 单任务最大下载量（256MB）：超过即中止并提示。
  /// 下载数据全量驻留内存（BytesBuilder），移动端内存有限，
  /// 无上限会让大体积 APK/压缩包直接 OOM。
  static const int maxDownloadBytes = 256 * 1024 * 1024;

  /// 以远端路径为键，同一资源只保留一个任务。
  final Map<String, DownloadTask> _tasks = {};

  /// 已有任务则直接返回（幂等），否则创建并立即开始下载。
  ///
  /// 同步返回：界面拿到任务后立刻打开下载页，下载在后台进行，
  /// 进度/状态通过 task 的流通知界面——避免等待 SFTP 打开导致"点开灰屏/无反应"。
  DownloadTask start(String remotePath, {int? resumeOffset}) {
    final existing = _tasks[remotePath];
    if (existing != null) {
      // 上次失败的任务会滞留任务表：再次点击同一资源时自动重试，
      // 避免用户"点一下没反应、还是失败状态"。
      if (existing.status == DownloadStatus.failed) {
        retry(existing);
      }
      return existing;
    }
    final task = DownloadTask(
      remotePath: remotePath,
      fileName: _basename(remotePath),
    );
    _tasks[remotePath] = task;
    _run(task, offset: resumeOffset ?? 0); // 后台启动，不阻塞返回
    return task;
  }

  void retry(DownloadTask task) {
    _run(task, offset: task.downloadedBytes);
  }

  /// 断点续传：从已下载偏移继续（暂停后调用）。
  void resume(DownloadTask task) {
    _run(task, offset: task.downloadedBytes);
  }

  /// 暂停：取消当前流并关闭句柄，记录已下载量，可恢复。
  void pause(DownloadTask task) {
    task._running = false;
    task._sub?.cancel();
    task._sub = null;
    task._file?.close();
    task._file = null;
    task._emitStatus(DownloadStatus.paused);
  }

  /// 取消：暂停并清空缓冲区，任务进入 cancelled，并从任务表移除
  /// （否则下次点击同一资源会拿到"死任务"，无法重新下载）。
  void cancel(DownloadTask task) {
    pause(task);
    task._buffer.clear();
    task.downloadedBytes = 0;
    task.totalBytes = null;
    task.resultBytes = null;
    _release(task);
    task._emitStatus(DownloadStatus.cancelled);
  }

  /// 从任务表释放：completed / cancelled 的任务不再持有全量字节，
  /// 防止 `_tasks` 随会话增长造成内存滞留。
  void _release(DownloadTask task) {
    _tasks.remove(task.remotePath);
  }

  /// 断点续传：以 [offset] 重新打开 SFTP，从该偏移继续读取。
  Future<void> _run(DownloadTask task, {required int offset}) async {
    // 并发守卫：任务已在下载中时，忽略重复的 resume/retry/start，
    // 避免并发打开多条 SFTP 流导致缓冲区重复数据。
    if (task._running) return;
    task._running = true;
    task._emitStatus(DownloadStatus.downloading);
    final file = await TunnelService.instance.openRemoteFile(task.remotePath);
    if (file == null) {
      task._running = false;
      task.error = '无法打开云端文件（隧道可能未连接）';
      task._emitStatus(DownloadStatus.failed);
      return;
    }
    try {
      final attrs = await file.stat();
      task.totalBytes = attrs.size ?? 0;
      task._file = file;
      // 已知文件大小超限：直接中止，避免下载到一半才失败。
      // （totalBytes 为 0 表示未知大小，仍需在分块时实时检查。）
      if (task.totalBytes != null && task.totalBytes! > maxDownloadBytes) {
        task._running = false;
        await file.close();
        task._file = null;
        task.error = '文件过大（超过 ${maxDownloadBytes ~/ (1024 * 1024)}MB），'
            '当前下载方式仅支持内存缓存，无法保存超大文件';
        task._emitStatus(DownloadStatus.failed);
        return;
      }
      // onProgress 的 bytesRead 是相对本次读取起点（offset）的，
      // 界面总进度 = offset + bytesRead。
      final stream = file.read(
        offset: offset,
        onProgress: (bytesRead) =>
            task._emitProgress(offset + bytesRead, task.totalBytes),
      );
      task._sub = stream.listen(
        (chunk) {
          // 分块累计超限：中止下载并释放资源（内存保护）
          if (task._buffer.length + chunk.length > maxDownloadBytes) {
            task._running = false;
            task._sub?.cancel();
            task._sub = null;
            task._file?.close();
            task._file = null;
            task.error = '文件过大（超过 ${maxDownloadBytes ~/ (1024 * 1024)}MB），'
                '已中止下载';
            task._emitStatus(DownloadStatus.failed);
            return;
          }
          task._buffer.add(chunk);
        },
        onDone: () async {
          task._running = false;
          await file.close();
          task._file = null;
          task._sub = null;
          task.resultBytes = task._buffer.takeBytes();
          task.downloadedBytes = task.resultBytes?.length ?? 0;
          // 完成后释放任务表条目：不再持有全量字节，防内存滞留
          _release(task);
          task._emitStatus(DownloadStatus.completed);
        },
        onError: (Object e) {
          task._running = false;
          task.error = '$e';
          task._file = null;
          task._sub = null;
          file.close();
          task._emitStatus(DownloadStatus.failed);
        },
        cancelOnError: true,
      );
    } catch (e) {
      task._running = false;
      task.error = '$e';
      file.close();
      task._emitStatus(DownloadStatus.failed);
    }
  }

  /// 取路径最后一段作为文件名，兼容 `/` 与 `\` 分隔。
  static String _basename(String p) {
    final norm = p.replaceAll(r'\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : norm;
  }
}
