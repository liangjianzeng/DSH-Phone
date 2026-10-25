import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:share_plus/share_plus.dart';

import 'artifact_recognizer.dart';
import 'artifact_render_html.dart';
import 'tunnel_service.dart' show RemoteFailureKind, RemoteReadException;

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
    this.path = '',
    this.rawBytesLoader,
    this.initialError = '',
    this.webRenderer,
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

  /// 页面内（JS 侧）取内容失败时带回的原因。
  ///
  /// 以前 JS 的 `fetchArtifact` 一旦失败就 `send({content:''})`，于是链接型成果
  /// 点开后只有笼统一句"无内容可查看"——既没说是失败，也没说是 401 还是超时，
  /// 用户和排查者都无从下手。
  /// 读取用的云端路径：只为"出错时说清试过哪条路"而存在（无 adb 时的排查命脉）。
  final String path;

  final String initialError;

  /// 初始渲染方式（null = 按内容类型自动选）。测试用，也便于以后"记住上次选择"。
  final bool? webRenderer;

  @override
  State<ArtifactViewerScreen> createState() => _ArtifactViewerScreenState();
}

class _ArtifactViewerScreenState extends State<ArtifactViewerScreen> {
  /// 渲染模式：原生渲染 vs 网页式兜底。
  bool _webFallback = false;

  /// 主渲染方式：null = 未由用户指定，按内容类型给默认值。
  ///
  /// 默认走**系统 WebView**（`loadData` + `baseUrl` 指向隧道 origin）：
  /// `flutter_widget_from_html_core` 不执行脚本、外链 CSS/flex 基本无效，
  /// DSH 的报告渲染成裸文本；`flutter_markdown` 又没有 imageBuilder /
  /// onTapLink，相对图片与链接都点不动。原生那条路保留为"快速模式"
  /// （超长代码、低配机型、WebView 起不来时更有优势）。
  bool? _useWebRenderer;

  /// 失败分类（来自 RemoteReadException.kind）：只报文案用户依然不知道下一步。
  RemoteFailureKind? _loadErrorKind;

  /// 图片成果的字节（延迟加载）。图片以前只能下载，连看都看不了。
  Uint8List? _imageBytes;
  bool _loadingImage = false;

  /// 渲染种类与网页文档的**按内容缓存**。
  ///
  /// 不是微优化：判定要看首行特征，直接 `content.trimLeft().toLowerCase()`
  /// 对 20MB 文本就是整串拷贝，而 AppBar 的 tooltip/icon/onPressed 一次 build
  /// 就问了三遍；`document()` 同理每次 setState 重拼整份 HTML。
  ArtifactRenderKind? _cachedKind;
  String? _cachedKindSource;
  String? _cachedHtml;
  String? _cachedHtmlSource;
  ArtifactRenderKind? _cachedHtmlKind;
  bool? _cachedHtmlDark;

  /// 异步加载中的内容（loader 拉取后填充）。
  String? _asyncContent;
  bool _loading = false;

  /// loader 成功返回过（哪怕返回的是空串）。
  ///
  /// 用于区分两件完全不同的事：**云端文件是 0 字节** 与 **读取失败**。旧实现里
  /// 两者都落到 `_buildLoadError()`，于是刚创建的空文件、只含 BOM 的文件被显示成
  /// "读取成果失败"，而且因为 `_loadError` 是 null，连"原因"那一行都没有。
  bool _loadedOk = false;

  /// 异步加载失败原因（真实原因，如隧道未连接/文件过大，错误页展示）。
  String? _loadError;

  /// 另存为状态。
  bool _saving = false;

  /// 加载世代号：重试时作废上一次的回调，慢返回不会覆盖新结果。
  int _loadGeneration = 0;

  /// 二进制判定缓存：该判定要逐字符扫全文，原来**每次 build 都跑一遍**
  /// （8M 字符就是几十毫秒，直接卡在 UI 线程掉帧）。
  bool? _binaryVerdict;
  String? _binaryVerdictSource;

  @override
  void initState() {
    super.initState();
    _useWebRenderer = widget.webRenderer;
    if (widget.initialError.isNotEmpty) {
      // JS 侧 fetch 失败带来的原因（401 / 超时 / 超大），不再只是"无内容可查看"。
      _loadError = widget.initialError;
    }
    if (_isImage) {
      _loadImage();
    } else {
      _startLoad();
    }
  }

