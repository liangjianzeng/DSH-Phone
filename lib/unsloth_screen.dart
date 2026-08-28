import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'config.dart';
import 'tunnel_service.dart';

/// Unsloth Studio 页面：复用现有 WebView 能力加载远程服务，支持缓存加载、
/// 缓存刷新，以及登录页自动登录（用户配置登录密码）。
///
/// 两种连接方式（实例级配置）：
/// - HTTP 直连（默认）：WebView 直接加载 `http://<host>:<unslothPort>`
/// - SSH 隧道：复用当前活动 SSH 会话开启第二转发通道，本地端口由 OS
///   动态分配，WebView 加载 `http://127.0.0.1:<本地端口>`
///
/// 自动登录针对 Unsloth Studio 登录页（用户名固定 `unsloth`，仅一个密码框）：
/// documentEnd 注入填充脚本，检测到登录表单后用原生 setter 填密码并提交；
/// 尝试后仍停留在登录页时回调 Flutter 提示检查密码。
class UnslothScreen extends StatefulWidget {
  const UnslothScreen({
    super.key,
    required this.config,
    required this.profileIndex,
    this.timeoutSeconds = 60,
  });

  /// 当前实例配置（含 unsloth 字段）。
  final SSHConfig config;

  /// 当前实例索引（用于日志标识）。
  final int profileIndex;

  /// 页面加载超时（秒）。
  final int timeoutSeconds;

  @override
  State<UnslothScreen> createState() => _UnslothScreenState();
}

class _UnslothScreenState extends State<UnslothScreen> {
  InAppWebViewController? _controller;

  /// SSH 模式时 OS 动态分配的本地转发端口；直连模式为 null。
  int? _localPort;
  bool _connecting = false;

  // ---- 页面加载状态 ----
  bool _pageLoading = false;
  int _loadProgress = 0;
  String? _pageError;
  Timer? _loadTimeoutTimer;

  Duration get _loadTimeout => Duration(seconds: widget.timeoutSeconds);

  @override
  void initState() {
    super.initState();
    if (widget.config.unslothUseSsh) {
      _startForward();
    }
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    // 关闭 Unsloth Studio 转发（若 SSH 模式已开启）
    TunnelService.instance.stopUnslothForward();
    super.dispose();
  }

