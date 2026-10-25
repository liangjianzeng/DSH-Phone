/// 成果识别器：根据点击目标（DOM 元素信息 + URL）判断"点的是什么成果"，
/// 以及应如何获取其内容。
///
/// 设计目标：DSH 的成果 DOM 结构我们不完全掌握，因此把判定依据做成
/// **规则常量表**（[rules]），方便按实际页面微调，而不写死在渲染逻辑里。
library;

/// 成果类型。
enum ArtifactType { markdown, html, code, file, resource, none }

/// 识别结果。
class ArtifactHit {
  const ArtifactHit({
    required this.type,
    this.url = '',
    this.language = '',
    this.content = '',
    this.path = '',
    this.dirs = const [],
    this.error = '',
  });

  final ArtifactType type;

  /// 成果地址（文件型成果的 href），空表示无需联网获取。
  final String url;

  /// 代码块的语言（用于语法高亮），空表示未知。
  final String language;

  /// 已内联的原始内容（代码块/markdown 由 JS 侧直接提取）。
  final String content;

  /// 云端主机上的文件路径（文件型成果按钮的 title/aria-label），
  /// 用于通过 SSH 读取文件内容。
  final String path;

  /// 候选目录列表：path 只有文件名时，用这些目录拼接定位（chips 被隐藏场景）。
  final List<String> dirs;

  /// JS 侧取内容失败的原因（旧实现失败时只回传空串，界面于是显示
  /// "无内容可查看"——既不说是失败，也不说为什么失败，用户无从下手）。
  final String error;

  bool get isNone => type == ArtifactType.none;
}

/// 识别规则表：按顺序匹配，命中即返回。可随 DSH 页面结构调整。
class ArtifactRules {
  const ArtifactRules();

  /// 文件型成果：href 指向后端文件路径。
  /// DSH 常见模式：`/api/files/...`、`/files/...`、以及 `.md/.html/.htm` 后缀。
  static const List<String> fileUrlPrefixes = [
    '/api/files/',
    '/files/',
    '/api/artifact/',
    '/artifacts/',
  ];

  static const List<String> fileUrlSuffixes = [
    '.md',
    '.markdown',
    '.html',
    '.htm',
    '.txt',
    '.json',
    '.csv',
  ];

  /// 可查看的文本类后缀（用原生查看器渲染）。
  ///
  /// 原来只有 22 项，`.log/.tsv/.ini/.tsx/.jsx/.rs/.rb/.php/.css/.vue/.diff`
  /// 等一概不在表内；由于未知后缀默认按文本处理，真正踩坑的是**二进制被当文本**
  /// （见 [resourceSuffixes]），以及链接型成果因后缀判不出而走错分支。
  static const List<String> viewableSuffixes = [
    '.md', '.markdown', '.html', '.htm', '.txt', '.json', '.csv',
    '.py', '.dart', '.js', '.ts', '.c', '.cpp', '.java', '.go',
    '.sh', '.bash', '.yml', '.yaml', '.toml', '.sql', '.xml',
    '.log', '.tsv', '.ini', '.conf', '.cfg', '.properties', '.env',
    '.tsx', '.jsx', '.rs', '.rb', '.php', '.css', '.scss', '.vue',
    '.kt', '.swift', '.lua', '.pl', '.r', '.m', '.h', '.hpp',
    '.diff', '.patch', '.proto', '.graphql', '.tf', '.gradle',
    '.ipynb', '.ipynb.json', '.plist', '.tex', '.bibtex', '.srt',
    '.makefile', '.dockerfile', '.gitignore', '.editorconfig',
  ];

  /// 资源类后缀（apk/压缩包等二进制，走下载保存流程）。
  static const List<String> resourceSuffixes = [
    '.apk', '.zip', '.tar', '.gz', '.tgz', '.rar', '.7z', '.xz',
    '.bin', '.exe', '.msi', '.dmg', '.iso', '.img', '.mp4', '.mp3',
    '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.doc',
    '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.so', '.a', '.dll',
    '.deb', '.rpm', '.jar', '.war', '.whl', '.bz2', '.zst', '.z',
    '.class', '.o', '.pyc', '.wav', '.flac', '.ogg', '.mov', '.mkv',
    '.avi', '.tiff', '.bmp', '.ico', '.ttf', '.otf', '.woff', '.woff2',
    '.sqlite', '.db', '.pdb', '.unityas', '.pack', '.bak',
  ];

