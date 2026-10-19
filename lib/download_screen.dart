import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'download_manager.dart';
import 'download_name.dart';
import 'tunnel_service.dart';

/// 资源下载页：展示进度，支持暂停/恢复（断点续传）/取消/重试，
/// 下载完成后引导用户选择保存位置（SAF 另存为）。
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key, required this.task});

  final DownloadTask task;

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  DownloadProgress? _progress;
  bool _saving = false;
  String? _savedPath;

  /// 流订阅必须保存并在 dispose 里取消：旧实现两次 `listen` 都没留句柄，
  /// `dispose()` 只调了 `super.dispose()` → broadcast controller → 闭包 →
  /// State → BuildContext 整条链常驻，长会话内存单调增长；再叠加"同一任务
  /// 被多次点开"时 N 个页面各挂一份订阅，完成时弹 N 个对话框。
  StreamSubscription<DownloadProgress>? _progressSub;
  StreamSubscription<DownloadStatus>? _statusSub;

  /// 保存用文件名：下载完成后一次性生成（原名 + 时间戳 MD5 后 6 位），
  /// 弹窗提示与实际保存保持同名。
  String? _saveFileName;

  DownloadTask get _task => widget.task;

  /// 保存文件名：完成后首次生成后缀，之后保持不变。
  String get _effectiveSaveFileName =>
      _saveFileName ??= applyTimestampSuffix(_task.fileName);

  @override
  void initState() {
    super.initState();
    _progress = DownloadProgress(
      _task.downloadedBytes,
      _task.totalBytes ?? 0,
    );
    _progressSub = _task.progressStream.listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
    });
    _statusSub = _task.statusStream.listen((s) {
      if (!mounted) return;
      setState(() {});
      // 下载完成：生成带时间戳指纹的保存文件名，提示用户选择保存位置
      if (s == DownloadStatus.completed) {
        _saveFileName ??= applyTimestampSuffix(_task.fileName);
        _promptSave();
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _statusSub?.cancel();
    _progressSub = null;
    _statusSub = null;
    // 注意：不在这里 `task.dispose()`——任务可能仍在后台下载，或完成后还要
    // 让用户再次点"保存到…"；它的生命周期由 DownloadManager（含保留期淘汰）负责。
    super.dispose();
  }

  String _statusText(DownloadStatus s) {
    return switch (s) {
      DownloadStatus.queued => '排队等待中…',
      DownloadStatus.downloading => '下载中…',
      DownloadStatus.paused => '已暂停（支持断点续传）',
      DownloadStatus.completed => '下载完成',
      DownloadStatus.failed => '下载失败',
      DownloadStatus.cancelled => '已取消',
    };
  }

  String _sizeText(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  /// 下载完成：弹窗提示用户选择保存位置。
  void _promptSave() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载完成'),
        content: Text('$_effectiveSaveFileName 已下载，选择保存位置？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _save();
            },
            child: const Text('保存到…'),
          ),
        ],
      ),
    );
  }

  /// 通过系统文件选择器（SAF）另存为。
  Future<void> _save() async {
    if (_saving) return;
    final bytes = _task.resultBytes;
    if (bytes == null) {
      // 旧实现在这里静默 return：字节被"取消"清空而状态仍是 completed 时，
      // 用户点"保存到…"毫无反应，像 App 卡死。
      _toast('没有可保存的数据，请重新下载');
      return;
    }
    if (bytes.isEmpty) {
      // 绝不写 0 字节文件还提示"已保存成功"（旧路径：读取失败 → 回落空内容 →
      // SAF 建了个空文档 → toast 成功，用户拿到坏文件毫不知情）。
      _toast('文件内容为空（0 字节），未保存');
      return;
    }
    setState(() => _saving = true);
    try {
      final path = await FilePicker.platform.saveFile(
        fileName: _effectiveSaveFileName,
        bytes: bytes,
      );
      if (!mounted) return;
      if (path == null) {
        // 用户在系统面板里取消 / 拒绝权限：旧实现什么都不说，界面像没反应。
        _toast('已取消保存');
        return;
      }
      setState(() => _savedPath = path);
      // 插件在 Android 上返回的是**拼出来的** `Download/文件名`，并不等于真实
      // 位置（用户可能存到了文档/SD 卡/云盘）。这里不再假装是绝对路径。
      _toast('已保存：$_effectiveSaveFileName（具体位置以系统文件选择器为准）');
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 失败种类 → 下一步建议。旧实现把所有失败都说成"隧道可能未连接"，
  /// 用户于是反复重连隧道，而真因往往是路径不存在 / 是目录 / 并发通道已满。
  String? _kindHint(RemoteFailureKind? kind) {
    return switch (kind) {
      RemoteFailureKind.notConnected => '请先在设置里连上 SSH 隧道，再重试',
      RemoteFailureKind.notFound => '路径可能在产物被清理后失效，回到对话重新点一次',
      RemoteFailureKind.isDirectory => '这是一个目录，请点开目录里的具体文件',
      RemoteFailureKind.permission => '云端账号对该路径没有读权限',
      RemoteFailureKind.timeout => '网络/隧道不稳定，可点"重试"从断点继续',
      RemoteFailureKind.tooLarge => '该文件超出内存下载上限，建议在电脑端取',
      RemoteFailureKind.channelExhausted => '云端 SSH 并发通道已满，稍等半分钟再试',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _progress;
    final frac = p?.fraction ?? 0.0;
    final total = p?.total ?? _task.totalBytes ?? 0;
    final status = _task.status;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: Text(_task.fileName)),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(_statusText(status),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            LinearProgressIndicator(
              // 大小未知时走 indeterminate。旧实现传的是恒非 null 的 frac，
              // 于是"根本没开始传"和"传到 0%"长得一样，用户无从判断是否卡死。
              value: total > 0
                  ? frac
                  : (status == DownloadStatus.downloading ? null : 0.0),
            ),
            const SizedBox(height: 12),
            Text(
              '${_sizeText(p?.downloaded ?? 0)} / ${_sizeText(total)}'
              '${total > 0 ? '  (${(frac * 100).toStringAsFixed(1)}%)' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            if (status == DownloadStatus.failed && _task.error != null) ...[
              const SizedBox(height: 12),
              Text('错误：${_task.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
              if (_kindHint(_task.errorKind) != null) ...[
                const SizedBox(height: 6),
                Text(_kindHint(_task.errorKind)!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ],
            const Spacer(),
            _buildActions(status),
            const SizedBox(height: 8),
            if (_savedPath != null)
              Text(
                '已保存：$_effectiveSaveFileName（位置以系统文件选择器为准）',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.green, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  /// 按状态渲染操作按钮。
  Widget _buildActions(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.queued => Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DownloadManager.instance.cancel(_task),
                icon: const Icon(Icons.close),
                label: const Text('取消排队'),
              ),
            ),
          ],
        ),
      DownloadStatus.downloading => Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DownloadManager.instance.pause(_task),
                icon: const Icon(Icons.pause),
                label: const Text('暂停'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DownloadManager.instance.cancel(_task),
                icon: const Icon(Icons.close),
                label: const Text('取消'),
              ),
            ),
          ],
        ),
      DownloadStatus.paused => Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => DownloadManager.instance.resume(_task),
                icon: const Icon(Icons.play_arrow),
                label: const Text('继续'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DownloadManager.instance.cancel(_task),
                icon: const Icon(Icons.close),
                label: const Text('取消'),
              ),
            ),
          ],
        ),
      DownloadStatus.failed => Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => DownloadManager.instance.retry(_task),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => DownloadManager.instance.cancel(_task),
                icon: const Icon(Icons.close),
                label: const Text('取消'),
              ),
            ),
          ],
        ),
      DownloadStatus.completed => FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt),
          label: Text(_saving ? '保存中…' : '保存到…'),
        ),
      DownloadStatus.cancelled => OutlinedButton.icon(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.check),
          label: const Text('完成'),
        ),
    };
  }
}
