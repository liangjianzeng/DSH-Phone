import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import 'artifact_recognizer.dart';

/// 原生成果查看器：按类型渲染 md / html / 代码，关闭即返回对话。
///
/// 以全屏路由叠在对话之上打开，`Navigator.pop()` 关闭后对话滚动位置天然保持。
/// 内容由外层（WebView 页面）预先获取后传入，本页只负责渲染与兜底打开。
class ArtifactViewerScreen extends StatefulWidget {
  const ArtifactViewerScreen({
    super.key,
    required this.type,
    this.url = '',
    this.language = '',
    this.content = '',
    this.loader,
    this.fileName,
    this.rawBytesLoader,
  });

  /// 识别类型。
  final ArtifactType type;

  /// 文件型成果地址（空表示内容已内联传入）。
  final String url;

  /// 代码块语言（语法高亮用，可为空）。
  final String language;

  /// 已获取的原始内容。
  final String content;

  /// 异步加载器：文件型成果内容为空时调用（经 SSH 读取云端文件），
  /// 返回原始文本；为空表示无需异步加载。
  final Future<String> Function()? loader;

  /// 展示/保存用的文件名（路径最后一段；为空则按类型取名）。
  final String? fileName;

  /// 原始字节加载器：文件型成果"另存为"时经 SSH 读取原始字节
  /// （保留原始编码）。为空时用已解码文本按 UTF-8 编码保存。
  final Future<Uint8List?> Function()? rawBytesLoader;

  @override
  State<ArtifactViewerScreen> createState() => _ArtifactViewerScreenState();
}

class _ArtifactViewerScreenState extends State<ArtifactViewerScreen> {
  /// 渲染模式：原生渲染 vs 网页式兜底。
  bool _webFallback = false;

  /// 异步加载中的内容（loader 拉取后填充）。
  String? _asyncContent;
  bool _loading = false;