  /// 去掉 URL/路径上的查询串与片段，并小写，用于后缀判定。
  ///
  /// 关键修复：`typeOfPath` 原来直接 `lower.endsWith(s)`，而 DSH 的链接常带
  /// `?token=…`/`#sha=…`，于是 `app.apk?token=x` **判不出是资源**，被当文本读进
  /// 内存渲染成乱码；JS 侧那份正则倒是处理了 `?`/`#`，两边规则不一致。
  static String normalizeForSuffix(String pathOrUrl) {
    var s = pathOrUrl.trim();
    final cut = s.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) s = s.substring(0, cut);
    // 结尾的目录分隔符会让 `.apk/` 之类判不出后缀
    while (s.length > 1 && (s.endsWith('/') || s.endsWith(r'\'))) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  /// 无后缀但众所周知是文本的文件名。
  static const Set<String> knownTextNames = {
    'makefile', 'dockerfile', 'readme', 'license', 'agents.md', 'changelog',
    'gemfile', 'rakefile', 'procfile', 'justfile',
  };

  /// 按文件路径后缀判断属于可查看文本还是资源（二进制）。
  ///
  /// 后缀判定一律先过 [normalizeForSuffix]：带 `?query`、`#fragment`、结尾斜杠
  /// 的路径以前都会误判。
  static ArtifactType typeOfPath(String path) {
    final lower = normalizeForSuffix(path);
    if (lower.isEmpty) return ArtifactType.file;
    if (resourceSuffixes.any((s) => lower.endsWith(s))) {
      return ArtifactType.resource;
    }
    // 带版本号的动态库（`libfoo.so.1`、`libfoo.so.1.2.3`）：后缀 endsWith 判不出，
    // 但它们是纯二进制，进文本查看器就是一片乱码 + 卡顿。
    if (lower.contains('.so.')) return ArtifactType.resource;
    if (viewableSuffixes.any((s) => lower.endsWith(s))) {
      return ArtifactType.file;
    }
    // 无后缀的知名文本文件（Makefile / Dockerfile / README…）按文本处理
    final base = lower.replaceAll(RegExp(r'[/\\]'), '').trim();
    if (knownTextNames.contains(base)) return ArtifactType.file;
    // 无明确后缀：默认按可查看文本处理（可能是代码/未知）
    return ArtifactType.file;
  }

  /// 图片类：预览要用 InteractiveViewer，而不是任何文本渲染器。
  static bool isImageSuffix(String pathOrUrl) {
    final lower = normalizeForSuffix(pathOrUrl);
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.ico') ||
        lower.endsWith('.tiff');
  }

  /// 安卓系统 WebView 渲染不了的文档后缀（无 PDF 插件、无 office 渲染器）。
  ///
  /// 与 webview_bridges.dart 里 artifactBridgeJs 的 passPreviewRe **两处必须
  /// 一致**：这些类型的成果 chips 点击已放行给 DSH Web 自带 pdf.js 预览；
  /// 失败卡片上的「用网页方式打开」对它们只会白屏，按此隐藏。
  static const Set<String> _webviewUnrenderableSuffixes = {
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  };

  static bool isWebviewUnrenderable(String pathOrUrl) {
    final lower = normalizeForSuffix(pathOrUrl);
    return _webviewUnrenderableSuffixes.any(lower.endsWith);
  }

  /// 代码块命中：点击落在 pre/code 内（由 JS 侧判定，这里只做类型归类）。
  static bool isCodeTarget(String tagName) =>
      tagName == 'PRE' || tagName == 'CODE';

  /// 文件型：href 命中文件规则。
  ///
  /// 与 [typeOfPath] 一样先过 [normalizeForSuffix]：`/api/files/x.md?token=y`
  /// 这类带查询串的链接以前 `endsWith` 一律判不出，只能靠前缀碰运气。
  static bool isFileUrl(String url) {
    final raw = url.toLowerCase();
    if (fileUrlPrefixes.any((p) => raw.contains(p.toLowerCase()))) {
      return true;
    }
    final lower = normalizeForSuffix(url);
    return fileUrlSuffixes.any((s) => lower.endsWith(s));
  }
}

/// 把 JS 桥返回的原始 Map 解析成 [ArtifactHit]。
///
/// JS 侧会回传形如 `{ type, url, language }` 的字典；这里做防御性解析，
/// 字段缺失时降级为 [ArtifactType.none]。
ArtifactHit parseArtifactHit(Map<Object?, Object?> raw) {
  final typeStr = (raw['type'] as String?)?.toLowerCase() ?? '';
  final url = (raw['url'] as String?) ?? '';
  final language = (raw['language'] as String?) ?? '';
  final content = (raw['content'] as String?) ?? '';
  final path = (raw['path'] as String?) ?? '';
  final error = (raw['error'] as String?) ?? '';
  final dirsRaw = raw['dirs'];
  final dirs = <String>[
    if (dirsRaw is List)
      for (final d in dirsRaw)
        if (d is String && d.isNotEmpty) d,
  ];

  var type = switch (typeStr) {
    'markdown' => ArtifactType.markdown,
    'html' => ArtifactType.html,
    'code' => ArtifactType.code,
    'file' => ArtifactType.file,
    'resource' => ArtifactType.resource,
    _ => ArtifactType.none,
  };
  // 防御性路由 ①：文件型若带资源后缀（apk/zip 等），强制归为资源（走下载），
  // 避免二进制内容进入文本查看器导致灰屏。
  if (type == ArtifactType.file && path.isNotEmpty) {
    final byPath = ArtifactRules.typeOfPath(path);
    if (byPath == ArtifactType.resource) {
      type = ArtifactType.resource;
    }
  }
  // 防御性路由 ②：只有链接、没有远端路径的成果（`/api/files/app.apk?token=…`）。
  // JS 那份后缀正则虽然处理了 `?`/`#`，但 Dart 这侧必须独立判得出来——否则
  // 二进制被当文本读入并渲染，就是"点开一片乱码/卡死"。
  if (type == ArtifactType.file && path.isEmpty && url.isNotEmpty) {
    if (ArtifactRules.typeOfPath(url) == ArtifactType.resource) {
      type = ArtifactType.resource;
    }
  }
  return ArtifactHit(
    type: type,
    url: url,
    language: language,
    content: content,
    path: path,
    dirs: dirs,
    error: error,
  );
}
