import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'config.dart';

/// GitHub 仓库快捷访问页面：复用现有 WebView 能力加载 github.com，
/// 支持本地缓存加速（优先用缓存，缺时才走网络）与登录态持久化（Cookie）。
///
/// 两种登录方式：
/// - 网页登录（默认 / 路线 A）：用户像用手机浏览器一样在 WebView 内完成
///   GitHub 授权，Cookie 由 WebView 持久化，重启后免重复登录。
/// - 令牌登录（路线 B）：填写 fine-grained PAT 后，进入时把地址换成
///   `https://x-access-token:<token>@github.com`，由 GitHub 从 Authorization
///   头建立会话，彻底绕开 WebView 内的 OAuth 跳转。
///
/// 访问地址默认 https://github.com，可在设置里覆盖（如 GitHub Enterprise）。

/// 给界面/日志用的地址：**必须剥掉 `x-access-token:<PAT>@`  userinfo**，
/// 否则 PAT 会被显示在错误卡片上、被用户复制走、甚至进截图与日志。
String githubDisplayTarget(String url) {
  final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@').firstMatch(url);
  if (m == null) return url;
  return '${m.group(1)}…@${url.substring(m.end)}';
}
class GitHubScreen extends StatefulWidget {
  const GitHubScreen({super.key, this.timeoutSeconds = 60});

  /// 页面加载超时（秒）。
  final int timeoutSeconds;

  @override
  State<GitHubScreen> createState() => _GitHubScreenState();
}

class _GitHubScreenState extends State<GitHubScreen> {
  InAppWebViewController? _controller;

  /// 目标地址：默认 github.com；异步读配置后更新（令牌登录换 x-access-token
  /// 前缀，自定义地址覆盖 GHE）。
  String _target = 'https://github.com';

  /// 已导航到的地址（去重，避免与 initialUrlRequest 重复加载）。
  String _loadedTarget = 'https://github.com';

  // ---- PAT 令牌 ----
  String _currentToken = '';
  late TextEditingController _tokenCtrl;

  // ---- 页面加载状态 ----
  bool _pageLoading = false;
  String? _pageError;
  Timer? _loadTimeoutTimer;

