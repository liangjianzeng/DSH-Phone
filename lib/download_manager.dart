import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'tunnel_service.dart';

/// 下载状态。
///
/// [queued] 是新增态：原来跨任务**没有任何并发闸门**（唯一的守卫是 per-task 的
/// `_running`），连点几个产物就是 k×256MB 同时压在 Dart 堆上，而 Android 侧
/// 没有声明 `largeHeap`，直接 OOM 被系统杀（连带全内存缓冲一起丢）。
enum DownloadStatus {
  queued, // 已排队（等前面的任务让出并发位）
  downloading, // 下载中
  paused, // 已暂停（可断点续传）
  completed, // 已完成（字节数已与远端大小核对）
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
/// 数据先缓存在内存（分块列表），支持**会话内断点续传**：恢复时以"已落缓冲的
/// 真实字节数"为 offset 重新打开 SFTP 继续读取。完成时一次性取整字节供"另存为"。
///
/// 为什么偏移不能用库回报的进度值：dartssh2 的 `onProgress` 累加的是**向服务端
/// 请求的长度**（`bytessRecieved += chunkLength`），而 SFTP 允许一次 READ 短读；
/// 且 `add(chunk)` 之后才回调 onProgress，App 侧 `onData` 还要晚一个微任务。
/// 两种情况下"计数"都会领先真实缓冲区，用它续传就在文件中间**留洞**，而界面
/// 照样显示"下载完成"。所以：进度与续传偏移一律以缓冲区实际字节数为准。
class DownloadTask {
  DownloadTask({required this.remotePath, required this.fileName});

  /// 云端主机上的文件路径（归一化后的形式，同时用作任务表键）。
  final String remotePath;

  /// 展示用的文件名（路径最后一段）。
  final String fileName;

  /// 已下载并**确实进入缓冲区**的字节数（含续传前的部分）。
  int downloadedBytes = 0;

  /// 文件总字节数（打开后才知道，未知为 null）。
  int? totalBytes;

  /// 失败原因（status == failed 时）。
  String? error;

  /// 失败种类：界面据此给不同的下一步（重连隧道 / 换路径 / 换目录）。
  RemoteFailureKind? errorKind;

  DownloadStatus status = DownloadStatus.queued;

  /// 已完成时持有的完整字节（供"另存为"）。
  Uint8List? resultBytes;

  final List<Uint8List> _chunks = [];
  int _bufferedBytes = 0;
  StreamSubscription<Uint8List>? _sub;
  SftpFile? _file;
  SftpClient? _sftp;
  Timer? _idleTimer;

  /// 是否占用着并发位（由 [DownloadManager._active] 对照维护）。
  bool _activeInManager = false;

  /// 世代号：pause/cancel/restart 都会自增。所有异步回调（流数据、onDone、
  /// onError、看门狗）先比对世代号，不符就直接丢弃。
  ///
  /// 这解决三类静默损坏：① 在 `await openRemoteFile` 窗口里点"暂停"→ 旧实现把
  /// `_running` 置 false，于是"继续"又能开一条流，**两条流往同一个缓冲区写**；
  /// ② 点"取消"清了缓冲区，但在飞的那条流毫不知情继续写 → 最后 `completed`
  /// 存出一个只有尾包的坏文件；③ 传输静默丢包后 `_running` 恒真，把"重试"永久
  /// 挡在守卫外。
  int _generation = 0;

  /// 完成/取消的时刻，用于保留期回收。
  DateTime? _finishedAt;

  StreamController<DownloadStatus>? _statusCtl;
  StreamController<DownloadProgress>? _progressCtl;

  StreamController<DownloadStatus> get _statusSink =>
      _statusCtl ??= StreamController<DownloadStatus>.broadcast();
  StreamController<DownloadProgress> get _progressSink =>
      _progressCtl ??= StreamController<DownloadProgress>.broadcast();

  Stream<DownloadStatus> get statusStream => _statusSink.stream;
  Stream<DownloadProgress> get progressStream => _progressSink.stream;

  void _emitStatus(DownloadStatus s) {
    status = s;
    final ctl = _statusCtl;
    if (ctl != null && !ctl.isClosed) ctl.add(s);
  }