  /// 另存为状态。
  bool _saving = false;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    final loader = widget.loader;
    if (loader != null && widget.content.isEmpty) {
      _loading = true;
      loader().then((text) {
        if (!mounted) return;
        setState(() {
          _asyncContent = text;
          _loading = false;
        });
      });
    }
  }

  String get _title {
    final lang = widget.language;
    return switch (widget.type) {
      ArtifactType.markdown => 'Markdown 成果',
      ArtifactType.html => 'HTML 成果',
      ArtifactType.code => '代码成果${lang.isNotEmpty ? ' · $lang' : ''}',
      ArtifactType.file => '文件成果',
      ArtifactType.resource => '资源成果',
      ArtifactType.none => '成果',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 背景跟随主题：深色模式下避免刺眼的浅色底色
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: '另存为（下载保存到本机）',
            icon: const Icon(Icons.download),
            onPressed: _saving ? null : _save,
          ),
          IconButton(
            tooltip: '网页式打开（兜底）',
            icon: const Icon(Icons.open_in_new),
            onPressed: widget.url.isEmpty
                ? null
                : () => setState(() => _webFallback = true),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 实际展示内容：优先内联，否则用异步加载结果。
  String get _effectiveContent =>
      widget.content.isNotEmpty ? widget.content : (_asyncContent ?? '');

  Widget _buildBody() {
    debugPrint('VIEWER: type=${widget.type} url=${widget.url} '
        'contentLen=${_effectiveContent.length} webFallback=$_webFallback');
    // 网页式兜底：原生渲染不可用/用户主动切换时，用嵌套 WebView 打开成果 URL。
    if (_webFallback && widget.url.isNotEmpty) {
      return _buildWebFallback();
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_effectiveContent.isEmpty) {
      // 有异步加载器（文件型）但内容为空：提示读取失败并给出重试/另存为
      if (widget.loader != null) {
        return _buildLoadError();
      }
      return const Center(child: Text('无内容可查看'));
    }
    // 二进制内容防护：解码后含大量替换符视为不可读 → 提示另存为，避免灰屏
    if (_looksBinary(_effectiveContent)) {
      return _buildLoadError('该文件无法直接查看（可能是二进制内容），可尝试另存为。');
    }
    // 渲染构造异常时兜底为错误界面，避免 release 模式灰屏
    try {
      return SafeArea(child: _buildContent());
    } catch (e, st) {
      debugPrint('VIEWER render error: $e\n$st');
      return _buildLoadError('渲染失败，可尝试另存为查看原始内容。');
    }
  }

  /// 判断解码文本是否像二进制：替换符（U+FFFD）占比过高即视为不可读。
  bool _looksBinary(String text) {
    if (text.isEmpty) return false;
    var replacements = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0xFFFD) replacements++;
    }
    return replacements > text.length * 0.05;
  }

  /// 文件型成果读取失败界面：提示隧道状态并提供重试/另存为。
  Widget _buildLoadError([String message = '读取成果失败，隧道可能未连接。']) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (widget.url.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('地址：${widget.url}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _retryLoad,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.download),
              label: const Text('另存为'),
            ),
          ],
        ),
      ),
    );
  }

  void _retryLoad() {
    final loader = widget.loader;
    if (loader == null) return;
    setState(() => _loading = true);
    loader().then((text) {
      if (!mounted) return;
      setState(() {
        _asyncContent = text;
        _loading = false;
      });
    });
  }

  /// 另存为：优先取原始字节（保留原始编码），否则用已解码文本按 UTF-8 保存。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      Uint8List? bytes;
      final rawLoader = widget.rawBytesLoader;
      if (rawLoader != null) {
        bytes = await rawLoader();
      }
      bytes ??= Uint8List.fromList(utf8.encode(_effectiveContent));
      final path = await FilePicker.platform.saveFile(
        fileName: _defaultFileName(),
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

  /// 保存文件名：优先成果文件名，否则按类型取名。
  String _defaultFileName() {
    if (widget.fileName != null && widget.fileName!.isNotEmpty) {
      return widget.fileName!;
    }
    return switch (widget.type) {
      ArtifactType.markdown => '成果.md',
      ArtifactType.html => '成果.html',
      ArtifactType.code => '代码.txt',
      ArtifactType.file => '成果.txt',
      ArtifactType.resource => '资源.bin',
      ArtifactType.none => '成果.txt',
    };
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 网页式兜底：嵌套 WebView 打开成果 URL（复杂 HTML 可完整渲染）。
  Widget _buildWebFallback() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
      ),
    );
  }

  Widget _buildContent() {
    final content = _effectiveContent;
    // 按类型分发渲染。
    switch (widget.type) {
      case ArtifactType.html:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: HtmlWidget(content),
        );
      case ArtifactType.code:
        return _buildCodeRenderer(content);
      case ArtifactType.markdown:
      case ArtifactType.file:
      case ArtifactType.resource:
      case ArtifactType.none:
        // 文件型/未知类型：按内容自动识别 HTML 还是 Markdown。
        final lower = content.trim().toLowerCase();
        if (lower.startsWith('<!doctype') || lower.startsWith('<html')) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: HtmlWidget(content),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MarkdownBody(data: content, styleSheet: _markdownStyle()),
        );
    }
  }

  /// 跟随主题的 Markdown 样式：深色模式下代码块背景不再刺眼。
  MarkdownStyleSheet _markdownStyle() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = MarkdownStyleSheet.fromTheme(theme);
    return base.copyWith(
      code: base.code?.copyWith(
        color: scheme.onSurface,
        backgroundColor: Colors.transparent,
      ),
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  /// 代码渲染：flutter_highlight 语法高亮，主题跟随系统深浅色。
  Widget _buildCodeRenderer(String content) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final theme = dark ? atomOneDarkTheme : atomOneLightTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: HighlightView(
        content,
        language: widget.language.isEmpty ? null : widget.language,
        theme: theme,
        textStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.4,
        ),
      ),
    );
  }
}
