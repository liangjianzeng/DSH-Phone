import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音输入对话框：端侧系统语音识别（默认 zh-CN），实时转写。
///
/// 与 dsh 自带的浏览器麦克风 STT 无关——WebView 内申请麦克风权限、下载
/// 识别模型在移动端体验都不可靠。这里用 Android 系统识别服务在原生层
/// 转写，结果交给调用方注入 DSH 消息输入框（composer 桥）。
///
/// 机型没有系统识别服务（小米/无谷歌服务 ROM 常见，启动即 error_client）
/// 时，对话框提供「改用页面内语音输入」入口：返回 [pageMicFallback]
/// 哨兵，由调用方授权 WebView 麦克风并引导用户点页面里的麦克风按钮。
///
/// 返回 null = 用户取消；返回 [pageMicFallback] = 走页面内语音；
/// 其它非空文本 = 用户确认插入。
class VoiceInputDialog extends StatefulWidget {
  const VoiceInputDialog({super.key});

  /// 页面内语音输入的哨兵返回值。
  static const String pageMicFallback = '__use_page_mic__';

  /// 打开对话框并返回最终转写文本（或哨兵/null）。
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
    bool ok;
    try {
      debugPrint('[DSH][voice] initialize begin');
      // 小米/无谷歌服务机型：系统识别服务缺失时 initialize 可能静默挂起，
      // 超时兜底给出明确错误而不是永远转圈。
      ok = await _stt.initialize(
        onError: (e) {
          debugPrint('[DSH][voice] onError: ${e.errorMsg}');
          // MIUI 等国产 ROM 的识别器怪癖：结果正常送达前后仍会补发
          // error_permission/error_client 事件（服务自检误报）。
          // 延迟判定：短期内若有转写文本到达则忽略该错误；只有始终
          // 无文本才作为失败展示（并给出页面内语音的降级入口）。
          Future<void>.delayed(const Duration(milliseconds: 600), () {
            if (!mounted || _text.trim().isNotEmpty || _error != null) return;
            setState(() => _error = switch (e.errorMsg) {
                  'error_client' => '本机没有可用的系统语音识别服务',
                  'error_permission' => '识别服务报权限错误：请确认已允许麦克风，'
                      '仍失败多为 ROM 兼容问题，可改用页面内语音',
                  _ => '识别错误：${e.errorMsg}',
                });
          });
        },
        onStatus: (status) {
          debugPrint('[DSH][voice] status: $status');
          // 系统识别可能自动结束（静音超时），同步按钮态
          if (mounted && status == 'done' && _listening) {
            setState(() => _listening = false);
          }
        },
      ).timeout(const Duration(seconds: 6));
    } on TimeoutException {
      debugPrint('[DSH][voice] initialize timeout');
      if (mounted) {
        setState(() => _error = '系统语音识别无响应（机型可能缺少语音识别服务，'
            '如未装"小爱语音引擎"/谷歌应用）');
      }
      return;
    }
    debugPrint('[DSH][voice] initialize result: $ok');
    if (!ok) {
      if (mounted) {
        setState(() => _error = '语音识别不可用：未授权麦克风或系统无识别服务');
      }
      return;
    }
    // 选 zh 系 locale（简体优先）；系统无中文语音时回退默认（跟随系统语言）
    String? locale;
    try {
      final locales =
          await _stt.locales().timeout(const Duration(seconds: 4));
      debugPrint('[DSH][voice] locales: '
          '${locales.map((l) => l.localeId).take(8).toList()}');
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
    } catch (e) {
      debugPrint('[DSH][voice] locales error: $e');
    }
    debugPrint('[DSH][voice] ready, localeId=$locale');
    if (!mounted) return;
    setState(() {
      _ready = true;
      _localeId = locale;
    });
    _start();
  }

  Future<void> _start() async {
    if (!_ready || _listening) return;
    debugPrint('[DSH][voice] listen start (localeId=$_localeId)');
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
              child: _text.isNotEmpty
                  // 有转写文本优先展示（ROM 误报的错误不遮盖实时结果）
                  ? Text(_text, style: theme.textTheme.bodyMedium)
                  : _error != null
                      ? Text(_error!,
                          style: const TextStyle(color: Colors.red, fontSize: 13))
                      : const Text('请说话…'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        // 系统识别不可用（无识别服务/客户端错误）且没有可用结果时，
        // 提供页面内语音输入的降级路径（dsh 自带 mic，模型跑在 host 端）。
        if (_error != null && _text.trim().isEmpty)
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, VoiceInputDialog.pageMicFallback),
            child: const Text('改用页面内语音'),
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
