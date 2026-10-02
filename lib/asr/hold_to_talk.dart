import 'dart:async';

import 'package:flutter/material.dart';

import 'asr_model_manager.dart';
import 'sherpa_streaming_asr.dart';

/// 按住说话会话：长按月相按钮期间的浮层 UI + 引擎生命周期。
///
/// 交互（微信式）：
/// - `start`：先插浮层（「准备中」），引擎就绪后切换实时回显；
/// - 上滑超过阈值 → cancelMode（浮层提示「松开取消」）；
/// - `end`：松手时取终稿（cancelMode 或空文本返回空串）。
///
/// 生命周期坑（真机实测）：首次 start 要加载 ~160MB 模型（数秒），期间
/// 用户可能已松手——调用方必须在 start 前把会话登记到持有方，松手时若
/// 引擎未就绪则置 [cancelRequested]，由 start 完成侧负责收尾，避免会话
/// 孤儿化（浮层滞留 + 麦克风常开）。
class HoldToTalkSession {
  HoldToTalkSession();

  /// 实时转写文本（已断句定稿 + 当前 partial）。
  final ValueNotifier<String> partial = ValueNotifier('');

  /// 上滑取消状态（浮层据此切换提示样式）。
  final ValueNotifier<bool> cancelMode = ValueNotifier(false);

  /// 引擎是否已就绪（浮层据此从「准备中」切到实时回显）。
  final ValueNotifier<bool> ready = ValueNotifier(false);

  /// 引擎加载完成前用户已松手：start 侧收尾时按取消处理。
  bool cancelRequested = false;

  OverlayEntry? _overlay;
  SherpaStreamingAsr? _engine;
  StreamSubscription<String>? _sub;
  bool _engineStarted = false;
  bool _aborted = false;

  /// 引擎是否已开始录音（end 语义分叉的依据）。
  bool get isStarted => _engineStarted;

  /// 上滑取消的位移阈值（逻辑像素，相对长按起点）。
  static const double cancelSlop = 70;

  /// 启动会话：插浮层 → 加载引擎 → 开始录音 → 切实时回显。
  /// 返回 false = 启动失败（浮层已自行撤除）。
  Future<bool> start(BuildContext context) async {
    // 先取 OverlayState（context 跨 async gap 使用会告警）
    final overlay = Overlay.of(context, rootOverlay: true);
    _overlay = OverlayEntry(builder: (_) => _HoldOverlay(session: this));
    overlay.insert(_overlay!);
    bool recording = false;
    // 成功标记必须在 try 内置位：finally 不能用 [_engineStarted] 判断——
    // 它在 finally 之后才置 true，恒为 false 会把成功路径也当成失败清理
    // （引擎刚启动即被 stop/dispose，随后 _engine! 空指针崩溃，真机实测）。
    bool success = false;
    try {
      _engine = await SherpaStreamingAsr.create(
          await AsrModelManager.modelDir());
      if (_aborted) return false;
      await _engine!.start();
      recording = true;
      if (_aborted) return false;
      success = true;
    } catch (e) {
      debugPrint('[DSH][asr] session start failed: $e');
      return false;
    } finally {
      if (!success) {
        // 失败或加载期间被中止：清理浮层与引擎
        _removeOverlay();
        final engine = _engine;
        _engine = null;
        if (engine != null) {
          if (recording) await engine.stop();
          await engine.dispose();
        }
      }
    }
    _engineStarted = true;
    _sub = _engine!.partialText.listen((t) {
      partial.value = t;
    });
    ready.value = true;
    return true;
  }

  /// 结束会话：[cancelled] 为 true 时丢弃结果。返回终稿文本（可能为空串）。
  /// 引擎尚未就绪时调用 = 请求中止，由 start 的 finally 负责清理。
  Future<String> end({bool cancelled = false}) async {
    if (!_engineStarted) {
      _aborted = true;
      cancelRequested = true;
      _removeOverlay();
      return '';
    }
    _removeOverlay();
    await _sub?.cancel();
    _sub = null;
    final text = cancelled ? '' : await _engine?.stop() ?? '';
    await _engine?.dispose();
    _engine = null;
    return text.trim();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }
}