  Duration get _loadTimeout => Duration(seconds: widget.timeoutSeconds);

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController();
    // 异步读取地址/令牌并发起首次加载；读取失败不崩溃，回退默认 github.com。
    _loadInitial();
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    _tokenCtrl.dispose();
    super.dispose();
  }

  /// 读取配置（地址 + 令牌），构造目标地址后开始加载。
  Future<void> _loadInitial() async {
    final base = await SSHConfig.loadGithubUrl();
    final token = await SSHConfig.loadGithubToken();
    if (!mounted) return;
    setState(() {
      _currentToken = token.trim();
      _tokenCtrl.text = _currentToken;
    });
    // 路线 B：有令牌时用 x-access-token 前缀自动认证（PAT 为字母数字连字符，无需转义）。
    final target = _currentToken.isNotEmpty
        ? 'https://x-access-token:$_currentToken@github.com'
        : base;
    setState(() => _target = target);
    _ensureLoaded();
  }

  /// 确保 WebView 已导航到 [_target]：控制器就绪则导航；已与当前地址一致则跳过。
  void _ensureLoaded() {
    final c = _controller;
    if (c == null) return;
    if (_loadedTarget == _target) return;
    _onPageLoadStart();
    c.loadUrl(urlRequest: URLRequest(url: WebUri(_target)));
    _loadedTarget = _target;
  }

  /// **强制走网络**重载当前页面。
  ///
  /// 两个坑，都是"页面看着像有缓存、但缓存以外的一直没刷出来"的成因：
  ///  1. 裸 `reload()` 照样命中 HTTP 缓存（旧配置还是 LOAD_CACHE_ELSE_NETWORK，
  ///     命中就根本不上网，连一次失败的导航都被反复复用）→ 这里把 cacheMode
  ///     临时压成 LOAD_NO_CACHE，刷完恢复 LOAD_DEFAULT；不能长期关缓存，
  ///     GitHub 静态资源带内容哈希，缓存是有益的。
  ///  2. 旧实现调 `clearAllCache()` 清的是**整个 App 的 WebView 缓存**，
  ///     顺手把 DSH 隧道页面的加速缓存也清了（那是特性）→ 不再使用。
  Future<void> _reloadIgnoringCache() async {
    final c = _controller;
    if (c == null) {
      await _loadInitial();
      return;
    }
    _onPageLoadStart();
    try {
      await c.setSettings(
          settings: InAppWebViewSettings(cacheMode: CacheMode.LOAD_NO_CACHE));
      await c.reload();
    } catch (_) {
      // 控制器已失效（极少见）：交回初始加载路径重建。
      _loadedTarget = '';
      await _loadInitial();
      } finally {
        try {
          await c.setSettings(
              settings: InAppWebViewSettings(cacheMode: CacheMode.LOAD_DEFAULT));
        } catch (_) {
          // 控制器已随页面销毁：缓存模式恢复不了也无妨，下次建 WebView 会重置。
        }
      }
  }

  /// 打开 PAT 令牌输入对话框（在 GitHub 页面内即可配置令牌，免翻设置页）。
  Future<void> _editToken() async {
    _tokenCtrl.text = _currentToken;
    final newToken = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('个人访问令牌（PAT）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '在 GitHub → Settings → Developer settings → '
              'Fine-grained personal access tokens 生成，'
              '勾选 contents: read 即可只读浏览仓库。\n\n'
              '留空则使用网页登录（需在网页内登录一次）。',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                hintText: '留空则使用网页登录',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.maybePop(context, _tokenCtrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newToken == null) return;
    await _saveToken(newToken);
  }

  /// 保存令牌并带令牌重新加载（路线 B：x-access-token 前缀自动认证）。
  Future<void> _saveToken(String raw) async {
    final token = raw.trim();
    await SSHConfig.saveGithubToken(token);
    if (!mounted) return;
    final base = await SSHConfig.loadGithubUrl();
    final target = token.isNotEmpty
        ? 'https://x-access-token:$token@github.com'
        : base;
    setState(() {
      _currentToken = token;
      _target = target;
      _loadedTarget = ''; // 强制重新导航
    });
    _ensureLoaded();
  }

  // ================= 页面加载回调 =================

  void _onPageLoadStart() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = true;
      _pageError = null;
    });
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || !_pageLoading) return;
      setState(() {
        _pageLoading = false;
        _pageError = '加载超时（${_loadTimeout.inSeconds} 秒未完成）。\n'
            'github.com 直连常不通，请先确认 VPN / 代理已开启，再点「强制刷新」；'
            '仍不通可在设置里把访问地址改为镜像或企业版地址。';
      });
    });
  }

  void _onPageLoadStop() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
    });
  }

  void _onPageError(String message) {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _pageError = message;
    });
  }

  /// 重试：**绕过缓存**重新导航（见 [_reloadIgnoringCache]）。
  Future<void> _retry() async {
    if (!mounted) return;
    setState(() => _pageError = null);
    await _reloadIgnoringCache();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          _buildTopBar(context),
          Expanded(
            child: ColoredBox(color: scheme.surface, child: _buildBody(context)),
          ),
        ],
      ),
    );
  }

  /// 紧凑顶栏：与 Unsloth 页面同构——背景延伸到状态栏，内容由图标驱动（48dp）。
  Widget _buildTopBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'GitHub',
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'PAT 令牌登录',
              icon: Icon(_currentToken.isNotEmpty ? Icons.login : Icons.key_outlined),
              onPressed: _editToken,
            ),
            IconButton(
              tooltip: '强制刷新（忽略缓存）',
              icon: const Icon(Icons.refresh),
              onPressed: _reloadIgnoringCache,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final webview = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_target)),
      initialSettings: InAppWebViewSettings(
        // 本地缓存加速：优先用缓存，缺时才走网络（与 Unsloth 一致）。
        cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
        javaScriptEnabled: true,
        // 现代 SPA（github.com）需要 DOM 存储，保留 Cookie 以持久登录态。
        domStorageEnabled: true,
        transparentBackground: false,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        // 控制器就绪后确保加载目标地址（首次加载 / 令牌登录后重定向）。
        _ensureLoaded();
      },
      onLoadStart: (controller, url) => _onPageLoadStart(),
      onLoadStop: (controller, url) => _onPageLoadStop(),
      // 仅主框架加载失败才视为致命错误；子资源忽略以免误报。
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == false) return;
        _onPageError('加载失败：${error.description}\n（${error.type}）');
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame == false) return;
        final code = errorResponse.statusCode;
        // 401/403/404 由 GitHub 自行处理（登录/鉴权/路由），不致命。
        if (code != null && (code == 401 || code == 403 || code == 404)) {
          return;
        }
        _onPageError('服务器返回错误（$code），请检查网络后重试。');
      },
    );

    final err = _pageError;
    if (err == null) return webview;
    // 错误态**不销毁** WebView，而是盖一层卡片。旧实现在这里直接 return 卡片，
    // InAppWebView 被卸载、控制器随之失效，"重试"于是对着一个已销毁的控制器
    // loadUrl——页面永远刷不出来，症状和"缓存卡住"一模一样。
    return Stack(
      fit: StackFit.expand,
      children: [
        webview,
        ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: _buildErrorCard(context, err),
        ),
      ],
    );
  }

  Widget _buildErrorCard(BuildContext context, String message) {
    final shown = githubDisplayTarget(_target);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('无法加载 GitHub',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            const SizedBox(height: 10),
            // 显示真正去访问的地址（令牌已剥离），便于判断是不是镜像/代理的问题。
            SelectionArea(
              child: Text(
                shown,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('强制刷新'),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: shown));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制访问地址')),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制地址'),
            ),
          ],
        ),
      ),
    );
  }
}
