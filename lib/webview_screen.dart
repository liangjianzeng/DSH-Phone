import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lunar/lunar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artifact_recognizer.dart';
import 'artifact_viewer_screen.dart';
import 'config.dart';
import 'download_manager.dart';
import 'download_screen.dart';
import 'host_monitor.dart';
import 'moon_astronomy.dart';
import 'moon_location.dart';
import 'moon_painter.dart';
import 'setup_screen.dart';
import 'task_notifier.dart';
import 'tunnel_service.dart';
import 'unsloth_screen.dart';
import 'webview_bridges.dart';

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

class _WebViewScreenState extends State<WebViewScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;

  // ---- 多实例配置 ----
  List<SSHConfig> _profiles =
      List.filled(SSHConfig.maxProfiles, const SSHConfig());
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

  /// 对话区左侧浮动缩放控件的开关键（持久化，默认关闭）。
  static const String _zoomControlsPrefKey = 'webview_zoom_controls_enabled';

  /// 对话区左侧相机入口的开关键（持久化，默认开启）。
  static const String _photoControlsPrefKey = 'webview_photo_controls_enabled';

  // ---- 工具类功能开关（设置页"工具"分类控制）----
  bool _hostMonitorEnabled = true; // 主机监控（默认开：采样并呈现曲线）
  bool _resourceViewEnabled = true; // 资源查看（默认开）
  bool _resourceDownloadEnabled = true; // 资源下载（默认开）

  /// 缩放比例共享通知器：设置页可实时监听并展示。
  final ValueNotifier<double> _zoomScaleNotifier = ValueNotifier<double>(1.0);

  /// 对话区左侧浮动缩放控件是否显示（默认关闭，由设置页开关控制）。
  bool _zoomControlsEnabled = false;

  /// 对话区左侧相机入口是否显示（默认开启，由设置页开关控制）。
  bool _photoControlsEnabled = true;

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

  // 三个 WebView JS 桥脚本常量已提取到 lib/webview_bridges.dart：
  // - artifactBridgeJs：成果识别（点击监听 → onArtifactClick）
  // - taskBridgeJs：任务状态监听（onTaskState → 熄屏通知）
  // - photoBridgeJs：图片直传（pickImage → DSH 附件槽）

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
    WidgetsBinding.instance.addObserver(this);
    // 监听隧道真实状态，状态变化时同步界面；仅在真正断开时自动重连。
    _tunnelSub = TunnelService.instance.statusStream.listen(_onTunnelStatus);
    _load();
    _loadZoomScale();
    _loadZoomControls();
    _loadPhotoControls();
    _loadToolSwitches();
    // 监控采样定时器常驻，内部仅在隧道 connected 时旁路采集。
    HostMonitor.instance.start();
    // 月相按钮：读取观测位置设置（默认北京/手动/GPS）并监听生效位置变化。
    MoonLocation.observer.addListener(_onMoonLocationChanged);
    MoonLocation.init();
  }

  /// 观测位置变化（GPS 到位/设置变更）→ 重绘月相盘面。
  void _onMoonLocationChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 应用前后台切换记录：用于排查"后台→前台必然重连"问题。
  /// 后台期间记录时间戳；前台恢复时打印隧道状态，确认断开发生在何时。
  DateTime? _backgroundedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[DSH] lifecycle: $state '
        '(tunnel=${TunnelService.instance.status})');
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // 进入后台：记录时间（inactive/hidden 都可能触发）
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.paused:
        // 确认进入后台
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        // 回到前台：打印后台持续时长与当前隧道状态
        final bg = _backgroundedAt;
        debugPrint('[DSH] resumed from background, '
            'backgroundedMs=${bg == null ? '?' : DateTime.now().difference(bg).inMilliseconds}, '
            'tunnel=${TunnelService.instance.status}');
        _backgroundedAt = null;
      case AppLifecycleState.detached:
        break;
    }
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

  /// 读取持久化的对话区缩放控件开关。
  Future<void> _loadZoomControls() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_zoomControlsPrefKey) ?? false;
    if (!mounted) return;
    setState(() => _zoomControlsEnabled = enabled);
  }

  /// 保存并应用对话区缩放控件开关（默认关闭）。
  void _setZoomControlsEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _zoomControlsEnabled = enabled);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_zoomControlsPrefKey, enabled),
    );
  }

  /// 读取持久化的对话区相机入口开关。
  Future<void> _loadPhotoControls() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_photoControlsPrefKey) ?? true;
    if (!mounted) return;
    setState(() => _photoControlsEnabled = enabled);
  }

  /// 保存并应用对话区相机入口开关（默认开启）。
  void _setPhotoControlsEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _photoControlsEnabled = enabled);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_photoControlsPrefKey, enabled),
    );
  }

  /// 月相观测位置设置变更：持久化并重新解析（observer 变化自动触发重绘）。
  void _setMoonLocation(MoonLocationMode mode,
      {double? latitude, double? longitude}) {
    MoonLocation.update(mode,
        latitude: latitude, longitude: longitude);
  }

  /// 读取工具类功能开关（监控 / 资源查看 / 资源下载），并同步监控采样器。
  Future<void> _loadToolSwitches() async {
    final hostMonitor = await SSHConfig.loadHostMonitorEnabled();
    final resourceView = await SSHConfig.loadResourceViewEnabled();
    final resourceDownload = await SSHConfig.loadResourceDownloadEnabled();
    if (!mounted) return;
    setState(() {
      _hostMonitorEnabled = hostMonitor;
      _resourceViewEnabled = resourceView;
      _resourceDownloadEnabled = resourceDownload;
    });
    // 同步监控采样器：关闭则不请求（曲线随之消失）。
    HostMonitor.instance.enabled = hostMonitor;
  }

  /// 主机监控开关：持久化并同步采样器（关闭 → 停止请求并清空曲线）。
  void _setHostMonitorEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _hostMonitorEnabled = enabled);
    HostMonitor.instance.enabled = enabled;
    SSHConfig.saveHostMonitorEnabled(enabled);
  }

  /// 资源查看开关：关闭后点击文件型成果不再打开查看器。
  void _setResourceViewEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _resourceViewEnabled = enabled);
    SSHConfig.saveResourceViewEnabled(enabled);
  }

  /// 资源下载开关：关闭后点击资源型成果不再触发下载。
  void _setResourceDownloadEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _resourceDownloadEnabled = enabled);
    SSHConfig.saveResourceDownloadEnabled(enabled);
  }

  /// 通过 CSS zoom 应用缩放比例（页面就绪后调用）。
  Future<void> _applyZoom() async {
    final c = _controller;
    if (c == null) return;
    await c.evaluateJavascript(
      source:
          "document.documentElement.style.zoom = '${_zoomScaleNotifier.value.toStringAsFixed(2)}'",
    );
  }

  void _adjustZoom(double delta) {
    final next = (_zoomScaleNotifier.value + delta).clamp(_zoomMin, _zoomMax);
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
  /// 首次异常（[_reconnectCount] == 0）不显示错误文案（静默重连，
  /// 避免隐藏后台 / 黑屏一段时间后频繁闪现异常界面），
  /// 但仍把状态置为 disconnected——顶栏不再显示"已连接"误导用户，
  /// 回到前台时看到的是诚实的"隧道已断开"，而非残留的绿色状态点。
  void _onTunnelStatus(TunnelStatus s) {
    if (!mounted) return;
    final isBreak =
        s == TunnelStatus.disconnected || s == TunnelStatus.failed;
    if (!_switching && isBreak) {
      if (_reconnectCount == 0) {
        if (_tunnelStatus == TunnelStatus.connected) {
          // 仅更新状态（不设错误文案，_buildBody 的 disconnected 分支
          // 显示"隧道已断开"，不会闪现红色错误界面）
          setState(() => _tunnelStatus = TunnelStatus.disconnected);
        }
        _scheduleReconnect();
        return;
      }
    }
    setState(() => _tunnelStatus = s);
    if (!_switching && isBreak) {
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
    // 注意：_reconnectCount 在调度时就已自增，第 5 次调度后值为
    // _maxReconnect，此时仍应执行连接（否则实际只重试 4 次）。
    final delay = Duration(seconds: 2 * _reconnectCount);
    Future<void>.delayed(delay, () {
      _reconnecting = false;
      if (mounted && _reconnectCount <= _maxReconnect) _connect();
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
    _setupMonitorProfile();
    _manualConnect();
  }

  /// 依据实例级"默认主机资源监控"开关，建立/更新独立的监控采集隧道。
  /// 监控目标与当前连接实例无关：顶栏曲线始终显示监控实例的数据。
  void _setupMonitorProfile() {
    final index = _profiles.indexWhere((p) => p.hostMonitorEnabled);
    if (index < 0) {
      TunnelService.instance.setupMonitorProfile(null);
      return;
    }
    final config = _profiles[index];
    if (!config.isConfigured) {
      TunnelService.instance.setupMonitorProfile(null);
      return;
    }
    TunnelService.instance.setupMonitorProfile(config, profileIndex: index);
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
      await TunnelService.instance.connect(_config, profileIndex: _activeIndex);
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
    WidgetsBinding.instance.removeObserver(this);
    _loadTimeoutTimer?.cancel();
    _tunnelSub?.cancel();
    _zoomScaleNotifier.dispose();
    MoonLocation.observer.removeListener(_onMoonLocationChanged);
    HostMonitor.instance.stop();
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

  /// 打开 Unsloth Studio 页面（全局唯一启用的实例，与当前连接实例无关）。
  ///
  /// 与"默认主机资源监控"一致：仅允许一个实例开启 unsloth，
  /// 顶栏图标始终打开该实例的 Unsloth Studio（HTTP 直连 / SSH 隧道）。
  void _openUnsloth() {
    final index = _profiles.indexWhere((p) => p.unslothEnabled);
    if (index < 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('未启用 Unsloth Studio，请到设置 → 主机中开启'),
        ));
      return;
    }
    final config = _profiles[index];
    if (config.host.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('该实例未配置主机地址')));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnslothScreen(
          config: config,
          profileIndex: index,
          timeoutSeconds: _timeoutSeconds,
        ),
      ),
    );
  }

  Future<void> _openSettings({int? profileIndex}) async {
    final connected = _tunnelStatus == TunnelStatus.connected;
    final target = profileIndex ?? _activeIndex;
    // 进入设置前的配置快照：返回后据此判断是否需要断开重连
    final snapshotProfiles = List<SSHConfig>.of(_profiles);
    final snapshotTimeout = _timeoutSeconds;
    final snapshotActive = _activeIndex;
    await Navigator.of(context).push<bool>(
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
          zoomControlsEnabled: _zoomControlsEnabled,
          onZoomControlsChanged: _setZoomControlsEnabled,
          photoControlsEnabled: _photoControlsEnabled,
          onPhotoControlsChanged: _setPhotoControlsEnabled,
          moonLocationMode: MoonLocation.mode,
          moonManualLatitude: MoonLocation.manualLatitude,
          moonManualLongitude: MoonLocation.manualLongitude,
          onMoonLocationChanged: _setMoonLocation,
          hostMonitorEnabled: _hostMonitorEnabled,
          onHostMonitorChanged: _setHostMonitorEnabled,
          resourceViewEnabled: _resourceViewEnabled,
          onResourceViewChanged: _setResourceViewEnabled,
          resourceDownloadEnabled: _resourceDownloadEnabled,
          onResourceDownloadChanged: _setResourceDownloadEnabled,
          // 实例级监控开关即时保存后：重新加载配置并刷新监控隧道
          onInstanceMonitorChanged: (_) => _load(),
        ),
      ),
    );
    // 设置已自动保存（表单编辑即落盘）：无论返回方式（点完成/返回键），
    // 返回后读取最新配置。仅当配置/激活实例/加载超时确实变化时才断开重连，
    // 否则保持现有隧道——避免"只打开看一眼设置"就打断当前会话。
    final profiles = await SSHConfig.loadAllProfiles();
    final activeIndex = await SSHConfig.loadActiveIndex();
    final timeout = await SSHConfig.loadTimeoutSeconds();
    if (!mounted) return;
    final changed = _settingsChanged(
      before: snapshotProfiles,
      beforeTimeout: snapshotTimeout,
      beforeActive: snapshotActive,
      after: profiles,
      afterTimeout: timeout,
      afterActive: activeIndex,
    );
    if (changed) {
      await TunnelService.instance.disconnect();
    }
    await _load();
  }

  /// 对比设置页返回后的配置与进入前快照：任一字段/激活实例/加载超时
  /// 变化即视为需要重连（地址/端口/凭据修改必须重连才生效）。
  static bool _settingsChanged({
    required List<SSHConfig> before,
    required int beforeTimeout,
    required int beforeActive,
    required List<SSHConfig> after,
    required int afterTimeout,
    required int afterActive,
  }) {
    if (beforeTimeout != afterTimeout || beforeActive != afterActive) {
      return true;
    }
    for (var i = 0; i < SSHConfig.maxProfiles; i++) {
      final a = before[i];
      final b = after[i];
      if (a.host != b.host ||
          a.sshPort != b.sshPort ||
          a.username != b.username ||
          a.localPort != b.localPort ||
          a.authType != b.authType ||
          a.password != b.password ||
          a.privateKeyPem != b.privateKeyPem ||
          a.keyPassphrase != b.keyPassphrase ||
          a.alias != b.alias ||
          a.hostMonitorEnabled != b.hostMonitorEnabled ||
          a.unslothEnabled != b.unslothEnabled ||
          a.unslothPort != b.unslothPort ||
          a.unslothUseSsh != b.unslothUseSsh ||
          a.unslothPassword != b.unslothPassword) {
        return true;
      }
    }
    return false;
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

  // ================= 成果识别桥（方案 C）=================

  /// 注册成果点击 handler 并注入监听脚本。
  ///
  /// handler 随 controller 常驻；监听脚本按页面加载注入（onLoadStop），
  /// 因为每次页面导航 DOM 都会重建。
  void _setupArtifactBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onArtifactClick',
      callback: (List<Object?> args) async {
        // 只打印关键字段与内容长度，不落完整内容（避免大文本/敏感对话进日志）
        if (args.isNotEmpty && args.first is Map) {
          final raw = args.first as Map;
          debugPrint('ARTIFACT_RAW: type=${raw['type']} url=${raw['url']} '
              'path=${raw['path']} '
              'contentLen=${(raw['content'] as String?)?.length ?? 0}');
        }
        if (args.isEmpty || !mounted) return null;
        final raw = args.first;
        if (raw is! Map) return null;
        final hit = parseArtifactHit(raw);
        debugPrint('ARTIFACT_HIT: type=${hit.type} url=${hit.url} '
            'lang=${hit.language} contentLen=${hit.content.length}');
        if (hit.isNone || !mounted) return null;
        await _openArtifact(hit);
        return null;
      },
    );
    // 立即注入一次；页面导航后 onLoadStop 会再次注入。
    controller.evaluateJavascript(source: artifactBridgeJs);
  }

  /// 图片直传桥：注入桥脚本（页面导航 DOM 重建后需重新注入）。
  void _setupPhotoBridge(InAppWebViewController controller) {
    controller.evaluateJavascript(source: photoBridgeJs);
  }

  /// 页面导航后重新注入图片直传桥（每次导航 DOM 重建）。
  void _injectPhotoBridge() {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: photoBridgeJs);
  }

  // ================= 任务状态桥（熄屏通知）=================

  /// 注册任务状态 handler 并注入监听脚本。
  ///
  /// handler 随 controller 常驻；监听脚本按页面加载注入（onLoadStop），
  /// 因为每次页面导航 DOM 都会重建。
  void _setupTaskBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onTaskState',
      callback: (List<Object?> args) async {
        if (args.isEmpty) return null;
        final raw = args.first;
        if (raw is! Map) return null;
        final state = raw['state'] as String?;
        debugPrint('[DSH] task state: $state');
        switch (state) {
          case 'running':
            await TaskNotifier.instance.showRunning();
          case 'settled':
            await TaskNotifier.instance.showCompleted();
        }
        return null;
      },
    );
    controller.evaluateJavascript(source: taskBridgeJs);
  }

  /// 页面导航后重新注入任务状态桥（每次导航 DOM 重建）。
  void _injectTaskBridge() {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: taskBridgeJs);
  }

  /// 相机/相册选图 → base64 → 注入 DSH 消息输入窗口（附件槽）。
  Future<void> _pickAndSendImage() async {
    final c = _controller;
    if (c == null) return;
    // 选择来源：相册 / 拍照
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picker = ImagePicker();
    // 限制尺寸与质量：手机照片通常远小于 DSH 单图 20MB 上限，这里再压缩
    final file = await picker.pickImage(
      source: source,
      maxWidth: 4096,
      maxHeight: 4096,
      imageQuality: 90,
    );
    if (file == null || !mounted) return;
    // DSH 附件仅接受 png/jpeg/webp/gif；其它格式直接提示，避免页面侧报错
    final name = file.name.isNotEmpty ? file.name : 'image.jpg';
    final mime = _imageMimeForName(name);
    if (mime == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            content: Text('不支持的图片格式，请选择 PNG / JPEG / WebP / GIF')));
      return;
    }
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final base64 = base64Encode(bytes);
    // name 可能含中文/空格，用 jsonEncode 保证注入安全
    final js =
        "window.__dshPhotoBridge.pickImage('$base64', ${jsonEncode(name)}, '$mime')";
    final result = await c.evaluateJavascript(source: js) as Object?;
    debugPrint('[DSH] photo pick: name=$name mime=$mime '
        'bytes=${bytes.length} result=$result');
    if (!mounted) return;
    // 页面侧注入失败（桥未就绪 / 解码异常）时明确提示，便于排查
    if (result is Map && result['ok'] == false) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text('图片注入失败：${result['error'] ?? '未知错误'}')));
    }
  }

  /// 依据文件名判断 DSH 附件可接受的图片 MIME（png/jpeg/webp/gif）。
  static String? _imageMimeForName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return null;
  }

  /// 页面加载完成后注入成果监听脚本（每次导航 DOM 重建后重新绑定）。
  void _injectArtifactBridge() {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: artifactBridgeJs);
  }

  /// 打开原生成果查看器：以全屏路由叠在对话之上，关闭即返回对话。
  Future<void> _openArtifact(ArtifactHit hit) async {
    // path 只有文件名时（chips 被隐藏场景），先用候选目录拼接定位云端路径。
    final resolved = await _resolveHitPath(hit);
    if (!mounted) return;
    hit = resolved;
    // 资源型成果（apk/压缩包等）：转下载页（含断点续传 + 另存为）。
    // 工具开关：资源下载关闭时不触发下载能力。
    if (hit.type == ArtifactType.resource) {
      if (_resourceDownloadEnabled) {
        _openResourceDownload(hit);
      }
      return;
    }
    // 工具开关：资源查看关闭时不打开查看器。
    if (!_resourceViewEnabled) return;
    // 文件型成果：内容经 SSH 读取云端文件（复用隧道会话），打开后异步加载。
    final loader = hit.type == ArtifactType.file && hit.path.isNotEmpty
        ? () => TunnelService.instance.readRemoteFile(hit.path)
        : null;
    // 另存为时读取原始字节（保留原始编码，如 GBK）。
    final rawBytesLoader = hit.type == ArtifactType.file && hit.path.isNotEmpty
        ? () => TunnelService.instance.readRemoteFileBytes(hit.path)
        : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ArtifactViewerScreen(
          type: hit.type,
          url: hit.url,
          language: hit.language,
          content: hit.content,
          loader: loader,
          fileName: hit.path.isNotEmpty ? _basename(hit.path) : null,
          rawBytesLoader: rawBytesLoader,
        ),
      ),
    );
  }

  /// 解析成果云端路径：path 已含路径分隔符视为完整路径；否则用候选目录
  /// （[ArtifactHit.dirs]）逐个拼接并经 SFTP 验证，返回首个可打开的路径。
  ///
  /// 链接型资源（path 为空、url 非空，如 `/api/files/xxx.apk`）时，
  /// 用 URL 文件名 + 候选目录拼接定位，避免"不支持直接下载"。
  Future<ArtifactHit> _resolveHitPath(ArtifactHit hit) async {
    if (hit.path.contains(r'\') || hit.path.contains('/')) return hit;
    var base = hit.path;
    if (base.isEmpty && hit.url.isNotEmpty) {
      base = _basename(hit.url); // 链接型资源兜底：从 URL 提取文件名
    }
    if (base.isEmpty || hit.dirs.isEmpty) return hit;
    final resolved =
        await TunnelService.instance.resolveRemotePath(base, hit.dirs);
    if (resolved == null || resolved.isEmpty) return hit;
    return ArtifactHit(
      type: hit.type,
      url: hit.url,
      language: hit.language,
      content: hit.content,
      path: resolved,
    );
  }

  /// 资源型成果：经 SSH 下载（复用隧道会话），打开下载页。
  ///
  /// 仅当云端路径可用（文件成果按钮的 title/aria-label）时经 SFTP 下载；
  /// 仅含链接地址的资源无法取得远端路径，提示不支持直接下载。
  /// 立即打开下载页（任务后台启动），避免等待 SFTP 打开导致"点开灰屏/无反应"。
  void _openResourceDownload(ArtifactHit hit) {
    if (!mounted) return;
    if (hit.path.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('该资源不支持直接下载')));
      return;
    }
    final task = DownloadManager.instance.start(hit.path);
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => DownloadScreen(task: task),
      ),
    );
  }

  /// 取路径最后一段（兼容 `/` 与 `\` 分隔），用于查看器保存文件名。
  static String _basename(String p) {
    final norm = p.replaceAll(r'\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : norm;
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
        _pageError =
            _appendQosHintIfTimeout('加载超时（${_loadTimeout.inSeconds} 秒未完成）。\n'
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
  ///
  /// 启用主机监控且已连接时，趋势曲线叠加在左侧"DSH-Phone"标题区域内
  /// （左侧最老、右侧最新，纵轴高度即百分比），顶栏整体保持简洁。
  Widget _buildTopBar(BuildContext context) {
    final theme = Theme.of(context);
    // 曲线数据来自"默认主机资源监控"实例（独立采集隧道），
    // 与当前连接实例/隧道状态无关：任一实例连接时都显示监控实例的值。
    final showTrend = _hostMonitorEnabled &&
        TunnelService.instance.monitorProfileIndex != null;
    return Container(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const SizedBox(width: 12),
            // DSH-Phone 标题区域：背景叠加趋势曲线（仅此区域，不铺满整条顶栏）
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Stack(
                children: [
                  if (showTrend)
                    Positioned.fill(
                      child: ListenableBuilder(
                        listenable: HostMonitor.instance,
                        builder: (context, _) => CustomPaint(
                          painter: HostTrendPainter(
                            samples: HostMonitor.instance.samples,
                          ),
                        ),
                      ),
                    ),
                  // 文字半透明底：曲线透出时仍清晰
                  Container(
                    color: theme.colorScheme.surface.withValues(alpha: 0.7),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child:
                        Text('DSH-Phone', style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
            ),
            const Spacer(),
            _buildInstanceSwitcher(context),
            IconButton(
              tooltip: 'Unsloth Studio',
              icon: const Icon(Icons.science_outlined),
              onPressed: _openUnsloth,
            ),
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
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
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
              onWebViewCreated: (controller) {
                _controller = controller;
                _setupArtifactBridge(controller);
                _setupPhotoBridge(controller);
                _setupTaskBridge(controller);
              },
              onLoadStart: (controller, url) => _onPageLoadStart(),
              onProgressChanged: (controller, progress) =>
                  _onPageProgress(progress),
              onLoadStop: (controller, url) {
                _onPageLoadStop();
                // 页面就绪后应用持久化的缩放比例
                _applyZoom();
                // 每次页面导航后重新注入成果监听脚本
                _injectArtifactBridge();
                // 每次页面导航后重新注入图片直传桥
                _injectPhotoBridge();
                // 每次页面导航后重新注入任务状态桥，并复位可能残留的
                // 「任务进行中」通知（桥会对齐当前状态，运行中会重新上报）。
                _injectTaskBridge();
                TaskNotifier.instance.reset();
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
            if (_pageLoading && _pageError == null) _buildPageLoading(context),
            // 页面加载失败/超时：错误界面
            if (_pageError != null) _buildPageError(context),
            // 自定义缩放控件：左侧屏幕中央、竖排，避开右下角发送按钮。
            // 默认关闭，仅在设置页开启后显示。
            if (_zoomControlsEnabled && !_pageLoading && _pageError == null)
              _buildZoomControls(context),
            // 相机入口浮动按钮：对话区左侧靠屏幕边居中偏上，默认开启。
            if (_photoControlsEnabled && !_pageLoading && _pageError == null)
              _buildPhotoControls(context),
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
              Text('无法加载远程界面', style: Theme.of(context).textTheme.titleMedium),
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

  /// 相机入口浮动按钮：对话区左侧、屏幕底部往上约六分之一处（避开底部安全区与
  /// 键盘、缩放控件）。按钮呈现为**真实观测的月相**——用太阳/月球实际位置计算：
  /// 照明度（小时级连续的朔望周期 29.53 天）与盘面朝向（亮缘位置角 + 观测者
  /// 纬度/经度/时角决定的旋转，月出月落可见亮面旋转），满月最亮、新月留微光，
  /// 让用户一眼注意到视觉工具入口；默认开启，设置页可关。
  Widget _buildPhotoControls(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final now = DateTime.now();
    // 真实月球观测：绝对时间（UTC）+ 当前生效的观测位置（默认北京/手动/GPS，
    // 设置页可改；observer 变化会触发本方法重建）。
    final obs = MoonAstronomy.compute(now.toUtc(), MoonLocation.observer.value);
    final lit = obs.illumination;
    final borderColor = const Color(0xFF64B5F6);
    return Positioned(
      left: 6,
      bottom: screenHeight / 6,
      child: SizedBox(
        width: 48,
        height: 48,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 2), // 圆形边框
            boxShadow: [
              // 发光随月相变化：满月最亮，新月留微光保持入口可见。
              BoxShadow(
                color: borderColor.withValues(alpha: 0.12 + 0.55 * lit),
                blurRadius: 6 + 12 * lit,
                spreadRadius: 1 + 2 * lit,
              ),
              BoxShadow(
                color: const Color(0xFF81D4FA)
                    .withValues(alpha: 0.08 + 0.35 * lit),
                blurRadius: 16 + 12 * lit,
                spreadRadius: 2 + 3 * lit,
              ),
            ],
          ),
          child: CustomPaint(
            painter: MoonPhasePainter(obs.phase01, obs.tiltDeg),
            child: Center(
              child: IconButton(
                tooltip: '添加图片/拍照（视觉工具）·${obs.name}'
                    '·照明 ${(lit * 100).round()}%'
                    '·农历${_lunarDay(now)}'
                    '·观测${MoonLocation.observerLabel}',
                icon: Icon(
                  Icons.camera_alt_outlined,
                  color: lit >= 0.5
                      ? const Color(0xFF1565C0) // 亮面：深蓝图标
                      : Colors.white, // 暗面：白色图标
                ),
                iconSize: 22,
                visualDensity: VisualDensity.compact,
                onPressed: _pickAndSendImage,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 农历日（1~29/30）。统一按北京时间（UTC+8）推算农历，避免设备时区差异
  /// 导致月相差一天；异常时退回 15（满月，最亮最显眼）。
  static int _lunarDay(DateTime date) {
    try {
      // 本地时间 → UTC → +8h 得到北京日历字段；lunar 只取年月日，忽略时分。
      final beijing = date.toUtc().add(const Duration(hours: 8));
      return Solar.fromDate(beijing).getLunar().getDay();
    } catch (_) {
      return 15;
    }
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


