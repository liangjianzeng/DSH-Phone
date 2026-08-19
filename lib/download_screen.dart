import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'download_manager.dart';

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

  DownloadTask get _task => widget.task;

  @override
  void initState() {
    super.initState();
    _progress = DownloadProgress(
      _task.downloadedBytes,
      _task.totalBytes ?? 0,
    );
    _task.progressStream.listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
    });
    _task.statusStream.listen((s) {
      if (!mounted) return;
      setState(() {});
      // 下载完成：提示用户选择保存位置
      if (s == DownloadStatus.completed) {
        _promptSave();
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  String _statusText(DownloadStatus s) {
    return switch (s) {
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
        content: Text('${_task.fileName} 已下载，选择保存位置？'),
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
    final bytes = _task.resultBytes;
    if (bytes == null || _saving) return;
    setState(() => _saving = true);
    try {
      final path = await FilePicker.platform.saveFile(
        fileName: _task.fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      if (path != null) {
        setState(() => _savedPath = path);
        _toast('已保存到：$path');
      }
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _progress;
    final frac = p?.fraction ?? 0.0;
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
            LinearProgressIndicator(value: frac),
            const SizedBox(height: 12),
            Text(
              '${_sizeText(p?.downloaded ?? 0)} / ${_sizeText(p?.total ?? 0)}'
              '${p?.total != null && p!.total > 0 ? '  (${(frac * 100).toStringAsFixed(1)}%)' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            if (status == DownloadStatus.failed && _task.error != null) ...[
              const SizedBox(height: 12),
              Text('错误：${_task.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
            const Spacer(),
            _buildActions(status),
            const SizedBox(height: 8),
            if (_savedPath != null)
              Text('已保存到：$_savedPath',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.green, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// 按状态渲染操作按钮。
  Widget _buildActions(DownloadStatus status) {
    return switch (status) {
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