class _HoldOverlay extends StatelessWidget {
  const _HoldOverlay({required this.session});

  final HoldToTalkSession session;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      // 浮层只做展示：手指仍按在月相按钮上，事件路由不能被打断
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.all(32),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                constraints: const BoxConstraints(maxWidth: 360),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: session.cancelMode,
                      builder: (_, cancelling, __) => Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _PulsingMicIcon(red: cancelling),
                          const SizedBox(width: 10),
                          Text(
                            cancelling
                                ? '松开取消'
                                : session.ready.value ? '松开发送' : '准备中…',
                            style: TextStyle(
                              color: cancelling
                                  ? Colors.redAccent
                                  : Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<String>(
                      valueListenable: session.partial,
                      builder: (_, text, __) => ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            text.isEmpty ? '请说话…' : text,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15, height: 1.4),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 麦克风呼吸动画：说话中持续脉动，取消态变红。
class _PulsingMicIcon extends StatefulWidget {
  const _PulsingMicIcon({required this.red});

  final bool red;

  @override
  State<_PulsingMicIcon> createState() => _PulsingMicIconState();
}

class _PulsingMicIconState extends State<_PulsingMicIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_ctrl),
      child: Icon(Icons.mic,
          color: widget.red ? Colors.redAccent : Colors.lightBlueAccent,
          size: 26),
    );
  }
}

/// 模型下载引导：模型未就绪时弹窗展示断点续传下载进度，完成返回 true。
class AsrModelGate {
  AsrModelGate._();

  /// 确保模型就绪。已就绪直接返回 true；否则弹下载对话框：
  /// 完成 → true；用户取消/失败未重试 → false（调用方回落系统识别）。
  static Future<bool> ensureModelReady(BuildContext context) async {
    if (await AsrModelManager.isReady()) return true;
    if (!context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AsrDownloadDialog(),
    );
    return ok == true;
  }
}

class _AsrDownloadDialog extends StatefulWidget {
  const _AsrDownloadDialog();

  @override
  State<_AsrDownloadDialog> createState() => _AsrDownloadDialogState();
}

class _AsrDownloadDialogState extends State<_AsrDownloadDialog> {
  final ValueNotifier<double> _progress = ValueNotifier(0);
  String _status = '准备下载…';
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _status = '准备下载…';
    });
    try {
      await AsrModelManager.download(
        onProgress: (p, file) {
          _progress.value = p;
          if (mounted) {
            setState(() => _status = '正在下载 $file（${(p * 100).toStringAsFixed(1)}%，'
                '中断可续传）');
          }
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AsrDownloadCancelled {
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      debugPrint('[DSH][asr] download failed: $e');
      if (mounted) {
        setState(() => _error = '下载失败：$e\n已下载的部分会保留，重试将从断点继续。');
      }
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
    await AsrModelManager.cancelDownloads();
  }

  @override
  void dispose() {
    if (!_cancelled) unawaited(AsrModelManager.cancelDownloads());
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('启用端侧语音识别'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('首次使用需下载中文识别模型（约 160MB，一次即可）：'),
          const SizedBox(height: 8),
          const Text('· 下载到应用私有目录，不打包也无需重复下载\n'
              '· 中断（断网/杀 App）后自动断点续传\n'
              '· 下载完成后长按月相按钮即可按住说话'),
          const SizedBox(height: 14),
          ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, p, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: p <= 0 ? null : p),
                const SizedBox(height: 6),
                Text(_status,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await _cancel();
            if (context.mounted) Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
        if (_error != null)
          FilledButton(
            onPressed: _start,
            child: const Text('重试'),
          ),
      ],
    );
  }
}