  void _emitProgress() {
    downloadedBytes = _bufferedBytes;
    final ctl = _progressCtl;
    if (ctl != null && !ctl.isClosed) {
      ctl.add(DownloadProgress(_bufferedBytes, totalBytes ?? 0));
    }
  }

  bool get _isTerminal =>
      status == DownloadStatus.completed || status == DownloadStatus.cancelled;

  void dispose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _sub?.cancel();
    _sub = null;
    _chunks.clear();
    _bufferedBytes = 0;
    resultBytes = null;
    _statusCtl?.close();
    _progressCtl?.close();
    _statusCtl = null;
    _progressCtl = null;
  }
}

/// 会话级下载管理器：负责打开 SFTP、分块读取、暂停/恢复/取消。
class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// 单任务最大下载量（256MB）：超过即中止并提示。
  /// 下载数据全量驻留内存（分块列表），移动端内存有限，
  /// 无上限会让大体积 APK/压缩包直接 OOM。
  static const int maxDownloadBytes = 256 * 1024 * 1024;

  /// 同时下载的任务数。SFTP 每条流占一条 SSH 会话通道，而远端 sshd 默认
  /// `MaxSessions=10`——预览、WebView 转发、上传都共用这份配额，这里必须留余量。
  static const int maxConcurrentDownloads = 2;

  /// 单个块之间允许的最大空闲：超过即判定"链路已死"。
  ///
  /// 原来只有"流报错"这一条出口：一旦几个在途 READ 的 reply 被静默丢弃，
  /// `scheduleRead` 不再被驱动，onDone/onError 都不触发 → 界面永久停在某个
  /// 百分比，而且 `_running` 恒真把"重试"也挡掉，用户只能取消重来。
  static const Duration readIdleTimeout = Duration(seconds: 30);

  /// 已完成后在任务表里保留多久（供"再点一次"直接复用字节，不再全量重下）。
  static const Duration completedRetention = Duration(minutes: 10);

  /// 最多保留几个已完成任务（内存保护，超出按时间淘汰）。
  static const int maxRetainedCompleted = 3;

  /// 以归一化路径为键，同一资源只保留一个任务。
  final Map<String, DownloadTask> _tasks = {};

  /// 正在传输中的任务（并发闸门计数）。
  final Set<DownloadTask> _active = {};

  /// 排队等待并发位的任务。
  final List<DownloadTask> _queue = [];

  /// 归一化任务键：同一物理文件常有 `E:\a\b.apk` / `E:/a/b.apk` /
  /// `/E:/a/b.apk` 三种写法，旧实现用原始字符串作键 → 同一文件两个任务、
  /// 两条 SFTP 会话、两份全量内存、两个"下载完成"弹窗。
  /// 只做分隔符与重复斜杠归一，**不折叠大小写**（Linux 上大小写敏感）。
  static String taskKeyOf(String path) {
    var k = path.replaceAll(r'\', '/');
    while (k.contains('//')) {
      k = k.replaceAll('//', '/');
    }
    if (k.length > 1 && k.endsWith('/')) k = k.substring(0, k.length - 1);
    return k;
  }

  /// 取路径最后一段作为文件名，兼容 `/` 与 `\` 分隔，并去掉 URL 的
  /// `?query` / `#fragment`（带签名串的链接另存时曾生成
  /// `app.apk?sign=xxx` 这种文件名，SAF 侧直接失败）。
  static String basename(String p) {
    var s = p;
    final q = s.indexOf(RegExp(r'[?#]'));
    if (q >= 0) s = s.substring(0, q);
    final norm = s.replaceAll(r'\', '/');
    final i = norm.lastIndexOf('/');
    final name = i >= 0 ? norm.substring(i + 1) : norm;
    return name.trim();
  }

  /// 以远端路径为键，同一资源只保留一个任务。
  ///
  /// 同步返回：界面拿到任务后立刻打开下载页，下载在后台进行——避免等待 SFTP
  /// 打开导致"点开灰屏/无反应"。重复点击**不再**"返回旧任务就什么都不做"：
  /// 失败→自动重试，暂停/排队→自动继续，下载中→继续看进度，已完成→直接复用
  /// 字节给"保存到…"（旧实现里 completed 已移出表，再点一次就是第二次全量下载）。
  DownloadTask start(String remotePath, {int? resumeOffset}) {
    final key = taskKeyOf(remotePath);
    final existing = _tasks[key];
    if (existing != null) {
      switch (existing.status) {
        case DownloadStatus.failed:
        case DownloadStatus.cancelled:
          retry(existing);
          break;
        case DownloadStatus.paused:
        case DownloadStatus.queued:
          resume(existing);
          break;
        case DownloadStatus.downloading:
        case DownloadStatus.completed:
          break;
      }
      return existing;
    }
    final task = DownloadTask(remotePath: key, fileName: basename(remotePath));
    _tasks[key] = task;
    _schedule(task, offset: resumeOffset ?? 0);
    return task;
  }

  void retry(DownloadTask task) {
    // 已拿到完整字节（完成时校验过大小）就不必再下一遍。
    if (task.resultBytes != null) {
      task._emitStatus(DownloadStatus.completed);
      return;
    }
    _schedule(task, offset: task._bufferedBytes);
  }

  /// 断点续传：从已落缓冲的真实偏移继续（暂停后调用）。
  void resume(DownloadTask task) {
    if (task._isTerminal) return;
    _schedule(task, offset: task._bufferedBytes);
  }

  /// 暂停：取消当前流并关闭句柄，记录已下载量，可恢复。
  void pause(DownloadTask task) {
    _stopStream(task, reason: 'pause');
    if (task._isTerminal) return;
    task._emitStatus(DownloadStatus.paused);
    _pump();
  }

  /// 取消：作废在途流、清空缓冲区并移出任务表。
  ///
  /// 旧实现只清缓冲不**作废**在途流：那条流继续往"已清空"的缓冲里写，最后
  /// `completed`，用户存出一个只有尾包的坏文件——取消语义完全失效。现在世代号
  /// 先自增，所有回调立刻失配作废。
  void cancel(DownloadTask task) {
    _stopStream(task, reason: 'cancel');
    _queue.remove(task);
    task._chunks.clear();
    task._bufferedBytes = 0;
    task.downloadedBytes = 0;
    task.totalBytes = null;
    task.resultBytes = null;
    _tasks.remove(taskKeyOf(task.remotePath));
    task._emitStatus(DownloadStatus.cancelled);
    task._finishedAt = DateTime.now();
    _pump();
  }

  /// 排队：超过并发上限的任务先进 [DownloadStatus.queued]。
  void _schedule(DownloadTask task, {required int offset}) {
    task.error = null;
    task.errorKind = null;
    _queue.remove(task);
    if (_active.length >= maxConcurrentDownloads) {
      if (task.status != DownloadStatus.downloading) {
        task._emitStatus(DownloadStatus.queued);
      }
      _queue.add(task);
      return;
    }
    _active.add(task);
    unawaited(_run(task, offset: offset));
  }

  /// 有任务结束后，从队列里补位。
  void _pump() {
    while (_active.length < maxConcurrentDownloads && _queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      if (next._isTerminal) continue;
      _active.add(next);
      unawaited(_run(next, offset: next._bufferedBytes));
    }
  }

  /// 结束本次传输：自增世代号（作废一切在途回调）、取消订阅、关句柄与会话。
  void _stopStream(DownloadTask task, {required String reason}) {
    task._generation++;
    task._idleTimer?.cancel();
    task._idleTimer = null;
    final sub = task._sub;
    task._sub = null;
    unawaited(sub?.cancel());
    final file = task._file;
    final sftp = task._sftp;
    task._file = null;
    task._sftp = null;
    if (task._activeInManager) {
      _active.remove(task);
      task._activeInManager = false;
    }
    if (file != null || sftp != null) {
      debugPrint('[DSH] download stop stream ($reason) ${task.remotePath}');
      unawaited(TunnelService.instance
          .closeRemoteFile(file: file, sftp: sftp)
          .catchError((Object e) {
        debugPrint('[DSH] download close ignored: $e');
      }));
    }
  }

  /// 断点续传：以 [offset] 重新打开 SFTP，从该偏移继续读取。
  Future<void> _run(DownloadTask task, {required int offset}) async {
    final generation = ++task._generation;
    task._activeInManager = true;
    // 续传前的一致性自检：偏移必须等于缓冲区字节数，否则本次写入会接不上。
    if (offset != task._bufferedBytes) {
      debugPrint('[DSH] download offset mismatch for ${task.remotePath}: '
          'request=$offset buffered=${task._bufferedBytes} → 从缓冲区长度续传');
      offset = task._bufferedBytes;
    }
    task._emitStatus(DownloadStatus.downloading);

    final opened =
        await TunnelService.instance.openRemoteFileDetailed(task.remotePath);
    if (!_isCurrent(task, generation)) {
      // 期间被暂停/取消：句柄可能是刚迟到的成功结果，必须就地回收。
      unawaited(TunnelService.instance
          .closeRemoteFile(file: opened.file, sftp: opened.sftp));
      _finishActive(task);
      _pump();
      return;
    }
    final file = opened.file;
    if (file == null) {
      task.error = opened.reason ?? '无法打开云端文件';
      task.errorKind = opened.kind;
      task._emitStatus(DownloadStatus.failed);
      _finishActive(task);
      _pump();
      return;
    }
    try {
      task._file = file;
      task._sftp = opened.sftp;
      task.totalBytes = opened.size;
      if (task.totalBytes != null && task.totalBytes! > maxDownloadBytes) {
        task.error = '文件过大（超过 ${maxDownloadBytes ~/ (1024 * 1024)}MB），'
            '当前下载方式仅支持内存缓存，无法保存超大文件';
        task.errorKind = RemoteFailureKind.tooLarge;
        _stopStream(task, reason: 'too large');
        task._emitStatus(DownloadStatus.failed);
        _pump();
        return;
      }
      // 0 字节 / 目录（目录已在 openRemoteFileDetailed 挡掉）不再谎报"完成"。
      if (task.totalBytes != null && task.totalBytes == 0) {
        _stopStream(task, reason: 'empty');
        task.error = '云端文件是 0 字节，没有可保存的内容';
        task.errorKind = RemoteFailureKind.notFound;
        task._emitStatus(DownloadStatus.failed);
        _pump();
        return;
      }
      // onProgress 的 bytesRead 是相对本次读取起点（offset）的，界面总进度
      // = offset + bytesRead。
      final stream = file.read(
        offset: offset,
        onProgress: (bytesRead) {
          if (!_isCurrent(task, generation)) return;
          task._emitProgress();
        },
      );
      task._sub = stream.listen(
        (chunk) {
          if (!_isCurrent(task, generation)) return;
          // 分块累计超限：中止下载并释放资源（内存保护）
          if (task._bufferedBytes + chunk.length > maxDownloadBytes) {
            task.error =
                '文件过大（超过 ${maxDownloadBytes ~/ (1024 * 1024)}MB），已中止下载';
            task.errorKind = RemoteFailureKind.tooLarge;
            _stopStream(task, reason: 'over limit');
            task._emitStatus(DownloadStatus.failed);
            _pump();
            return;
          }
          task._chunks.add(chunk);
          task._bufferedBytes += chunk.length;
          task._emitProgress();
          _armIdleWatchdog(task, generation);
        },
        onDone: () async {
          if (!_isCurrent(task, generation)) return;
          _stopStream(task, reason: 'done');
          final got = task._bufferedBytes;
          final want = task.totalBytes;
          // 完成判定必须校验字节数：`onDone` 只代表"SFTP 流正常收尾"，不代表
          // 字节到齐。服务端提前 EOF、远端文件被截断、短读都会走进这里，
          // 旧实现无条件 completed → 用户存出一个截断的 apk/zip 还毫不知情。
          if (want != null && want > 0 && got != want) {
            task.error = '下载不完整（$got/$want 字节），可点"重试"从断点继续';
            task.errorKind = RemoteFailureKind.other;
            task._emitStatus(DownloadStatus.failed);
            _pump();
            return;
          }
          final bytes = Uint8List(got);
          var pos = 0;
          for (final c in task._chunks) {
            bytes.setRange(pos, pos + c.length, c);
            pos += c.length;
          }
          task._chunks.clear();
          task.resultBytes = bytes;
          task.downloadedBytes = got;
          task._emitStatus(DownloadStatus.completed);
          _retainCompleted(task);
          _pump();
        },
        onError: (Object e) {
          if (!_isCurrent(task, generation)) return;
          _stopStream(task, reason: 'stream error');
          task.error = _readableDownloadError(e);
          task.errorKind = _kindOfDownloadError(e);
          task._emitStatus(DownloadStatus.failed);
          _pump();
        },
        cancelOnError: true,
      );
      _armIdleWatchdog(task, generation);
    } catch (e) {
      if (!_isCurrent(task, generation)) return;
      _stopStream(task, reason: 'setup error');
      task.error = _readableDownloadError(e);
      task.errorKind = _kindOfDownloadError(e);
      task._emitStatus(DownloadStatus.failed);
      _pump();
    }
  }

  /// 本次回调是否仍属于当前世代（世代不符 = 已被暂停/取消/重开，一律作废）。
  bool _isCurrent(DownloadTask task, int generation) =>
      task._generation == generation;

  void _finishActive(DownloadTask task) {
    _active.remove(task);
    task._activeInManager = false;
  }

  void _armIdleWatchdog(DownloadTask task, int generation) {
    task._idleTimer?.cancel();
    task._idleTimer = Timer(readIdleTimeout, () {
      if (!_isCurrent(task, generation)) return;
      debugPrint('[DSH] download idle timeout for ${task.remotePath} '
          '(${task._bufferedBytes}/${task.totalBytes ?? '?'} bytes)');
      _stopStream(task, reason: 'idle timeout');
      task.error = '传输停滞：${readIdleTimeout.inSeconds} 秒没有收到数据'
          '（链路可能已半开），可点"重试"从断点继续';
      task.errorKind = RemoteFailureKind.timeout;
      task._emitStatus(DownloadStatus.failed);
      _pump();
    });
  }

  /// 已完成任务保留一段时间：再点一次直接复用字节，不再全量重下。
  void _retainCompleted(DownloadTask task) {
    task._finishedAt = DateTime.now();
    final done = _tasks.values
        .where((t) => t.status == DownloadStatus.completed && t._finishedAt != null)
        .toList(growable: false)
      ..sort((a, b) => a._finishedAt!.compareTo(b._finishedAt!));
    while (done.length > maxRetainedCompleted) {
      final oldest = done.removeAt(0);
      _tasks.remove(taskKeyOf(oldest.remotePath));
      oldest.dispose();
    }
  }

  static String _readableDownloadError(Object e) {
    final s = '$e';
    if (s.contains('SftpAbortError') || s.contains('Connection closed')) {
      return 'SSH 会话已关闭（隧道可能重连过），可点"重试"从断点继续';
    }
    if (s.contains('MaxSessions') ||
        s.contains('Channel open failure') ||
        s.contains('channel open failed')) {
      return '云端拒绝新开 SSH 通道（并发会话已满），请稍后重试或减少同时下载数';
    }
    return s;
  }

  static RemoteFailureKind _kindOfDownloadError(Object e) {
    final s = '$e';
    if (s.contains('Timeout') || s.contains('timed out')) {
      return RemoteFailureKind.timeout;
    }
    if (s.contains('MaxSessions') || s.contains('Channel open')) {
      return RemoteFailureKind.channelExhausted;
    }
    if (s.contains('SftpAbortError') ||
        s.contains('Connection closed') ||
        s.contains('connection lost')) {
      return RemoteFailureKind.notConnected;
    }
    return RemoteFailureKind.other;
  }

  /// 仅供测试/调试：清空会话级状态。
  void clearForTest() {
    for (final t in _tasks.values.toList(growable: false)) {
      _stopStream(t, reason: 'clear');
      t.dispose();
    }
    _tasks.clear();
    _queue.clear();
    _active.clear();
  }
}
