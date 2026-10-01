import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音输入对话框：端侧系统语音识别（默认 zh-CN），实时转写。
///
/// 与 dsh 自带的浏览器麦克风 STT 无关——WebView 内申请麦克风权限、下载
/// 识别模型在移动端体验都不可靠。这里用 Android 系统识别服务在原生层
/// 转写，结果交给调用方注入 DSH 消息输入框（composer 桥）。
///
/// 返回 null = 用户取消或识别不可用；返回文本 = 用户确认插入。
class VoiceInputDialog extends StatefulWidget {
  const VoiceInputDialog({super.key});

  /// 打开对话框并返回最终转写文本。
  static Future<String?> show(BuildContext context) =>
      showDialog<String>(context: context, builder: (_) => const VoiceInputDialog());

  @override
  State<VoiceInputDialog> createState() => _VoiceInputDialogState();
}

class _VoiceInputDialogState extends State<VoiceInputDialog> {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false; // initialize 成功
  bool _listening = false;
  String _text = ''; // 已确认 + 部分 转写
  String? _error;
  String? _localeId; // zh 系识别区域，取系统第一个 zh_*；无则用默认

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // initialize 内部处理 RECORD_AUDIO 权限申请：拒绝时返回 false
    final ok = await _stt.initialize(
      onError: (e) {
        if (mounted) setState(() => _error = '识别错误：${e.errorMsg}');
      },
      onStatus: (status) {
        // 系统识别可能自动结束（静音超时），同步按钮态
        if (mounted && status == 'done' && _listening) {
          setState(() => _listening = false);
        }
      },
    );
    if (!ok) {
      if (mounted) {
        setState(() => _error = '语音识别不可用：未授权麦克风或系统无识别服务');
      }
      return;
    }
    // 选 zh 系 locale（简体优先）；系统无中文语音时回退默认（跟随系统语言）
    String? locale;
    try {
      final locales = await _stt.locales();
      final zhList = locales
          .map((l) => l.localeId)
          .where((id) => id.toLowerCase().startsWith('zh'))
          .toList();
      if (zhList.isNotEmpty) {
        locale = zhList.firstWhere(
          (id) => id.toLowerCase().contains('cn'),
          orElse: () => zhList.first,
        );
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _ready = true;
      _localeId = locale;
    });
    _start();
  }

  Future<void> _start() async {
    if (!_ready || _listening) return;
    setState(() => _error = null);
    await _stt.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() => _text = r.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        localeId: _localeId,
      ),
    );
    if (mounted) setState(() => _listening = true);
  }

  Future<void> _stop() async {
    await _stt.stop();
    if (mounted) setState(() => _listening = false);
  }

  @override
  void dispose() {
    _stt.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('语音输入'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 麦克风波纹指示：识别中呼吸动画，静态时为灰
          Icon(
            _listening ? Icons.mic : Icons.mic_none,
            size: 48,
            color: _listening ? theme.colorScheme.primary : Colors.grey,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72, maxWidth: 280),
            child: Align(
              alignment: Alignment.topLeft,
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13))
                  : Text(
                      _text.isEmpty ? '请说话…' : _text,
                      style: theme.textTheme.bodyMedium,
                    ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        // 识别中 → 停止；已停且有文本 → 重说
        if (_listening)
          FilledButton.tonal(
            onPressed: _stop,
            child: const Text('停止'),
          )
        else if (_ready && _text.isNotEmpty)
          FilledButton.tonal(
            onPressed: _start,
            child: const Text('重说'),
          ),
        FilledButton(
          onPressed: _text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _text.trim()),
          child: const Text('插入'),
        ),
      ],
    );
  }
}