  /// 是否为图片成果（用 InteractiveViewer 看字节，绝不进任何文本渲染器）。
  bool get _isImage {
    if (widget.type != ArtifactType.resource) return false;
    final key = (widget.fileName?.isNotEmpty ?? false)
        ? widget.fileName!
        : widget.url;
    return key.isNotEmpty && ArtifactRules.isImageSuffix(key);
  }

  /// 图片：读原始字节交给 Image.memory + InteractiveViewer（可双指缩放）。
  Future<void> _loadImage() async {
    final loader = widget.rawBytesLoader;
    if (loader == null) {
      setState(() => _loadError = '这张图片没有可读取的云端路径');
      return;
    }
    setState(() {
      _loadingImage = true;
      _loadError = null;
    });
    try {
      final bytes = await loader();
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _loadingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = _errorText(e);
        _loadingImage = false;
      });
    }
  }

  /// 启动一次异步加载（initState 与"重试"共用一条路径）。
  void _startLoad() {
    final loader = widget.loader;
    if (loader == null || widget.content.isNotEmpty) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    // 用 Future 包一层再链：loader 若**同步**抛异常（闭包内 assert/空指针），
    // 直接 loader().then 会绕过 catchError，把界面永久留在转圈态。
    Future<String> run() async => loader();
    run().then((text) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _asyncContent = text;
        _loadedOk = true;
        _loading = false;
      });
    }).catchError((Object e) {
      debugPrint('VIEWER load error: $e');
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = _errorText(e);
        _loadErrorKind = e is RemoteReadException ? e.kind : null;
        _loading = false;
      });
    });
  }

  /// 提取用户可读的失败原因（自定义异常直接取 message）。
  static String _errorText(Object e) =>
      e is RemoteReadException ? e.message : '$e';

  /// AppBar 标题：优先文件名（4 个字的"文件成果"认不出是哪个成果），
  /// 文件名过长时靠 ellipsis 收缩，不再靠挤掉标题腾地方。
  String get _displayTitle {
    final name = widget.fileName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return _title;
  }

  /// 长按标题：复制"文件名 + 云端路径 + 链接"，用于无 adb 时的排查与转述。
  Future<void> _copyTarget() async {
    final parts = <String>[
      if (_displayTitle.isNotEmpty) _displayTitle,
      if (widget.path.isNotEmpty) '路径：${widget.path}',
      if (widget.url.isNotEmpty) '链接：${widget.url}',
    ];
    if (parts.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: parts.join('\n')));
    } catch (_) {
      // 剪贴板被系统策略限制（如企业策略）：复制失败仍给出提示，内容可手动选。
    }
    if (!mounted) return;
    _toast('已复制文件名与路径');
  }

  /// 低频动作收进 ⋯ 菜单：栏上少两个图标，标题才有地方呼吸。
  Widget _buildOverflowMenu() {
    final useWeb = _shouldUseWeb(_renderKindFor(_effectiveContent),
        _effectiveContent);
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'toggle-renderer':
            setState(() => _useWebRenderer = !useWeb);
          case 'web-open':
            setState(() => _webFallback = true);
          case 'copy-target':
            _copyTarget();
          case 'copy-content':
            _copyContent();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'toggle-renderer',
          enabled: !_isImage &&
              !(_effectiveContent.isEmpty && !_loading),
          child: Row(children: [
            Icon(useWeb ? Icons.phone_android_outlined : Icons.html_outlined,
                size: 20),
            const SizedBox(width: 10),
            Text(useWeb ? '改用原生渲染（更快更稳）' : '改用网页渲染（效果最全）'),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'web-open',
          enabled: widget.url.isNotEmpty,
          child: const Row(children: [
            Icon(Icons.open_in_new, size: 20),
            SizedBox(width: 10),
            Text('网页式打开（兜底）'),
          ]),
        ),
        const PopupMenuItem<String>(
          value: 'copy-target',
          child: Row(children: [
            Icon(Icons.my_location, size: 20),
            SizedBox(width: 10),
            Text('复制文件名与路径'),
          ]),
        ),
        if (!_canCopyShare)
          const PopupMenuItem<String>(
            value: 'copy-content',
            child: Row(children: [
              Icon(Icons.copy_all, size: 20),
              SizedBox(width: 10),
              Text('复制全文'),
            ]),
          ),
      ],
    );
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
        // 真机上标题被挤成了"文…"：leading + 6 个图标把 360dp 宽度吃光，
        // 标题只剩几个像素。三管齐下：图标降到 22、只留 3 个高频动作在栏上
        // （其余进 ⋯ 菜单）、标题用 Flexible 收缩并支持长按复制文件名与路径。
        titleSpacing: 4,
        iconTheme: const IconThemeData(size: 22),
        actionsIconTheme: const IconThemeData(size: 22),
        // AppBar 已把 title 包在 Flexible 里（这里再套 Flexible 会
        // Incorrect use of ParentDataWidget），所以只声明 ellipsis 即可。
        title: Tooltip(
          message: '长按复制文件名与路径',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: _copyTarget,
            child: Text(
              _displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '另存为（保存到本机）',
            icon: const Icon(Icons.download),
            onPressed: _saving ? null : _save,
          ),
          IconButton(
            tooltip: '复制内容',
            icon: const Icon(Icons.copy),
            onPressed: _canCopyShare ? _copyContent : null,
          ),
          IconButton(
            tooltip: '一键分享',
            icon: const Icon(Icons.share),
            onPressed: _canCopyShare ? _shareContent : null,
          ),
          _buildOverflowMenu(),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 实际展示内容：优先内联，否则用异步加载结果。
  String get _effectiveContent =>
      widget.content.isNotEmpty ? widget.content : (_asyncContent ?? '');

  /// 复制/分享是否可用：加载完成且有内容。
  bool get _canCopyShare => !_loading && _effectiveContent.isNotEmpty;

  /// 复制内容全文到剪贴板。
  Future<void> _copyContent() async {
    final content = _effectiveContent;
    if (content.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: content));
      if (!mounted) return;
      _toast('已复制 ${content.length} 字');
    } catch (e) {
      if (!mounted) return;
      _toast('复制失败：$e');
    }
  }

  /// 一键分享：调系统分享面板（微信/邮件/备忘录等），分享内容全文。
  Future<void> _shareContent() async {
    final content = _effectiveContent;
    if (content.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(text: content, subject: _defaultFileName()),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：$e');
    }
  }

  Widget _buildBody() {
    debugPrint('VIEWER: type=${widget.type} url=${widget.url} '
        'contentLen=${_effectiveContent.length} webFallback=$_webFallback');
    // 网页式兜底：原生渲染不可用/用户主动切换时，用嵌套 WebView 打开成果 URL。
    if (_webFallback && widget.url.isNotEmpty) {
      return _buildWebFallback();
    }
    // 图片：永远不进文本渲染器（旧实现把 png 当文本读，8M 字符乱码 + 卡顿）。
    if (_isImage) {
      if (_loadingImage) {
        return const Center(child: CircularProgressIndicator());
      }
      final bytes = _imageBytes;
      if ((bytes == null || bytes.isEmpty) && _canShowImageViaUrl) {
        // 云端路径拿不到字节，但链接往往还能开（登录态在 WebView cookie 里）：
        // 真机上"图片成果提示云端不存在该文件"就是这条兜底缺失造成的。
        return _buildImageViewViaUrl();
      }
      if (bytes == null || bytes.isEmpty) {
        return _buildLoadError('无法显示这张图片。');
      }
      return _buildImageView(bytes);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_effectiveContent.isEmpty) {
      // 0 字节 / 只含 BOM / 解码后为空：这是**成功读取的空文件**，不是失败。
      if (_loadedOk) {
        return _buildEmptyFile();
      }
      // 有异步加载器（文件型）但内容为空：提示读取失败并给出重试/另存为
      if (widget.loader != null) {
        return _buildLoadError();
      }
      if (widget.initialError.isNotEmpty) {
        return _buildLoadError('页面内获取内容失败。');
      }
      return const Center(child: Text('无内容可查看'));
    }
    // 二进制内容防护：解码后替换符占比过高视为不可读 → 提示另存为，避免灰屏
    if (_looksBinaryCached(_effectiveContent)) {
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

  /// 空文件界面：与"读取失败"分开，别再显示红色云断图标误导用户去查隧道。
  Widget _buildEmptyFile() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.note_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('云端文件是空的（0 字节）', textAlign: TextAlign.center),
            if (widget.fileName != null && widget.fileName!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('文件：${widget.fileName}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _startLoad,
              icon: const Icon(Icons.refresh),
              label: const Text('重新读取'),
            ),
          ],
        ),
      ),
    );
  }

  /// 判断解码文本是否像二进制：替换符（U+FFFD）占比过高即视为不可读。
  /// 占比 30% 以下仍按文本渲染（混合编码文本可能出现少量替换符，
  /// 不影响整体阅读；此前 5% 阈值会误杀正常中文文档）。
  bool _looksBinaryCached(String text) {
    if (_binaryVerdict != null && _binaryVerdictSource == text) {
      return _binaryVerdict!;
    }
    final verdict = _computeLooksBinary(text);
    _binaryVerdict = verdict;
    _binaryVerdictSource = text;
    return verdict;
  }

  static bool _computeLooksBinary(String text) {
    if (text.isEmpty) return false;
    var replacements = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0xFFFD) replacements++;
    }
    return replacements > text.length * 0.3;
  }

  /// 文件型成果读取失败界面：展示真实原因并提供重试/另存为。
  Widget _buildLoadError([String message = '读取成果失败。']) {
    final scheme = Theme.of(context).colorScheme;
    final target = widget.path.isNotEmpty ? widget.path : widget.url;
    final targetLabel = widget.path.isNotEmpty ? '路径' : '链接';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (_loadError != null && _loadError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '原因：$_loadError',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
            if (_kindHint != null) ...[
              const SizedBox(height: 6),
              Text(_kindHint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.outline, fontSize: 12.5)),
            ],
            // 无 adb 真机排查的命脉：必须看得见"到底试了哪条路径"，
            // 否则用户只能转述一句"点开提示云端不存在该文件"。
            if (target.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectionArea(
                  child: Text(
                    '$targetLabel：$target',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _copyTarget,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制文件名与路径'),
              ),
            ],
            const SizedBox(height: 12),
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
            if (widget.url.isNotEmpty &&
                // PDF/office：安卓 WebView 渲染不了（无 PDF 插件），点了
                // 只会白屏——这类去对话里点文件卡片，走 DSH Web 自带
                // pdf.js 预览（长按卡片则进 App 下载）。
                !ArtifactRules.isWebviewUnrenderable(widget.url)) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                // SFTP 这条路走不通时，同源链接往往还能打开（登录态在 WebView
                // cookie 里），至少让用户看到内容而不是一个红云。
                onPressed: () => setState(() => _webFallback = true),
                icon: const Icon(Icons.open_in_new),
                label: const Text('用网页方式打开'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 失败分类 → 下一步建议。
  String? get _kindHint {
    switch (_loadErrorKind) {
      case RemoteFailureKind.notFound:
        return '文件可能已被清理或改名；也可能是产物 chips 被隐藏后按目录拼出的路径不准。';
      case RemoteFailureKind.isDirectory:
        return '这是个目录，请点目录里的具体文件。';
      case RemoteFailureKind.permission:
        return '云端账号对该路径没有读权限。';
      case RemoteFailureKind.timeout:
        return '链路可能半开：切到主界面点顶栏状态图标探活，或直接重连。';
      case RemoteFailureKind.channelExhausted:
        return '远端 SSH 通道被占满（sshd MaxSessions）：稍等片刻再试，或减少并发下载。';
      case RemoteFailureKind.notConnected:
        return '隧道当前未连接：回主界面查看顶部横幅并重连。';
      case RemoteFailureKind.tooLarge:
        return '文件超出预览上限，请改用"另存为"。';
      case RemoteFailureKind.other:
      case null:
        return null;
    }
  }

  void _retryLoad() {
    _loadedOk = false;
    _loadErrorKind = null;
    _binaryVerdict = null;
    _binaryVerdictSource = null;
    _startLoad();
  }

  /// 另存为：优先取原始字节（保留原始编码），否则用已解码文本按 UTF-8 保存。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      Uint8List? bytes;
      final rawLoader = widget.rawBytesLoader;
      if (rawLoader != null) {
        try {
          bytes = await rawLoader();
        } catch (e) {
          // 读取失败绝不能再往下走"用空内容凑一份字节"的老路：那条路会
          // 建一个 0 字节的文档然后 toast「已保存到…」，用户拿到坏文件。
          if (!mounted) return;
          _toast('读取原始内容失败：${_errorText(e)}');
          return;
        }
      }
      if (bytes == null) {
        final content = _effectiveContent;
        if (content.isEmpty) {
          if (!mounted) return;
          _toast('没有可保存的内容（读取失败或文件为空）');
          return;
        }
        bytes = Uint8List.fromList(utf8.encode(content));
      }
      if (bytes.isEmpty) {
        if (!mounted) return;
        _toast('文件内容为空（0 字节），未保存');
        return;
      }
      final name = _defaultFileName();
      final path = await FilePicker.platform.saveFile(
        fileName: name,
        bytes: bytes,
      );
      if (!mounted) return;
      if (path == null) {
        _toast('已取消保存');
        return;
      }
      // 插件在 Android 上返回的是拼出来的 Downloads 路径，不等于真实位置，
      // 因此只报文件名 + 提示以系统选择器为准。
      _toast('已保存：$name（具体位置以系统文件选择器为准）');
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

  /// 网页式兜底：嵌套 WebView 直接打开成果 URL（复杂 HTML 可完整渲染）。
  Widget _buildWebFallback() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // 原来写死 LOAD_CACHE_ELSE_NETWORK：成果文件被 agent 覆盖后，
        // "网页式打开"看到的还是上一版，排查问题时极容易被这份旧缓存误导。
        cacheMode: CacheMode.LOAD_NO_CACHE,
      ),
    );
  }

  /// 内容 → 渲染种类。
  ///
  /// 以前 `file` 型一律先试 HTML、否则 Markdown，于是 `.csv`（没有 `|`）被挤成
  /// 一段、`.json` 的缩进被 Markdown 吃掉且无高亮——这两类现在单独走自己的路。
  ArtifactRenderKind _renderKindFor(String content) {
    if (_cachedKind != null && _cachedKindSource == content) {
      return _cachedKind!;
    }
    final kind = _computeRenderKind(content);
    _cachedKind = kind;
    _cachedKindSource = content;
    return kind;
  }

  ArtifactRenderKind _computeRenderKind(String content) {
    final name = (widget.fileName ?? '').toLowerCase();
    final lang = widget.language.trim().toLowerCase();
    if (name.endsWith('.json') || lang == 'json') {
      return ArtifactRenderKind.json;
    }
    if (name.endsWith('.csv') || name.endsWith('.tsv') || lang == 'csv') {
      return ArtifactRenderKind.csv;
    }
    if (widget.type == ArtifactType.code) return ArtifactRenderKind.code;
    if (widget.type == ArtifactType.html) return ArtifactRenderKind.html;
    if (widget.type == ArtifactType.markdown) return ArtifactRenderKind.markdown;
    final lower = content.trimLeft().toLowerCase();
    if (lower.startsWith('<!doctype') ||
        lower.startsWith('<html') ||
        // 片段式 HTML / SVG（DSH 报告常直接给 `<div …>`、`<svg …>`）：
        // 交给 Markdown 会把标签当字面文本吐出来。
        RegExp(r'^<[a-z][a-z0-9-]*[\s>/]').hasMatch(lower)) {
      return ArtifactRenderKind.html;
    }
    return ArtifactRenderKind.markdown;
  }

  /// WebView 走 method channel 把整份 HTML 传给原生 `loadDataWithBaseURL`，
  /// 超大字符串在 Android 上容易撞 binder 事务上限、表现为**点开一片空白**
  /// （比"渲染朴素"更糟）。超过这个量默认走原生；用户手动切网页仍然允许。
  static const int _maxWebChars = 1500 * 1024;

  /// 是否用系统 WebView 渲染（用户可切换，默认除代码外都用）。
  bool _shouldUseWeb(ArtifactRenderKind kind, String content) {
    final explicit = _useWebRenderer;
    if (explicit != null) return explicit;
    if (kind == ArtifactRenderKind.code) return false;
    return content.length <= _maxWebChars;
  }

  /// 相对资源的基址：不传 baseUrl，HTML/Markdown 里的相对图片与 CSS 必然 404。
  WebUri? _baseUrl() {
    final url = widget.url;
    if (url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      return WebUri('${uri.origin}/');
    } catch (_) {
      return null;
    }
  }

  Widget _buildContent() {
    final content = _effectiveContent;
    final kind = _renderKindFor(content);
    if (_shouldUseWeb(kind, content)) return _buildWebView(kind, content);
    switch (kind) {
      case ArtifactRenderKind.code:
        return _buildCodeRenderer(content);
      case ArtifactRenderKind.json:
        return _buildCodeRenderer(ArtifactWebDocument.prettyJson(content),
            language: 'json');
      case ArtifactRenderKind.csv:
        return _buildCsvNative(content);
      case ArtifactRenderKind.html:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: HtmlWidget(content, baseUrl: _baseUrl()),
        );
      case ArtifactRenderKind.markdown:
        return _buildMarkdownNative(content);
    }
  }

  /// 系统 WebView 主渲染：CSS/字体/表格/图片/脚本交给 Chromium。
  Widget _buildWebView(ArtifactRenderKind kind, String content) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_cachedHtml == null ||
        _cachedHtmlSource != content ||
        _cachedHtmlKind != kind ||
        _cachedHtmlDark != dark) {
      _cachedHtml = ArtifactWebDocument.document(
        kind: kind,
        content: content,
        dark: dark,
        title: widget.fileName ?? _title,
        language: widget.language,
      );
      _cachedHtmlSource = content;
      _cachedHtmlKind = kind;
      _cachedHtmlDark = dark;
    }
    final html = _cachedHtml!;
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: _baseUrl(),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        cacheMode: CacheMode.LOAD_NO_CACHE,
        builtInZoomControls: true,
        displayZoomControls: false,
      ),
      onWebViewCreated: (controller) {
        // 预览页里的链接不许把预览页替换掉：复制链接并提示。
        controller.addJavaScriptHandler(
          handlerName: 'onViewerLink',
          callback: (args) async {
            final href = args.isNotEmpty ? '${args.first}' : '';
            if (href.isEmpty) return;
            try {
              await Clipboard.setData(ClipboardData(text: href));
            } catch (_) {
              // 剪贴板不可用：仍提示链接内容，用户可手动抄录。
            }
            if (!mounted) return;
            _toast('链接已复制：$href');
          },
        );
      },
    );
  }

  /// 是否可用同源链接显示图片（需 http(s) 链接）。
  bool get _canShowImageViaUrl {
    final u = widget.url;
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// 用 WebView 直接加载图片链接：Chromium 自带缩放，且复用同源登录态——
  /// Dart 侧的 HttpClient 拿不到 WebView cookie jar，自拼请求只会 401。
  Widget _buildImageViewViaUrl() {
    return Column(
      children: [
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: false,
              cacheMode: CacheMode.LOAD_DEFAULT,
              builtInZoomControls: true,
              displayZoomControls: false,
            ),
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame ?? false) {
                debugPrint('VIEWER image url error: ${error.description}');
              }
            },
          ),
        ),
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            '云端路径读不到，已改用链接方式显示',
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ],
    );
  }

  /// 图片预览：双指缩放 + 真实像素尺寸提示。
  Widget _buildImageView(Uint8List bytes) {
    return InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('图片解码失败：$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 原生 Markdown：补上 selectable / onTapLink / imageBuilder 三个必需能力。
  Widget _buildMarkdownNative(String content) {
    final base = widget.url.isEmpty ? null : Uri.tryParse(widget.url);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: MarkdownBody(
        data: content,
        selectable: true, // 之前整页不可选中，想复制一段只能"复制全文"
        styleSheet: _markdownStyle(),
        onTapLink: (text, href, title) async {
          if (href == null || href.isEmpty) return;
          try {
            await Clipboard.setData(ClipboardData(text: href));
          } catch (_) {
            // 剪贴板不可用：仍提示链接内容，用户可手动抄录。
          }
          if (!mounted) return;
          _toast('链接已复制：$href');
        },
        sizedImageBuilder: (config) {
          // 相对路径必须手动 resolve：没有 baseUrl 时相对图片一律 404，
          // 于是"报告里所有截图都显示不出来"。
          var target = config.uri;
          if (target.scheme.isEmpty && base != null) {
          try {
            target = base.resolveUri(target);
          } catch (_) {
            // 非法相对路径 resolve 不了：保留原样交给 Image.network 自己报错。
          }
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 640),
            child: Image.network(
              target.toString(),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Text(
                '[图片加载失败：${config.alt ?? target.path}]',
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 原生 CSV 表格（横向可滚）。网页渲染才有"全部行"，这里为速度设上限。
  Widget _buildCsvNative(String content) {
    final rows = ArtifactWebDocument.parseDelimited(content);
    if (rows.isEmpty) {
      return const Center(child: Text('没有可解析的表格内容'));
    }
    const maxRows = 300;
    final shown = rows.length > maxRows ? rows.sublist(0, maxRows) : rows;
    final cols = shown.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    if (cols == 0) {
      return const Center(child: Text('没有可解析的表格内容'));
    }
    final header = shown.first;
    final scheme = Theme.of(context).colorScheme;
    // 纵向 + 横向各一层：只给横向一层时，纵向被 viewport 高度限死，
    // 表格超过约 15 行就直接 RenderFlex 溢出成黄黑花屏。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          DataTable(
            columns: [
              for (var c = 0; c < cols; c++)
                DataColumn(
                  label: SizedBox(
                    width: 160,
                    child: Text(
                      c < header.length ? header[c] : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
            rows: [
              for (final r in shown.skip(1))
                DataRow(
                  cells: [
                    for (var c = 0; c < cols; c++)
                      DataCell(SizedBox(
                        width: 160,
                        child: Text(
                          c < r.length ? r[c] : '',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '共 ${rows.length - 1} 行 · $cols 列'
            '${rows.length > shown.length ? '（原生模式仅显示前 ${shown.length - 1} 行，切"网页渲染"看全部）' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          ],
        ),
      ),
    );
  }

  // ---- 代码渲染参数：行号与代码必须用同一套字号/行高，否则行号会错位 ----
  static const double _codeFontSize = 13.5;
  static const double _codeLineHeight = 1.55;

  /// 高亮上限：超长文本让 highlight 库做全量着色会把 UI 线程卡死。
  static const int _maxHighlightedChars = 400 * 1024;

  TextStyle get _codeTextStyle => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['Menlo', 'Courier New'],
        fontSize: _codeFontSize,
        height: _codeLineHeight,
      );

  /// 代码渲染：flutter_highlight 语法高亮，主题跟随系统深浅色。
  ///
  /// 三处硬伤一起修掉：① 外层原来只有纵向滚动 → 长行被折行，缩进全毁；
  /// ② 无行号，报"第 37 行"要自己数；③ 不可选中，想拷一段代码只能整篇复制。
  Widget _buildCodeRenderer(String content, {String? language}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final theme = dark ? atomOneDarkTheme : atomOneLightTheme;
    final lang = (language ?? widget.language).trim();
    var text = content;
    var truncated = false;
    if (text.length > _maxHighlightedChars) {
      text = text.substring(0, _maxHighlightedChars);
      truncated = true;
    }
    final lineCount = '\n'.allMatches(text).length + 1;
    final showGutter = lineCount <= 5000;
    final gutterWidth =
        showGutter ? (30.0 + (lineCount.toString().length - 1) * 8.0) : 0.0;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (truncated)
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              '内容过长，仅显示前 ${(_maxHighlightedChars / 1024).round()}KB'
              '（切"网页渲染"或"另存为"可看全文）',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
      // 纵向在前、横向在后：外层给无限高、内层给无限宽，
      // RichText 因此不会折行，长行的缩进得以保住。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 20, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showGutter)
                SizedBox(
                  width: gutterWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 1; i <= lineCount; i++)
                        Text('$i',
                            textAlign: TextAlign.right,
                            style: _codeTextStyle.copyWith(
                              color: scheme.outlineVariant,
                            )),
                    ],
                  ),
                ),
              if (showGutter) const SizedBox(width: 10),
              // SelectionArea 而不是 HighlightView.selectable：这版
              // flutter_highlight 没有 selectable 参数，想选中一段代码只能整篇
              // 走右上角"复制全文"。
              SelectionArea(
                child: HighlightView(
                  text,
                  // 语言为空时以前完全不高亮：至少保留等宽 + 主题底色。
                  language: lang.isEmpty ? null : lang,
                  theme: theme,
                  textStyle: _codeTextStyle,
                ),
              ),
            ],
          ),
        ),
      ),
          ),
        ),
      ],
    );
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
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  /// 代码渲染：flutter_highlight 语法高亮，主题跟随系统深浅色。
}
