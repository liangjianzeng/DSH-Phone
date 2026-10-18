import 'dart:async';

import 'package:flutter/material.dart';
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

  /// 刷新缓存：清缓存后重新加载（与 Unsloth 页面一致）。
  Future<void> _refreshCache() async {
    final c = _controller;
    if (c == null) return;
    await InAppWebViewController.clearAllCache();
    await c.reload();
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
            '请检查网络连接后重试。';
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

  /// 重试加载：强制重新导航到目标地址；控制器未就绪则重新走初始加载。
  Future<void> _retry() async {
    final c = _controller;
    if (c == null) {
      await _loadInitial();
      return;
    }
    _onPageLoadStart();
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(_target)));
    _loadedTarget = _target;
    if (!mounted) return;
    setState(() => _pageError = null);
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
              tooltip: '刷新缓存',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshCache,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    // 页面错误（初始加载失败 / 超时 / 网络错误）
    if (_pageError != null) {
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
                  '$_pageError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return InAppWebView(
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
  }
}
