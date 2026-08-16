import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'setup_screen.dart';
import 'tunnel_service.dart';

/// 主界面：SSH 隧道就绪后，用 WebView 加载 DSH Web UI，并带缓存加速与设置入口。
///
/// 加载链路分两个阶段，均有可见反馈：
/// 1. SSH 隧道建立（连接中 → 已连接）；
/// 2. WebView 加载远程界面（进度条 + 阶段提示，超时/失败给出明确错误与重试）。
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _controller;
  SSHConfig _config = const SSHConfig();
  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  String? _error;
  StreamSubscription<TunnelStatus>? _tunnelSub;
  bool _reconnecting = false;

  // ---- 页面缩放（CSS zoom，持久化保存比例）----
  static const String _zoomPrefKey = 'webview_zoom_scale';
  static const double _zoomMin = 0.6;
  static const double _zoomMax = 2.5;
  static const double _zoomStep = 0.1;
  double _zoomScale = 1.0;

  // ---- WebView 页面加载状态 ----
  bool _pageLoading = false; // 远程页面加载中（隧道已通，页面未就绪）
  int _loadProgress = 0; // 0-100
  String? _pageError; // 页面加载错误（区别于隧道错误 _error）
  Timer? _loadTimeoutTimer;

  /// 首次通过 SSH 隧道加载 DSH 是体积较大的 SPA，给足时间。
  static const Duration _loadTimeout = Duration(seconds: 120);
  static const String _loadingHint =
      '首次加载需要从服务器传输界面资源，\n可能需要 1~2 分钟，请耐心等待。';

  @override
  void initState() {
    super.initState();
    // 监听隧道真实状态，状态变化时同步界面；仅在真正断开时自动重连。
    _tunnelSub = TunnelService.instance.statusStream.listen(_onTunnelStatus);
    _load();
    _loadZoomScale();
  }

  /// 读取持久化的缩放比例。
  Future<void> _loadZoomScale() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_zoomPrefKey);
    if (saved != null && mounted) {
      setState(() => _zoomScale = saved);
    }
  }

  /// 保存缩放比例（下次启动沿用）。
  Future<void> _saveZoomScale() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_zoomPrefKey, _zoomScale);
  }

  /// 通过 CSS zoom 应用缩放比例（页面就绪后调用）。
  Future<void> _applyZoom() async {
    final c = _controller;
    if (c == null) return;
    await c.evaluateJavascript(source:
      "document.documentElement.style.zoom = '${_zoomScale.toStringAsFixed(2)}'",
    );
  }

  void _adjustZoom(double delta) {
    final next = (_zoomScale + delta).clamp(_zoomMin, _zoomMax);
    if (next == _zoomScale) return;
    setState(() => _zoomScale = next);
    _saveZoomScale();
    _applyZoom();
  }

  void _resetZoom() {
    setState(() => _zoomScale = 1.0);
    _saveZoomScale();
    _applyZoom();
  }

  /// 隧道状态流回调：同步界面状态；断开/失败时带守卫自动重连。
  void _onTunnelStatus(TunnelStatus s) {
    if (!mounted) return;
    setState(() => _tunnelStatus = s);
    if (s == TunnelStatus.disconnected || s == TunnelStatus.failed) {
      _scheduleReconnect();
    }
  }

  /// 带守卫的自动重连：避免重复/并发重连造成死循环。
  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;
    Future<void>.delayed(const Duration(seconds: 2), () {
      _reconnecting = false;
      if (mounted) _connect();
    });
  }

  Future<void> _load() async {
    _config = await SSHConfig.load();
    _connect();
  }

  Future<void> _connect() async {
    // 已连接则跳过，避免冗余重连造成界面闪烁/循环
    if (TunnelService.instance.status == TunnelStatus.connected) return;
    setState(() {
      _error = null;
      _tunnelStatus = TunnelStatus.connecting;
      _pageError = null;
      _pageLoading = false;
    });
    try {
      await TunnelService.instance.connect(_config);
      if (!mounted) return;
      setState(() => _tunnelStatus = TunnelStatus.connected);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tunnelStatus = TunnelStatus.failed;
        _error = '$e';
      });
    }
  }

  Future<void> _disconnect() async {
    await TunnelService.instance.disconnect();
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    _tunnelSub?.cancel();
    _disconnect();
    super.dispose();
  }

  /// 刷新缓存：清缓存后重新加载。
  Future<void> _refreshCache() async {
    final c = _controller;
    if (c != null) {
      await InAppWebViewController.clearAllCache();
      await c.reload();
    }
  }

  Future<void> _openSettings() async {
    final connected = _tunnelStatus == TunnelStatus.connected;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetupScreen(
          initial: _config,
          showUiControls: connected,
          zoomScale: _zoomScale,
          onZoomIn: () => _adjustZoom(_zoomStep),
          onZoomOut: () => _adjustZoom(-_zoomStep),
          onResetZoom: _resetZoom,
          onRefreshCache: _refreshCache,
        ),
      ),
    );
    if (changed == true) {
      _config = await SSHConfig.load();
      await _disconnect();
      _connect();
    }
  }

  String get _targetUrl => 'http://127.0.0.1:${_config.localPort}';

  // ================= WebView 加载回调 =================

  void _onPageLoadStart() {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = true;
      _pageError = null;
      _loadProgress = 0;
    });
    // 超时保护：长时间卡住时提示用户，避免无限黑屏。
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      if (!mounted || !_pageLoading) return;
      setState(() {
        _pageLoading = false;
        _pageError = '加载超时（${_loadTimeout.inSeconds} 秒未完成）。\n'
            '请检查服务器状态、网络连接，或点重试。';
      });
    });
  }

  void _onPageProgress(int progress) {
    if (!mounted || !_pageLoading) return;
    setState(() => _loadProgress = progress);
  }

  void _onPageLoadStop() {
    _loadTimeoutTimer?.cancel();
    _pageRetryCount = 0;
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _loadProgress = 100;
    });
  }

  int _pageRetryCount = 0;

  void _onPageError(String message) {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _pageError = message;
    });
    // 有限次自动重试：隧道若刚断连会自动重连，页面重载后自愈
    _schedulePageRetry();
  }

  /// 页面加载失败后的有限自动重试（最多 3 次）。
  void _schedulePageRetry() {
    if (_pageRetryCount >= 3) return;
    _pageRetryCount++;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _pageError != null) _retryLoad();
    });
  }

  Future<void> _retryLoad() async {
    setState(() {
      _pageError = null;
      _pageLoading = true;
      _loadProgress = 0;
    });
    final c = _controller;
    if (c != null) {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(_targetUrl)));
    }
    _onPageLoadStart();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 边缘到边缘：顶栏延伸到系统状态栏区域（无 SafeArea 顶部留白）
      body: Column(
        children: [
          _buildTopBar(context),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 自定义全屏顶栏：背景延伸到状态栏区域（边缘到边缘），内容用 SafeArea 避让状态图标。
  Widget _buildTopBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Text('DSH-Phone', style: theme.textTheme.titleMedium),
            const Spacer(),
            _StatusChip(status: _tunnelStatus),
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.settings),
              onPressed: _openSettings,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_tunnelStatus) {
      case TunnelStatus.idle:
      case TunnelStatus.connecting:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在建立 SSH 隧道…'),
            ],
          ),
        );
      case TunnelStatus.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('连接失败：\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _openSettings,
                  child: const Text('修改设置'),
                ),
              ],
            ),
          ),
        );
      case TunnelStatus.connected:
        return Stack(
          fit: StackFit.expand,
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_targetUrl)),
              initialSettings: InAppWebViewSettings(
                // 本地缓存加速：优先用缓存，缺时才走网络
                cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
                // DSH 是含 WebSocket 的 SPA
                javaScriptEnabled: true,
                transparentBackground: false,
                // 原生双指缩放 + 缩放控件
                supportZoom: true,
                displayZoomControls: true,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStart: (controller, url) => _onPageLoadStart(),
              onProgressChanged: (controller, progress) =>
                  _onPageProgress(progress),
              onLoadStop: (controller, url) {
                _onPageLoadStop();
                // 页面就绪后应用持久化的缩放比例
                _applyZoom();
              },
              onReceivedError: (controller, request, error) => _onPageError(
                '加载失败：${error.description}\n'
                '（${error.type}）',
              ),
              onReceivedHttpError: (controller, response, error) =>
                  _onPageError(
                '服务器返回错误，请确认远程服务正常运行后重试。',
              ),
            ),
            // 页面加载中：进度遮罩（不透明白底，避免黑屏观感）
            if (_pageLoading && _pageError == null)
              _buildPageLoading(context),
            // 页面加载失败/超时：错误界面
            if (_pageError != null) _buildPageError(context),
          ],
        );
      case TunnelStatus.disconnected:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 48),
              const SizedBox(height: 16),
              const Text('隧道已断开'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ],
          ),
        );
    }
  }

  /// WebView 加载中的进度遮罩。
  Widget _buildPageLoading(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.dns_outlined, size: 56, color: Colors.indigo),
            const SizedBox(height: 24),
            Text('隧道已连接，正在加载远程界面…',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text(
              _loadingHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
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

  /// WebView 加载失败/超时界面。
  Widget _buildPageError(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.red),
              const SizedBox(height: 16),
              Text('无法加载远程界面',
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
                onPressed: _retryLoad,
                icon: const Icon(Icons.refresh),
                label: const Text('重试加载'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _openSettings,
                child: const Text('修改设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      TunnelStatus.idle => ('空闲', Colors.grey),
      TunnelStatus.connecting => ('连接中', Colors.orange),
      TunnelStatus.connected => ('已连接', Colors.green),
      TunnelStatus.failed => ('失败', Colors.red),
      TunnelStatus.disconnected => ('已断开', Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        backgroundColor: color.withValues(alpha: 0.2),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
