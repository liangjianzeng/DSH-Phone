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
///
/// 支持最多 3 路 SSH 实例配置，顶部状态栏可自由切换激活实例。
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _controller;

  // ---- 多实例配置 ----
  List<SSHConfig> _profiles = List.filled(SSHConfig.maxProfiles, const SSHConfig());
  int _activeIndex = 0;
  SSHConfig _config = const SSHConfig();

  // ---- 页面加载超时（秒），可配置，默认 60，最大 180 ----
  int _timeoutSeconds = SSHConfig.defaultTimeoutSeconds;

  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  String? _error;
  StreamSubscription<TunnelStatus>? _tunnelSub;
  bool _reconnecting = false;
  bool _switching = false; // 手动切换实例时抑制自动重连

  /// 连续自动重连次数上限：防止"死循环连接"刷屏/耗尽资源。
  static const int _maxReconnect = 5;
  int _reconnectCount = 0;

  // ---- 页面缩放（CSS zoom，持久化保存比例）----
  static const String _zoomPrefKey = 'webview_zoom_scale';
  static const double _zoomMin = 0.6;
  static const double _zoomMax = 2.5;
  static const double _zoomStep = 0.1;

  /// 缩放比例共享通知器：设置页可实时监听并展示。
  final ValueNotifier<double> _zoomScaleNotifier = ValueNotifier<double>(1.0);

  // ---- WebView 页面加载状态 ----
  bool _pageLoading = false; // 远程页面加载中（隧道已通，页面未就绪）
  int _loadProgress = 0; // 0-100
  String? _pageError; // 页面加载错误（区别于隧道错误 _error）
  Timer? _loadTimeoutTimer;

  /// VPN 组网 UDP QoS 友好提示：跨运营商 UDP 可能被限速/丢包导致请求缓慢超时，
  /// 建议端侧与云端联网在同一网络运营商下使用。
  static const String _qosHint =
      '\n\n提示：VPN 组网（WireGuard/Tailscale 走 UDP）跨运营商时可能被 QoS 限速/丢包，'
      '导致请求缓慢或超时。建议端侧与云端联网处于同一网络运营商下使用；'
      '必要时可在设置中调大页面加载超时。';

  /// 若是网络超时/缓慢类错误，追加 VPN UDP QoS 友好提示。
  static String _appendQosHintIfTimeout(String message) {
    final lowered = message.toLowerCase();
    if (lowered.contains('timeout') ||
        lowered.contains('timed out') ||
        lowered.contains('超时') ||
        lowered.contains('socketexception') ||
        lowered.contains('slow') ||
        lowered.contains('network')) {
      return message + _qosHint;
    }
    return message;
  }

  Duration get _loadTimeout => Duration(seconds: _timeoutSeconds);

  String get _loadingHint =>
      '首次加载需要从服务器传输界面资源，\n超时设置为 $_timeoutSeconds 秒，请耐心等待。';

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
    if (saved != null) {
      _zoomScaleNotifier.value = saved;
    }
  }

  /// 保存缩放比例（下次启动沿用）。
  Future<void> _saveZoomScale() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_zoomPrefKey, _zoomScaleNotifier.value);
  }

  /// 通过 CSS zoom 应用缩放比例（页面就绪后调用）。
  Future<void> _applyZoom() async {
    final c = _controller;
    if (c == null) return;
    await c.evaluateJavascript(source:
      "document.documentElement.style.zoom = '${_zoomScaleNotifier.value.toStringAsFixed(2)}'",
    );
  }

  void _adjustZoom(double delta) {
    final next =
        (_zoomScaleNotifier.value + delta).clamp(_zoomMin, _zoomMax);
    if (next == _zoomScaleNotifier.value) return;
    _zoomScaleNotifier.value = next;
    _saveZoomScale();
    _applyZoom();
  }

  void _resetZoom() {
    _zoomScaleNotifier.value = 1.0;
    _saveZoomScale();
    _applyZoom();
  }

  /// 隧道状态流回调：同步界面状态；断开/失败时带守卫自动重连。
  ///
  /// 首次异常（[_reconnectCount] == 0）不提示：保持当前状态直接默认重试，
  /// 避免隐藏后台 / 黑屏一段时间后频繁闪现异常界面；再次异常才显示提示。
  void _onTunnelStatus(TunnelStatus s) {
    if (!mounted) return;
    if (!_switching &&
        (s == TunnelStatus.disconnected || s == TunnelStatus.failed)) {
      if (_reconnectCount == 0) {
        // 首次异常：不更新状态（界面不闪现提示），直接默认重试
        _scheduleReconnect();
        return;
      }
    }
    setState(() => _tunnelStatus = s);
    if (!_switching &&
        (s == TunnelStatus.disconnected || s == TunnelStatus.failed)) {
      _scheduleReconnect();
    }
  }

  /// 带守卫的自动重连：避免重复/并发重连造成死循环；连续失败达到
  /// [_maxReconnect] 次后停止自动重连，交由用户手动重试（防止无限循环）。
  void _scheduleReconnect() {
    if (_reconnecting) return;
    if (_reconnectCount >= _maxReconnect) return;
    _reconnecting = true;
    _reconnectCount++;
    // 递增退避：2s、4s、6s、8s、10s
    final delay = Duration(seconds: 2 * _reconnectCount);
    Future<void>.delayed(delay, () {
      _reconnecting = false;
      if (mounted && _reconnectCount < _maxReconnect) _connect();
    });
  }

  Future<void> _load() async {
    final profiles = await SSHConfig.loadAllProfiles();
    final activeIndex = await SSHConfig.loadActiveIndex();
    final timeoutSeconds = await SSHConfig.loadTimeoutSeconds();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeIndex = activeIndex;
      _config = profiles[activeIndex];
      _timeoutSeconds = timeoutSeconds;
    });
    _manualConnect();
  }

  /// 用户主动连接：重置自动重连计数后连接（重试按钮 / 切换实例 / 初始加载）。
  void _manualConnect() {
    _reconnectCount = 0;
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
      await TunnelService.instance
          .connect(_config, profileIndex: _activeIndex);
      if (!mounted) return;
      _reconnectCount = 0; // 连接成功：重置重连计数
      setState(() => _tunnelStatus = TunnelStatus.connected);
      // 注意：这里不手动 loadUrl。WebView 每次在 body 重建时都会用
      // initialUrlRequest（即当前 _targetUrl）加载，切换实例/重连后
      // 会自动加载新地址；手动调用会用到尚未就绪/过期的 controller，
      // 触发 MissingPluginException。
    } catch (e) {
      if (!mounted) return;
      _handleConnectFailure('$e');
    }
  }

  /// 连接失败处理：首次失败不提示、直接默认重试；再次失败才显示错误
  /// 提示界面，随后按退避策略自动重试。
  void _handleConnectFailure(String message) {
    if (_reconnectCount == 0) {
      // 首次失败：不更新状态（界面不闪现错误提示），直接默认重试
      _scheduleReconnect();
      return;
    }
    // 再次失败：显示错误提示界面，随后自动重试
    setState(() {
      _tunnelStatus = TunnelStatus.failed;
      _error = _appendQosHintIfTimeout(message);
    });
    _scheduleReconnect();
  }

  Future<void> _disconnect() async {
    await TunnelService.instance.disconnect();
  }

  /// 切换激活实例：持久化 → 断开旧隧道 → 连接新实例并加载新界面。
  Future<void> _switchInstance(int index) async {
    if (index == _activeIndex) return;
    // 目标实例未配置 → 跳转设置页配置它
    if (!_profiles[index].isConfigured) {
      await _openSettings(profileIndex: index);
      return;
    }
    setState(() {
      _activeIndex = index;
      _config = _profiles[index];
      _switching = true;
      _pageError = null;
      _pageLoading = false;
    });
    await SSHConfig.setActiveIndex(index);
    await TunnelService.instance.disconnect();
    if (!mounted) return;
    setState(() => _switching = false);
    _manualConnect();
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    _tunnelSub?.cancel();
    _zoomScaleNotifier.dispose();
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

  Future<void> _openSettings({int? profileIndex}) async {
    final connected = _tunnelStatus == TunnelStatus.connected;
    final target = profileIndex ?? _activeIndex;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetupScreen(
          profileIndex: target,
          timeoutSeconds: _timeoutSeconds,
          profiles: _profiles,
          showUiControls: connected,
          zoomNotifier: _zoomScaleNotifier,
          onZoomIn: () => _adjustZoom(_zoomStep),
          onZoomOut: () => _adjustZoom(-_zoomStep),
          onResetZoom: _resetZoom,
          onRefreshCache: _refreshCache,
        ),
      ),
    );
    if (changed == true) {
      await _load();
    }
  }

  String get _targetUrl => 'http://127.0.0.1:${_config.localPort}';

  Future<void> _loadTargetUrl() async {
    final c = _controller;
    // 隧道未连接或 controller 已失效时跳过，避免 MissingPluginException
    if (c == null || _tunnelStatus != TunnelStatus.connected) return;
    try {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(_targetUrl)));
    } catch (_) {
      // controller 可能已失效，忽略
    }
  }

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
        _pageError = _appendQosHintIfTimeout(
            '加载超时（${_loadTimeout.inSeconds} 秒未完成）。\n'
            '请检查服务器状态、网络连接，或在设置中调大超时后重试。');
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
      _pageError = _appendQosHintIfTimeout(message);
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
    await _loadTargetUrl();
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
            const SizedBox(width: 12),
            Text('DSH-Phone', style: theme.textTheme.titleMedium),
            const Spacer(),
            // 实例切换器：点击弹出菜单，自由切换连接实例
            _buildInstanceSwitcher(context),
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

  /// 顶部实例切换器：当前实例标签 + 状态点，点击弹出菜单切换。
  Widget _buildInstanceSwitcher(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '切换连接实例',
      onSelected: _switchInstance,
      child: _InstanceChip(
        label: '${_activeIndex + 1} · ${_config.label}',
        status: _tunnelStatus,
      ),
      itemBuilder: (context) => [
        for (var i = 0; i < SSHConfig.maxProfiles; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(
                  i == _activeIndex
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('实例${i + 1} · ${_profiles[i].label}'),
                ),
              ],
            ),
          ),
      ],
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
                  onPressed: _manualConnect,
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
                // 原生双指缩放（保留手势），但禁用原生右下角缩放控件
                // （原生控件位置固定、常覆盖发送按钮），改用自定义
                // 左侧中央竖排浮动控件（_buildZoomControls）。
                supportZoom: true,
                displayZoomControls: false,
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
            // 自定义缩放控件：左侧屏幕中央、竖排，避开右下角发送按钮
            if (!_pageLoading && _pageError == null)
              _buildZoomControls(context),
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
                onPressed: _manualConnect,
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
            Text(
              _loadingHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
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

  /// 自定义浮动缩放控件：定位在**左侧屏幕中央、竖排**，替代原生右下角
  /// 缩放控件（后者固定右下、常覆盖发送按钮）。半透明小尺寸，尽量少遮挡。
  Widget _buildZoomControls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 6,
      top: 0,
      bottom: 0,
      child: Center(
        child: Material(
          color: scheme.surface.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(24),
          elevation: 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '放大',
                icon: const Icon(Icons.add),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () => _adjustZoom(_zoomStep),
              ),
              const Divider(height: 1, thickness: 1),
              IconButton(
                tooltip: '缩小',
                icon: const Icon(Icons.remove),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () => _adjustZoom(-_zoomStep),
              ),
              const Divider(height: 1, thickness: 1),
              IconButton(
                tooltip: '重置缩放',
                icon: const Icon(Icons.refresh),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: _resetZoom,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部实例切换器的展示 Chip：实例标签 + 连接状态点。
class _InstanceChip extends StatelessWidget {
  const _InstanceChip({required this.label, required this.status});

  final String label;
  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    final (color) = switch (status) {
      TunnelStatus.idle => Colors.grey,
      TunnelStatus.connecting => Colors.orange,
      TunnelStatus.connected => Colors.green,
      TunnelStatus.failed => Colors.red,
      TunnelStatus.disconnected => Colors.grey,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Chip(
        avatar: Icon(Icons.swap_horiz, size: 16, color: color),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: color.withValues(alpha: 0.15),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