  /// SSH 模式：复用活动会话开启第二转发，拿到本地端口后加载。
  Future<void> _startForward() async {
    setState(() {
      _connecting = true;
      _pageError = null;
    });
    final port =
        await TunnelService.instance.startUnslothForward(widget.config);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _localPort = port;
    });
    if (port == null) {
      _onPageError('无法建立 SSH 转发（配置缺失/认证失败/绑定失败）。\n'
          '请检查该实例的 SSH 配置，或在设置中改用 HTTP 直连。');
    }
  }

  /// 目标地址：SSH 模式走本地转发端口；直连模式走主机 + 配置端口。
  String? get _targetUrl {
    if (widget.config.unslothUseSsh) {
      final p = _localPort;
      return p == null ? null : 'http://127.0.0.1:$p';
    }
    return 'http://${widget.config.host}:${widget.config.unslothPort}';
  }

  /// 自动登录桥脚本模板。`__PASSWORD__` 占位符替换为 JSON 转义的密码。
  ///
  /// Unsloth Studio 登录页（React 受控表单）：用户名固定 `unsloth`，
  /// 仅一个密码输入框（id=password）。脚本用原生 value setter + input 事件
  /// 触发 React onChange，再 `requestSubmit()` 提交表单。
  static const String _autoLoginBridgeJs = r'''
(function() {
  if (window.__dshUnslothAutoLogin) return;
  window.__dshUnslothAutoLogin = true;
  var attempted = false;

  function submitForm(pw) {
    var form = pw.closest('form');
    if (!form) return;
    attempted = true;
    setTimeout(function() {
      try {
        if (form.requestSubmit) form.requestSubmit();
        else form.submit();
      } catch (e) { form.submit(); }
    }, 120);
  }

  function attempt() {
    if (attempted) return;
    var pw = document.getElementById('password');
    if (!pw) return;
    // 密码框已有值（预填/用户已输入）：直接提交
    if (pw.value && pw.value.length > 0) { submitForm(pw); return; }
    // React 受控输入：原生 setter + input 事件
    var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    try {
      setter.call(pw, __PASSWORD__);
      pw.dispatchEvent(new Event('input', { bubbles: true }));
    } catch (e) { return; }
    submitForm(pw);
  }

  // 页面就绪后尝试；SPA 异步渲染登录表单，延迟多次重试
  attempt();
  setTimeout(attempt, 600);
  setTimeout(attempt, 1500);
  setTimeout(attempt, 3000);
  setTimeout(attempt, 5000);

  // 自动登录失败检测：尝试后仍停留在登录页（#password 存在且路径含 /login）
  setTimeout(function() {
    if (!attempted) return;
    var pw = document.getElementById('password');
    if (pw && /\/login/.test(window.location.pathname)) {
      try {
        window.flutter_inappwebview.callHandler('onUnslothLoginFailed', {});
      } catch (e) {}
    }
  }, 6000);
})();
''';

  /// 生成注入脚本：替换密码占位符（jsonEncode 保证引号/反斜杠安全）。
  String _buildAutoLoginScript() {
    return _autoLoginBridgeJs.replaceFirst(
        '__PASSWORD__', jsonEncode(widget.config.unslothPassword));
  }

  /// 刷新缓存：清缓存后重新加载（与主界面 DSH 页面一致的能力）。
  Future<void> _refreshCache() async {
    final c = _controller;
    if (c == null) return;
    await InAppWebViewController.clearAllCache();
    await c.reload();
  }

  // ================= 页面加载回调 =================

  void _onPageLoadStart() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = true;
      _pageError = null;
      _loadProgress = 0;
    });
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || !_pageLoading) return;
      setState(() {
        _pageLoading = false;
        _pageError = '加载超时（${_loadTimeout.inSeconds} 秒未完成）。\n'
            '请检查服务器状态、网络连接后重试。';
      });
    });
  }

  void _onPageProgress(int progress) {
    if (!mounted || !_pageLoading) return;
    setState(() => _loadProgress = progress);
  }

  void _onPageLoadStop() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _loadProgress = 100;
    });
    // 页面就绪后注入自动登录脚本（含延迟重试等待 SPA 渲染登录表单）
    if (widget.config.unslothPassword.isNotEmpty) {
      final c = _controller;
      if (c != null) {
        c.evaluateJavascript(source: _buildAutoLoginScript());
      }
    }
  }

  void _onPageError(String message) {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _pageError = message;
    });
  }

  /// 重试加载：SSH 模式重新建立转发，随后重建 WebView 加载新地址。
  Future<void> _retry() async {
    if (widget.config.unslothUseSsh) {
      await _startForward();
      if (!mounted) return;
      // 转发失败：_startForward 已置 _pageError，直接返回
      if (_localPort == null) return;
    }
    setState(() {
      _pageError = null;
      _pageLoading = true;
      _loadProgress = 0;
    });
    _onPageLoadStart();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unsloth Studio'),
        actions: [
          IconButton(
            tooltip: '刷新缓存',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshCache,
          ),
        ],
      ),
      body: ColoredBox(color: scheme.surface, child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    // SSH 模式转发建立中
    if (_connecting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在建立 SSH 转发…'),
          ],
        ),
      );
    }
    // 转发失败 / 页面错误
    if (_pageError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('无法加载 Unsloth Studio',
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
    final url = _targetUrl;
    if (url == null) {
      return const Center(child: Text('地址无效，请检查配置'));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(url)),
          initialSettings: InAppWebViewSettings(
            // 本地缓存加速：优先用缓存，缺时才走网络
            cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
            javaScriptEnabled: true,
            transparentBackground: false,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            // 自动登录失败回调：提示检查密码
            if (widget.config.unslothPassword.isNotEmpty) {
              controller.addJavaScriptHandler(
                handlerName: 'onUnslothLoginFailed',
                callback: (args) async {
                  if (!mounted) return null;
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(const SnackBar(
                      content: Text('自动登录失败：请检查登录密码是否正确'),
                    ));
                  return null;
                },
              );
            }
          },
          onLoadStart: (controller, url) => _onPageLoadStart(),
          onProgressChanged: (controller, progress) =>
              _onPageProgress(progress),
          onLoadStop: (controller, url) => _onPageLoadStop(),
          // 仅主框架加载失败才视为致命错误；子资源（图片/脚本/API 等）
          // 失败不影响页面使用，忽略以免误报"无法加载"。
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame == false) return;
            _onPageError('加载失败：${error.description}\n（${error.type}）');
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            if (request.isForMainFrame == false) return;
            // 401/403/404 由 SPA 自行处理（登录/鉴权/客户端路由），不致命
            final code = errorResponse.statusCode;
            if (code != null && (code == 401 || code == 403 || code == 404)) {
              return;
            }
            _onPageError('服务器返回错误（$code），'
                '请确认远程服务正常运行后重试。');
          },
        ),
        // 页面加载中：进度遮罩
        if (_pageLoading && _pageError == null) _buildPageLoading(context),
      ],
    );
  }

  Widget _buildPageLoading(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_outlined, size: 56, color: Colors.indigo),
            const SizedBox(height: 24),
            Text('正在加载远程 Unsloth Studio…',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            LinearProgressIndicator(value: _loadProgress / 100),
            const SizedBox(height: 12),
            Text('$_loadProgress%',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
