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
  static const List<String> viewableSuffixes = [
    '.md', '.markdown', '.html', '.htm', '.txt', '.json', '.csv',
    '.py', '.dart', '.js', '.ts', '.c', '.cpp', '.java', '.go',
    '.sh', '.bash', '.yml', '.yaml', '.toml', '.sql', '.xml',
  ];

  /// 资源类后缀（apk/压缩包等二进制，走下载保存流程）。
  static const List<String> resourceSuffixes = [
    '.apk', '.zip', '.tar', '.gz', '.tgz', '.rar', '.7z', '.xz',
    '.bin', '.exe', '.msi', '.dmg', '.iso', '.img', '.mp4', '.mp3',
    '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.doc',
    '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.so', '.a', '.dll',
  ];

  /// 代码块命中：点击落在 pre/code 内（由 JS 侧判定，这里只做类型归类）。
  static bool isCodeTarget(String tagName) =>
      tagName == 'PRE' || tagName == 'CODE';

  /// 文件型：href 命中文件规则。
  static bool isFileUrl(String url) {
    final lower = url.toLowerCase();
    return fileUrlPrefixes.any((p) => lower.contains(p.toLowerCase())) ||
        fileUrlSuffixes.any((s) => lower.endsWith(s));
  }

  /// 按文件路径后缀判断属于可查看文本还是资源（二进制）。
  static ArtifactType typeOfPath(String path) {
    final lower = path.toLowerCase();
    if (resourceSuffixes.any((s) => lower.endsWith(s))) {
      return ArtifactType.resource;
    }
    if (viewableSuffixes.any((s) => lower.endsWith(s))) {
      return ArtifactType.file;
    }
    // 无明确后缀：默认按可查看文本处理（可能是代码/未知）
    return ArtifactType.file;
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
  // 防御性路由：文件型若带资源后缀（apk/zip 等），强制归为资源（走下载），
  // 避免二进制内容进入文本查看器导致灰屏。
  if (type == ArtifactType.file && path.isNotEmpty) {
    final byPath = ArtifactRules.typeOfPath(path);
    if (byPath == ArtifactType.resource) {
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
  );
}
