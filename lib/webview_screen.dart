import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lunar/lunar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
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
import 'asr/hold_to_talk.dart';
import 'sun_times.dart';
import 'task_notifier.dart';
import 'tunnel_service.dart';
import 'unsloth_screen.dart';
import 'weather_effects.dart';
import 'weather_service.dart';
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

  // ---- 文件上传大小上限（MB），可配置，默认 10，范围 1~30 ----
  int _uploadMaxMb = SSHConfig.defaultUploadMaxMb;

  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  String? _error;
  StreamSubscription<TunnelStatus>? _tunnelSub;
  bool _reconnecting = false;
  bool _switching = false; // 手动切换实例时抑制自动重连

  /// 按住说话会话（长按语音按钮期间非 null；结束后置回 null）。
  HoldToTalkSession? _holdSession;

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

  /// 对话区右侧语音输入入口的开关键（持久化，默认开启）。
  static const String _voiceControlsPrefKey = 'webview_voice_controls_enabled';

  /// 语音输入并入相机按钮的开关（持久化，默认关闭）：开启后隐藏右侧麦克风
  /// 浮动按钮，相机按钮叠加麦克风角标，短按相机（拍照/传图）、长按按住说话。
  static const String _voiceMergePrefKey = 'webview_voice_merge_to_camera';

  /// 天气动效开关（持久化，默认开启；WeatherService.enabled 同步启停查询）。
  static const String _weatherEffectsPrefKey = 'weather_effects_enabled';

  /// 日出日落联动开关（持久化，默认开启）：白天相机按钮显示全亮
  /// （月相暂停），夜间恢复真实月相；关闭则始终显示真实月相。
  static const String _sunSwitchPrefKey = 'moon_sun_switch_enabled';

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

  /// 对话区右侧语音输入入口是否显示（默认开启，由设置页开关控制）。
  bool _voiceControlsEnabled = true;

  /// 语音输入并入相机按钮（默认关闭，由设置页开关控制）：开启后隐藏右侧
  /// 麦克风按钮，相机按钮叠加麦克风角标，短按相机/长按说话。
  bool _voiceMergeToCamera = false;

  /// 天气动效是否显示（默认开启，由设置页开关控制）。
  bool _weatherEffectsEnabled = true;

  /// 日出日落联动是否开启（默认开启，由设置页开关控制）。
  bool _sunSwitchEnabled = true;

  // ---- 浮动控件可拖拽上下移动 ----
  // 位置以“像素”记录（相对对话区 Stack 的 top），拖拽时控件顶边跟随手指，
  // 避免“控件从手指下溜走→手势丢失→重新抓取→乱跳”的常见问题。

  /// 对话区 Stack 内可用高度（px），由 LayoutBuilder 填入（顶栏之下）。
  double _bodyHeight = 0;

  /// 缩放控件顶边 Y（相对 Stack，px），默认屏幕中央。
  double _zoomControlsTop = 0;

  /// 相机入口顶边 Y（相对 Stack，px）。默认底部往上约六分之一再上移约 1 厘米；
  /// 用户拖动过则下次进入按上次保存位置恢复（见 _photoPosTopPrefKey）。
  double _photoControlsTop = 0;

  /// 相机入口是否吸附在左侧边缘（false = 右侧）；松手时按水平位置吸附，
  /// 方便左右手操作（与语音入口一致）。
  bool _photoControlsOnLeft = true;

  /// 拖拽中相机入口的临时左侧 X（相对 Stack）；非拖拽时为 null。
  double? _photoControlsDragLeft;

  /// 语音入口顶边 Y（相对 Stack，px），默认与相机入口同高（右侧对称位置）。
  double _voiceControlsTop = 0;

  /// 语音入口是否吸附在左侧边缘（false = 右侧）；松手时按水平位置吸附，
  /// 方便左右手操作。
  bool _voiceControlsOnLeft = false;

  /// 拖拽中语音入口的临时左侧 X（相对 Stack）；非拖拽时为 null。
  double? _voiceControlsDragLeft;

  /// 拖拽抓手偏移：pan 起始时“手指 − 控件顶边/左边”，使控件始终跟随手指。
  double _zoomGripOffset = 0;
  double _photoGripOffset = 0;
  double _photoGripOffsetX = 0;
  double _voiceGripOffset = 0;
  double _voiceGripOffsetX = 0;

  /// 控件拖拽时顶边允许的最大值（Stack 高度 − 控件高度），保证不滑出屏外。
  static const double _zoomControlHeight = 120; // 3 图标 + 2 分隔，近似
  static const double _photoControlHeight = 48; // 圆形按钮 48×48
  static const double _photoControlWidth = 48; // 圆形按钮 48×48
  static const double _voiceControlHeight = 48; // 圆形麦克风按钮 48×48
  static const double _voiceControlWidth = 48; // 圆形麦克风按钮 48×48
  static const double _edgeGap = 8; // 吸附后距屏幕边缘的间距

  /// 相机入口位置持久化：顶边相对 Stack 高度的比例 + 吸附侧，
  /// 下次进入按最后拖动位置布局（纵向存比例，兼容不同屏高/键盘推挤）。
  static const String _photoPosTopPrefKey = 'photoControlsTopRatio';
  static const String _photoPosLeftPrefKey = 'photoControlsOnLeftEdge';

  /// 相机默认位置整体上移约 1 厘米（60dp）：默认顶边 = 底部起 5/6 处再上移。
  static const double _photoDefaultRaise = 60;

  /// 启动读取的上次保存的相机入口位置（null = 从未拖动过，用默认值）。
  double? _savedPhotoTopRatio;
  bool? _savedPhotoOnLeft;

  /// 相机入口当前左侧 X（非拖拽时按吸附侧取固定边距；拖拽中取临时值）。
  double _currentPhotoLeft(double stackWidth) => _photoControlsDragLeft ??
      (_photoControlsOnLeft ? _edgeGap : stackWidth - _photoControlWidth - _edgeGap);

  /// 语音入口当前左侧 X（非拖拽时按吸附侧取固定边距；拖拽中取临时值）。
  double _currentVoiceLeft(double stackWidth) => _voiceControlsDragLeft ??
      (_voiceControlsOnLeft ? _edgeGap : stackWidth - _voiceControlWidth - _edgeGap);

  // ---- WebView 页面加载状态 ----
  bool _pageLoading = false; // 远程页面加载中（隧道已通，页面未就绪）
  int _loadProgress = 0; // 0-100
  String? _pageError; // 页面加载错误（区别于隧道错误 _error）
  Timer? _loadTimeoutTimer;

  /// 鉴权错误（HTTP 401/403）：服务端 Token 鉴权未通过。此时不再自动重试，
  /// 错误页内嵌 Token 输入框，填完保存即重载（_targetUrl 会带上新 Token）。
  bool _authError = false;
  final TextEditingController _tokenCtrl = TextEditingController();

  // ---- 系统分享入口（Share Target）----
  /// 页面未就绪（隧道连接中 / WebView 加载中 / 报错）时收到的分享先入队，
  /// 页面加载完成后按序消费。
  final List<SharedMediaFile> _pendingShares = [];
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  // ---- 侧边栏终端按键条 ----
  /// 终端桥上报的 xterm 面板可见态：可见时在底部显示按键条
  /// （Esc/Tab/方向键/Ctrl 组合），隐藏时完全不打扰对话界面。
  bool _terminalVisible = false;

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
    _loadPhotoControlsPos();
    _loadVoiceControls();
    _loadVoiceMerge();
    _loadToolSwitches();
    // 监控采样定时器常驻，内部仅在隧道 connected 时旁路采集。
    HostMonitor.instance.start();
    // 月相按钮：读取观测位置设置（默认北京/手动/GPS）并监听生效位置变化。
    MoonLocation.observer.addListener(_onMoonLocationChanged);
    MoonLocation.init();
    // 天气动效：按观测位置查询真实天气（启动一次 + 每小时刷新 + 位置变化
    // 自动重查），驱动相机按钮周边的云/雨/雪等动效；设置页可整体开关。
    WeatherService.init();
    _loadWeatherEffects();
    _loadSunSwitch();
    // 系统分享入口：冷启动分享 + 运行中分享统一入队处理。
    ReceiveSharingIntent.instance.getInitialMedia().then(_enqueueShares);
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_enqueueShares);
  }

  /// 分享内容入队：页面就绪前先缓存，就绪后立即消费。
  void _enqueueShares(List<SharedMediaFile> items) {
    if (items.isEmpty) return;
    ReceiveSharingIntent.instance.reset(); // 已消费意图，清掉冷启动缓存
    _pendingShares.addAll(items);
    _processPendingShares();
  }

  /// 消费排队的分享：页面就绪（隧道通 + WebView 加载完成 + 无报错）才处理，
  /// 否则留在队列，由 onLoadStop 再次触发。
  Future<void> _processPendingShares() async {
    if (_pendingShares.isEmpty) return;
    if (TunnelService.instance.status != TunnelStatus.connected ||
        _pageLoading ||
        _pageError != null ||
        _controller == null) {
      return;
    }
    // 桥刚注入完，稍等 DOM/JS 就绪再注入，避免首次注入落到未挂载的页面
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    while (_pendingShares.isNotEmpty && mounted) {
      final item = _pendingShares.removeAt(0);
      try {
        if (item.type == SharedMediaType.text || item.type == SharedMediaType.url) {
          await _injectSharedText(item.path);
        } else if (item.type == SharedMediaType.image) {
          await _injectSharedImage(item.path);
        } else {
          _snack('暂不支持分享该类型内容（${item.type.value}）');
        }
      } catch (e) {
        _snack('分享内容注入失败：$e');
      }
    }
  }

  /// 分享的文本/链接 → 注入 DSH 消息输入框（不自动发送）。
  Future<void> _injectSharedText(String text) async {
    final c = _controller;
    if (c == null || text.isEmpty) return;
    final js =
        "window.__dshComposerBridge.insertText(${jsonEncode(text)})";
    final result = await c.evaluateJavascript(source: js) as Object?;
    if (result is Map && result['ok'] == false) {
      _snack('文本注入失败：${result['error'] ?? '未知错误'}');
    } else {
      _snack('已注入分享文本，请补充指令后发送');
    }
  }

  /// 分享的图片 → base64 → 注入 DSH 附件槽（复用拍照直传通道）。
  Future<void> _injectSharedImage(String path) async {
    final c = _controller;
    if (c == null) return;
    final name = path.replaceAll(r'\', '/').split('/').last;
    final mime = _imageMimeForName(name);
    if (mime == null) {
      _snack('不支持的图片格式（$name），仅支持 PNG / JPEG / WebP / GIF');
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      _snack('分享图片不存在或已被清理');
      return;
    }
    final bytes = await file.readAsBytes();
    final base64 = base64Encode(bytes);
    final js =
        "window.__dshPhotoBridge.pickImage('$base64', ${jsonEncode(name)}, '$mime')";
    final result = await c.evaluateJavascript(source: js) as Object?;
    if (result is Map && result['ok'] == false) {
      _snack('图片注入失败：${result['error'] ?? '未知错误'}');
    } else {
      _snack('已注入分享图片，请补充指令后发送');
    }
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

  /// 读取上次保存的相机入口位置（纵向比例 + 吸附侧），下次进入按其布局。
  Future<void> _loadPhotoControlsPos() async {
    final prefs = await SharedPreferences.getInstance();
    final r = prefs.getDouble(_photoPosTopPrefKey);
    if (r != null && r > 0 && r < 1) _savedPhotoTopRatio = r;
    _savedPhotoOnLeft = prefs.getBool(_photoPosLeftPrefKey);
  }

  /// 保存相机入口当前位置（顶边/Stack 高度比例 + 吸附侧）：拖拽松手后落盘。
  Future<void> _savePhotoControlsPos() async {
    final h = _bodyHeight;
    if (h <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_photoPosTopPrefKey, _photoControlsTop / h);
    await prefs.setBool(_photoPosLeftPrefKey, _photoControlsOnLeft);
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

  /// 读取持久化的对话区语音输入入口开关。
  Future<void> _loadVoiceControls() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_voiceControlsPrefKey) ?? true;
    if (!mounted) return;
    setState(() => _voiceControlsEnabled = enabled);
  }

  /// 保存并应用对话区语音输入入口开关（默认开启）。
  void _setVoiceControlsEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _voiceControlsEnabled = enabled);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_voiceControlsPrefKey, enabled),
    );
  }

  /// 读取持久化的"语音输入并入相机按钮"开关。
  Future<void> _loadVoiceMerge() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_voiceMergePrefKey) ?? false;
    if (!mounted) return;
    setState(() => _voiceMergeToCamera = enabled);
  }

  /// 保存并应用"语音输入并入相机按钮"开关（默认关闭）。
  void _setVoiceMergeToCamera(bool enabled) {
    if (!mounted) return;
    setState(() => _voiceMergeToCamera = enabled);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_voiceMergePrefKey, enabled),
    );
  }

  /// 读取天气动效开关（默认开启）。
  Future<void> _loadWeatherEffects() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_weatherEffectsPrefKey) ?? true;
    if (!mounted) return;
    setState(() => _weatherEffectsEnabled = enabled);
  }

  /// 保存并应用天气动效开关：同步启停 WeatherService 查询（持久化默认开启）。
  void _setWeatherEffectsEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _weatherEffectsEnabled = enabled);
    WeatherService.setEnabled(enabled);
  }

  /// 读取日出日落联动开关（默认开启）。
  Future<void> _loadSunSwitch() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_sunSwitchPrefKey) ?? true;
    if (!mounted) return;
    setState(() => _sunSwitchEnabled = enabled);
  }

  /// 保存并应用日出日落联动开关（默认开启）。
  void _setSunSwitchEnabled(bool enabled) {
    if (!mounted) return;
    setState(() => _sunSwitchEnabled = enabled);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setBool(_sunSwitchPrefKey, enabled),
    );
  }

  // ---- 浮动控件可拖拽上下移动 ----
  // 以“手指 − 抓手偏移”计算控件新顶边：控件顶边严格跟随手指，手抓在哪
  // 就跟到哪，不会从手指下溜走；clamp 到 [0, bodyHeight − controlHeight]
  // 保证拖到尽头也不滑出屏外（避免“消失”）。

  /// 缩放控件拖拽：更新归一化顶边（相对 Stack，px）。stackHeight 为 Stack 高。
  void _onZoomControlsPanStart(DragStartDetails details, double stackHeight) {
    _zoomGripOffset = details.globalPosition.dy - _zoomControlsTop;
  }

  void _onZoomControlsPanUpdate(DragUpdateDetails details, double stackHeight) {
    final newTop = (details.globalPosition.dy - _zoomGripOffset)
        .clamp(0.0, stackHeight - _zoomControlHeight);
    if ((newTop - _zoomControlsTop).abs() > 1.0) {
      setState(() => _zoomControlsTop = newTop);
    }
  }

  /// 相机入口拖拽开始：记录上下/左右抓手偏移（相对 Stack）。
  void _onPhotoControlsPanStart(DragStartDetails details, double stackHeight,
      double stackWidth) {
    _photoGripOffset = details.globalPosition.dy - _photoControlsTop;
    _photoGripOffsetX =
        details.globalPosition.dx - _currentPhotoLeft(stackWidth);
  }

  /// 相机入口拖拽：顶边跟随手指上下移动，左侧 X 跟随手指左右移动。
  void _onPhotoControlsPanUpdate(DragUpdateDetails details, double stackHeight,
      double stackWidth) {
    final newTop = (details.globalPosition.dy - _photoGripOffset)
        .clamp(0.0, stackHeight - _photoControlHeight);
    if ((newTop - _photoControlsTop).abs() > 1.0) {
      setState(() => _photoControlsTop = newTop);
    }
    final newLeft = (details.globalPosition.dx - _photoGripOffsetX)
        .clamp(0.0, stackWidth - _photoControlWidth);
    if ((_photoControlsDragLeft == null ||
        (newLeft - _photoControlsDragLeft!).abs() > 1.0)) {
      setState(() => _photoControlsDragLeft = newLeft);
    }
  }

  /// 相机入口松手：按水平位置吸附到最近边缘（左半 → 左边缘，右半 → 右边缘），
  /// 并把最终位置（纵向比例 + 吸附侧）持久化，下次进入按最后位置布局。
  void _onPhotoControlsPanEnd(double stackWidth) {
    final dragLeft = _photoControlsDragLeft;
    if (dragLeft == null) return;
    setState(() {
      _photoControlsOnLeft = dragLeft < stackWidth / 2;
      _photoControlsDragLeft = null;
    });
    _savePhotoControlsPos();
  }

  /// 语音入口拖拽：更新顶边与水平位置（相对 Stack，px）。
  /// 按住说话期间不拖拽（长按赢得手势竞技场后拖拽本就不会触发，此处双保险）。
  void _onVoiceControlsPanStart(DragStartDetails details, double stackHeight,
      double stackWidth) {
    if (_holdSession != null) return;
    _voiceGripOffset = details.globalPosition.dy - _voiceControlsTop;
    _voiceGripOffsetX =
        details.globalPosition.dx - _currentVoiceLeft(stackWidth);
  }

  void _onVoiceControlsPanUpdate(DragUpdateDetails details, double stackHeight,
      double stackWidth) {
    if (_holdSession != null) return;
    final newTop = (details.globalPosition.dy - _voiceGripOffset)
        .clamp(0.0, stackHeight - _voiceControlHeight);
    if ((newTop - _voiceControlsTop).abs() > 1.0) {
      setState(() => _voiceControlsTop = newTop);
    }
    // 水平跟随手指；松手时按位置吸附到左/右边缘。
    final newLeft = (details.globalPosition.dx - _voiceGripOffsetX)
        .clamp(0.0, stackWidth - _voiceControlWidth);
    if ((_voiceControlsDragLeft == null ||
        (newLeft - _voiceControlsDragLeft!).abs() > 1.0)) {
      setState(() => _voiceControlsDragLeft = newLeft);
    }
  }

  /// 语音入口松手：按水平位置吸附到最近边缘（左半 → 左边缘，右半 → 右边缘）。
  void _onVoiceControlsPanEnd(double stackWidth) {
    final dragLeft = _voiceControlsDragLeft;
    if (dragLeft == null) return;
    setState(() {
      _voiceControlsOnLeft = dragLeft < stackWidth / 2;
      _voiceControlsDragLeft = null;
    });
  }

  // ---- 按住说话（长按右侧语音按钮 → 端侧流式识别） ----

  /// 长按手势是否仍在进行（手指未松开）。用于权限/模型弹窗这类「长按过程中
  /// 弹出的系统/应用对话框」场景：弹窗期间用户必然松手去点弹窗，手势已结束，
  /// 此时不应再启动会话——否则浮层无人收尾（孤儿会话）且后续长按被
  /// `_holdSession != null` 拦截永久失效（真机实测踩坑）。
  bool _voiceLongPressActive = false;

  /// 语音按钮长按开始：授权麦克风 → 确保模型就绪（未就绪弹断点续传下载引导）→
  /// 启动会话与浮层。系统识别（speech_to_text）已移除：ROM 权限问题
  /// 导致部分机型（小米系）一用即崩，2026-10-02 决策只保留端侧方案。
  Future<void> _onVoiceLongPressStart() async {
    if (_holdSession != null) return;
    final c = _controller;
    if (c == null) return;
    _voiceLongPressActive = true;
    final mic = await Permission.microphone.request();
    if (!mounted || !_voiceLongPressActive) return;
    if (!mic.isGranted) {
      _snack('未授权麦克风，语音输入不可用');
      return;
    }
    final modelReady = await AsrModelGate.ensureModelReady(context);
    if (!mounted || !_voiceLongPressActive) {
      // 弹窗期间已松手：模型可能刚就绪，提示用户重新长按。
      if (mounted && modelReady) _snack('语音已就绪，请再次长按语音按钮说话');
      return;
    }
    if (!modelReady) {
      _snack('语音模型未下载完成，稍后再长按语音按钮');
      return;
    }
    // 先登记会话再启动：首次引擎加载需数秒，期间松手要能被正确收尾
    // （否则会话孤儿化：浮层滞留 + 麦克风常开，真机实测踩坑）。
    final session = HoldToTalkSession();
    if (mounted) setState(() => _holdSession = session); // 麦克风图标切录音动效
    final ok = await session.start(context);
    if (!identical(_holdSession, session)) {
      // 期间会话已被替换/清理（异常路径），兜底收尾
      await session.end(cancelled: true);
      return;
    }
    if (!ok) {
      setState(() => _holdSession = null);
      _snack('端侧语音识别启动失败，请重试');
      return;
    }    if (session.cancelRequested || !mounted) {
      // 引擎加载期间已松手：按取消丢弃
      await session.end(cancelled: true);
      if (mounted) setState(() => _holdSession = null);
      return;
    }
  }

  /// 长按移动：上滑超阈值 → 切换「松开取消」。
  void _onVoiceLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _holdSession?.cancelMode.value =
        details.offsetFromOrigin.dy < -HoldToTalkSession.cancelSlop;
  }

  /// 长按结束（松手/系统取消）：取终稿注入消息输入框并自动发送，
  /// 减少一次"确认发送"点击。
  /// 引擎尚未就绪（加载中松手）→ 标记取消，由 start 完成侧收尾。
  Future<void> _onVoiceLongPressEnd({bool cancelled = false}) async {
    _voiceLongPressActive = false; // 弹窗期间的收尾判断依赖此标记
    final session = _holdSession;
    if (session == null) return;
    if (!session.isStarted) {
      session.cancelRequested = true;
      return;
    }
    if (mounted) setState(() => _holdSession = null);
    final discard = cancelled || session.cancelMode.value;
    final text = await session.end(cancelled: discard);
    if (discard || text.isEmpty || !mounted) return;
    final ok = await _injectComposerTextAndSend(text);
    if (!mounted) return;
    if (ok) {
      _snack('已发送');
    } else {
      _snack('已注入，请点发送');
    }
  }

  /// 月相观测位置设置变更：持久化并重新解析（observer 变化自动触发重绘）。
  void _setMoonLocation(MoonLocationMode mode,
      {double? latitude, double? longitude}) {
    MoonLocation.update(mode, latitude: latitude, longitude: longitude);
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
    final isBreak = s == TunnelStatus.disconnected || s == TunnelStatus.failed;
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
    final uploadMaxMb = await SSHConfig.loadUploadMaxMb();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeIndex = activeIndex;
      _config = profiles[activeIndex];
      _timeoutSeconds = timeoutSeconds;
      _uploadMaxMb = uploadMaxMb;
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

  /// 顶栏模式一键切换：同实例内翻转 DSH/Zcode。端口若仍是另一模式的默认值
  /// 则落到本模式默认值（自定义端口保留），持久化后重载页面。
  ///
  /// 同一台服务器的两种模式只是转发目标端口不同（DSH 3080 / Zcode 8787），
  /// SSH 会话原样保留——转发通道按连接逐条拨号 _activeConfig.remotePort，
  /// 就地更新内存配置后新连接自动走新端口，无需断开重连。
  Future<void> _toggleMode() async {
    final newMode =
        _config.isZcodeMode ? SSHConfig.modeDsh : SSHConfig.modeZcode;
    var newPort = _config.remotePort;
    if (newMode == SSHConfig.modeZcode &&
        newPort == SSHConfig.defaultRemotePort) {
      newPort = SSHConfig.defaultZcodeRemotePort;
    } else if (newMode == SSHConfig.modeDsh &&
        newPort == SSHConfig.defaultZcodeRemotePort) {
      newPort = SSHConfig.defaultRemotePort;
    }
    final updated = _config.copyWith(mode: newMode, remotePort: newPort);
    await SSHConfig.saveProfile(_activeIndex, updated);
    if (!mounted) return;
    setState(() {
      _profiles[_activeIndex] = updated;
      _config = updated;
    });
    TunnelService.instance
        .updateActiveConfig(updated, profileIndex: _activeIndex);
    final modeName = newMode == SSHConfig.modeZcode ? "Zcode" : "DSH";
    if (TunnelService.instance.status == TunnelStatus.connected) {
      _snack('已切换到 $modeName 模式');
      await _loadTargetUrl();
    } else {
      _snack('已切换到 $modeName 模式，连接中…');
      _manualConnect();
    }
  }

  Future<void> _connect() async {
    // 已连接则跳过，避免冗余重连造成界面闪烁/循环
    if (TunnelService.instance.status == TunnelStatus.connected) return;
    setState(() {
      _error = null;
      _tunnelStatus = TunnelStatus.connecting;
      _authError = false;
      _pageError = null;
      _pageLoading = false;
    });
    try {
      await TunnelService.instance.connect(_config, profileIndex: _activeIndex);
      if (!mounted) return;
      _reconnectCount = 0; // 连接成功：重置重连计数
      setState(() => _tunnelStatus = TunnelStatus.connected);
      // WebView 只在 body 重建时用 initialUrlRequest 加载；同一实例内改
      // 模式/端口（设置保存返回，body 不重建）时页面仍是旧地址——曾因此
      // 在 Zcode 模式下残留 DSH 页面。校验实际地址，不一致就强制重载。
      try {
        final c = _controller;
        final current = (await c?.getUrl())?.toString();
        if (c != null && current != null && current != _targetUrl) {
          debugPrint('[DSH] page url mismatch ($current != ${_targetUrl.replaceAll(RegExp(r'token=[^&]+'), 'token=***')}), reloading');
          await _loadTargetUrl();
        }
      } catch (_) {
        // controller 未就绪：body 重建路径会自行加载
      }
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
      _authError = false;
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
    _shareSub?.cancel();
    _tokenCtrl.dispose();
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

  /// 是否存在任意启用了 Unsloth Studio 的实例。
  ///
  /// 顶栏 Unsloth 入口据此显示/隐藏：全部未启用时隐藏入口（无意义），
  /// 进入时仍保留兜底提示（防御并发修改配置）。
  bool get _unslothAvailable => _profiles.any((p) => p.unslothEnabled);

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
          voiceControlsEnabled: _voiceControlsEnabled,
          onVoiceControlsChanged: _setVoiceControlsEnabled,
          voiceMergeToCamera: _voiceMergeToCamera,
          onVoiceMergeToCameraChanged: _setVoiceMergeToCamera,
          weatherEffectsEnabled: _weatherEffectsEnabled,
          onWeatherEffectsChanged: _setWeatherEffectsEnabled,
          sunSwitchEnabled: _sunSwitchEnabled,
          onSunSwitchChanged: _setSunSwitchEnabled,
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
          // remotePort（远端服务端口）与 mode（DSH/Zcode 转发目标）也走
          // 隧道转发：漏比会导致设置页改完返回"无变化"不重连，旧目标继续用
          a.remotePort != b.remotePort ||
          a.mode != b.mode ||
          a.authType != b.authType ||
          a.password != b.password ||
          a.privateKeyPem != b.privateKeyPem ||
          a.keyPassphrase != b.keyPassphrase ||
          a.alias != b.alias ||
          a.hostMonitorEnabled != b.hostMonitorEnabled ||
          a.unslothEnabled != b.unslothEnabled ||
          a.unslothPort != b.unslothPort ||
          a.unslothUseSsh != b.unslothUseSsh ||
          a.unslothPassword != b.unslothPassword ||
          a.accessToken != b.accessToken ||
          a.zcodeToken != b.zcodeToken) {
        return true;
      }
    }
    return false;
  }

  /// 入口 URL（按当前模式取对应 Token）。
  /// DSH：配置了访问 Token 时拼上 `?token=`，让新版 DSH (>=0.1.2-rc.1)
  /// 在首次访问完成鉴权并下发 30 天签名 cookie；未配置则裸地址直连。
  /// Zcode：zcode-phone-server 对每个请求校验 Token，必须携带。
  String get _targetUrl {
    final base = 'http://127.0.0.1:${_config.localPort}';
    final token =
        (_config.isZcodeMode ? _config.zcodeToken : _config.accessToken)
            .trim();
    if (token.isEmpty) return base;
    return '$base/?token=${Uri.encodeQueryComponent(token)}';
  }

  Future<void> _loadTargetUrl() async {
    final c = _controller;
    // 隧道未连接或 controller 已失效时跳过，避免 MissingPluginException
    if (c == null || _tunnelStatus != TunnelStatus.connected) return;
    try {
      await c.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(_targetUrl),
          // 主文档必须绕过缓存：DSH/Zcode 的 token 只出现在主文档 URL 上，
          // 命中旧缓存会跳过「token→303→Set-Cookie」鉴权链，SPA 的 XHR
          // 带着旧签名 cookie 全部报「token 无效」（模式热切换实测复现，
          // 冷启动因缓存冷恰好走了鉴权链而正常）。
          headers: {'Cache-Control': 'no-cache'},
        ),
      );
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

  /// 消息输入框文本注入桥：注入桥脚本（页面导航 DOM 重建后需重新注入）。
  void _setupComposerBridge(InAppWebViewController controller) {
    controller.evaluateJavascript(source: composerBridgeJs);
  }

  /// 页面导航后重新注入文本注入桥（每次导航 DOM 重建）。
  void _injectComposerBridge() {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: composerBridgeJs);
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
          case 'approval':
            await TaskNotifier.instance.showApproval();
          case 'approval_clear':
            await TaskNotifier.instance.cancelApproval();
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

  // ================= 终端按键桥（侧边栏终端按键条）=================

  /// 注册终端可见态 handler 并注入检测/按键脚本。
  void _setupTerminalBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onTerminalState',
      callback: (List<Object?> args) async {
        if (args.isEmpty || args.first is! Map) return null;
        final visible = (args.first as Map)['visible'] == true;
        debugPrint('[DSH] terminal visible: $visible');
        if (mounted && visible != _terminalVisible) {
          setState(() => _terminalVisible = visible);
        }
        return null;
      },
    );
    controller.evaluateJavascript(source: terminalBridgeJs);
  }

  /// 页面导航后重新注入终端按键桥（每次导航 DOM 重建）。
  void _injectTerminalBridge() {
    final c = _controller;
    if (c == null) return;
    c.evaluateJavascript(source: terminalBridgeJs);
  }

  /// 终端按键条：注入一个按键到当前可见的 xterm 终端。
  Future<void> _sendTerminalKey(String key, int keyCode,
      {bool ctrl = false}) async {
    final c = _controller;
    if (c == null) return;
    final js = "window.__dshTerminalBridge.sendKey("
        "${jsonEncode(key)}, $keyCode, ${ctrl ? 'true' : 'false'}, false, false)";
    final result = await c.evaluateJavascript(source: js) as Object?;
    if (result is Map && result['ok'] == false) {
      _snack('按键注入失败：${result['error'] ?? '未知错误'}');
    }
    debugPrint('[DSH] terminal key: $key${ctrl ? ' (ctrl)' : ''} -> $result');
  }

  /// 侧边栏终端按键条：底部中央半透明胶囊，横向可滚动。
  /// 按键为终端刚需：Esc / Tab / 方向键 / Enter / Ctrl+C / Ctrl+D。
  Widget _buildTerminalKeyBar(BuildContext context) {
    final theme = Theme.of(context);
    final keyStyle = TextStyle(
        fontSize: 12.5, color: theme.colorScheme.onSurface, height: 1.0);
    Widget keyCap(String label, String key, int keyCode, {bool ctrl = false}) =>
        Material(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _sendTerminalKey(key, keyCode, ctrl: ctrl),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(label, style: keyStyle),
            ),
          ),
        );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 8,
      child: Center(
        child: Material(
          color: theme.colorScheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
          elevation: 3,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                keyCap('Esc', 'Escape', 27),
                const SizedBox(width: 4),
                keyCap('Tab', 'Tab', 9),
                const SizedBox(width: 4),
                keyCap('↑', 'ArrowUp', 38),
                const SizedBox(width: 4),
                keyCap('↓', 'ArrowDown', 40),
                const SizedBox(width: 4),
                keyCap('←', 'ArrowLeft', 37),
                const SizedBox(width: 4),
                keyCap('→', 'ArrowRight', 39),
                const SizedBox(width: 4),
                keyCap('⏎', 'Enter', 13),
                const SizedBox(width: 4),
                keyCap('^C', 'c', 67, ctrl: true),
                const SizedBox(width: 4),
                keyCap('^D', 'd', 68, ctrl: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 相机/相册选图 → base64 → 注入 DSH 消息输入窗口（附件槽）；
  /// 或选择本地文件 → SFTP 上传 → 注入远程路径文本。
  Future<void> _pickAndSendImage() async {
    final c = _controller;
    if (c == null) return;
    // 选择来源：相册 / 拍照 / 选择文件上传
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择文件上传'),
              subtitle: const Text('上传到服务器，路径注入消息框'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    if (source == 'file') {
      await _pickAndSendFile();
      return;
    }
    final picker = ImagePicker();
    // 限制尺寸与质量：手机照片通常远小于 DSH 单图 20MB 上限，这里再压缩
    final file = await picker.pickImage(
      source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
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
        ..showSnackBar(
            SnackBar(content: Text('图片注入失败：${result['error'] ?? '未知错误'}')));
    }
  }

  /// 文本注入后自动发送（语音松手场景）。返回是否成功发送。
  /// 注入失败或找不到发送入口时返回 false（文本已注入，用户可手动发送）。
  Future<bool> _injectComposerTextAndSend(String text) async {
    final c = _controller;
    if (c == null) return false;
    // 先注入文本
    final inj = await c.evaluateJavascript(
        source: "window.__dshComposerBridge.insertText(${jsonEncode(text)})")
        as Object?;
    if (inj is Map && inj['ok'] == false) {
      _snack('文本注入失败：${inj['error'] ?? '未知错误'}');
      return false;
    }
    debugPrint('[DSH] composer text injected: ${text.length} chars');
    // 等 React 同步文本、发送按钮变为可点（DSH 富文本编辑器异步更新）
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return false;
    // 再触发发送；按钮暂不可用（页面文本同步慢）时再等一拍重试一次
    for (var attempt = 0; attempt < 2; attempt++) {
      final send = await c.evaluateJavascript(
          source: "window.__dshComposerBridge.send()") as Object?;
      if (send is Map && send['ok'] == true) {
        debugPrint('[DSH] composer text sent via ${send['via']}');
        return true;
      }
      // 空 Map（无 ok/error 键）：页面自带 async send 的 Promise 被 Android
      // WebView 序列化为 {}——发送副作用已同步启动，按已发送处理。
      if (send is Map && send.containsKey('ok') == false) {
        debugPrint('[DSH] composer send promise (async page bridge)');
        return true;
      }
      final err = (send as Map?)?['error']?.toString() ?? '';
      final busy = err.contains('暂不可用');
      debugPrint('[DSH] composer send failed: $err');
      if (!busy || attempt == 1) return false;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return false;
    }
    return false;
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

  /// 提示 SnackBar（自动清空旧提示，避免叠加）。
  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 选择本地文件 → SFTP 上传到服务器临时目录 → 注入远程路径文本到消息框。
  ///
  /// 大小上限由设置页配置（默认 10M，1~30M）；上传期间显示进度框；
  /// 成功后把服务器本地绝对路径注入消息输入框，用户补充指令后手动发送。
  Future<void> _pickAndSendFile() async {
    final c = _controller;
    if (c == null) return;
    if (TunnelService.instance.status != TunnelStatus.connected) {
      _snack('请先连接 SSH 隧道，再选择文件上传');
      return;
    }
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    final picked = result.files.single;
    final bytes = picked.bytes;
    final name = picked.name.isNotEmpty ? picked.name : 'upload.dat';
    if (bytes == null || bytes.isEmpty) {
      _snack('无法读取所选文件（可能为空或不可读）');
      return;
    }
    final maxBytes = _uploadMaxMb * 1024 * 1024;
    if (bytes.length > maxBytes) {
      _snack('文件 ${bytes.length ~/ (1024 * 1024)}MB 超过上传上限 '
          '$_uploadMaxMb MB（可在设置 → 工具中调大）');
      return;
    }

    // 上传进度：模态进度框（上传中不可关闭）
    final progress = ValueNotifier<double>(0.0);
    final progressText = ValueNotifier<String>('准备上传…');
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, __) => AlertDialog(
          title: const Text('上传中…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: progressText,
                builder: (_, text, __) => Text(
                  text,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    String? remotePath;
    try {
      remotePath = await TunnelService.instance.uploadRemoteFile(
        bytes,
        name,
        onProgress: (sent, total) {
          progress.value = total > 0 ? sent / total : 0.0;
          progressText.value = '$sent / $total 字节';
        },
      );
    } finally {
      navigator.pop(); // 关闭进度框
    }

    if (!mounted) return;
    if (remotePath == null || remotePath.isEmpty) {
      _snack('上传失败：隧道可能已断开或服务器拒绝写入');
      return;
    }

    // 注入远程路径文本到消息输入框，用户补充指令后发送
    final js = "window.__dshComposerBridge.insertText(${jsonEncode(remotePath)})";
    final inject = await c.evaluateJavascript(source: js) as Object?;
    if (!mounted) return;
    if (inject is Map && inject['ok'] == false) {
      _snack('路径注入失败：${inject['error'] ?? '未知错误'}');
      return;
    }
    _snack('已上传：$remotePath\n路径已注入消息框，请补充指令后发送');
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
      _authError = false;
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
      _authError = false;
      _pageError = _appendQosHintIfTimeout(message);
    });
    // 有限次自动重试：隧道若刚断连会自动重连，页面重载后自愈
    _schedulePageRetry();
  }

  /// Token 鉴权失败（HTTP 401/403）：不走自动重试（填完 Token 前重试必然
  /// 还是 401），错误页展示内嵌 Token 输入框，保存后立即重载。
  void _onAuthError(int statusCode) {
    _loadTimeoutTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _pageLoading = false;
      _authError = true;
      _pageError = '访问被拒绝（HTTP $statusCode）：远程 DSH 已启用 Token 鉴权，'
          '当前保存的 Token 已失效（服务端重启后会轮换）。\n'
          '请在下方填入最新的「DSH 访问 Token」，保存后自动重连。';
    });
  }

  /// 保存内嵌输入的新 Token 到当前实例配置（按模式存对应字段），并重载页面。
  Future<void> _saveTokenAndReload() async {
    final token = _tokenCtrl.text.trim();
    if (token.isEmpty) return;
    final updated = _config.isZcodeMode
        ? _config.copyWith(zcodeToken: token)
        : _config.copyWith(accessToken: token);
    await SSHConfig.saveProfile(_activeIndex, updated);
    if (!mounted) return;
    setState(() {
      _profiles[_activeIndex] = updated;
      _config = updated;
      _authError = false;
      _pageError = null;
      _pageLoading = true;
      _loadProgress = 0;
    });
    await _loadTargetUrl();
    _onPageLoadStart();
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
      _authError = false;
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
                  // 文字半透明底：曲线透出时仍清晰。
                  // 顶栏名称跟随当前连接模式：Zcode 模式显示 ZCode-Phone。
                  Container(
                    color: theme.colorScheme.surface.withValues(alpha: 0.7),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      _config.isZcodeMode ? 'ZCode-Phone' : 'DSH-Phone',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // 模式一键切换：与顶栏其它图标同款样式的 IconButton（点击翻转
            // DSH/Zcode 并自动重连）。
            IconButton(
              tooltip: _config.isZcodeMode ? '切换到 DSH 模式' : '切换到 Zcode 模式',
              icon: const Icon(Icons.swap_horiz, color: Colors.green),
              onPressed: _toggleMode,
            ),
            _buildInstanceSwitcher(context),
            // Unsloth 入口：全部实例未启用时隐藏（首页无意义）
            if (_unslothAvailable)
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
        label: _config.label,
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
                  child: Text(_profiles[i].label),
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
        // 用 LayoutBuilder 拿到对话区 Stack 的实际高度（顶栏之下），用于
        // 浮动控件的定位与拖拽 clamp；并在此首次布局时设定控件默认位置。
        return LayoutBuilder(
          builder: (context, constraints) {
            final stackHeight = constraints.maxHeight;
            final stackWidth = constraints.maxWidth;
            if (_bodyHeight == 0) {
              _bodyHeight = stackHeight;
              _zoomControlsTop = stackHeight * 0.5; // 默认屏幕中央
              // 相机默认：底部往上约六分之一、再整体上移约 1 厘米；
              // 用户拖动过则按上次保存的比例位置恢复（含吸附侧）。
              _photoControlsTop = _savedPhotoTopRatio != null
                  ? (_savedPhotoTopRatio! * stackHeight)
                      .clamp(0.0, stackHeight - _photoControlHeight)
                  : stackHeight * (1 - 1 / 6) - _photoDefaultRaise;
              _photoControlsOnLeft = _savedPhotoOnLeft ?? true;
              // 语音按钮默认吸附右侧、比相机入口略高一点（视觉上不对齐成一
              // 条线，也避免与月相/天气动效拥挤）；可拖到左/右边缘吸附。
              _voiceControlsTop =
                  (_photoControlsTop - 16).clamp(0.0, stackHeight);
            } else if ((stackHeight - _bodyHeight).abs() > 1) {
              // 容器高度变化（键盘弹出/收起、旋转等）：按高度比例上推/下拉
              // 浮动控件，让相机/语音/缩放按钮跟随页面内容一起移动——键盘
              // 上推页面时相机不会留在原地被键盘遮挡，天气动效锚定相机故
              // 一并移动。
              final ratio = stackHeight / _bodyHeight;
              _zoomControlsTop = _zoomControlsTop * ratio;
              _photoControlsTop = _photoControlsTop * ratio;
              _voiceControlsTop = _voiceControlsTop * ratio;
              _bodyHeight = stackHeight;
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_targetUrl)),
                  initialSettings: InAppWebViewSettings(
                    // 缓存策略：LOAD_DEFAULT 尊重 HTTP 缓存头——zcode-phone-server
                    // 对 HTML 发 no-store，保证页面代码始终最新。曾因
                    // LOAD_CACHE_ELSE_NETWORK（哪怕过期也吃缓存）长期加载旧页面，
                    // 服务端修复全部无法到达手机；DSH 静态资源仍按其缓存头命中
                    cacheMode: CacheMode.LOAD_DEFAULT,
                    // DSH 是含 WebSocket 的 SPA
                    javaScriptEnabled: true,
                    transparentBackground: false,
                    // 原生双指缩放（保留手势），但禁用原生右下角缩放控件
                    // （原生控件位置固定、常覆盖发送按钮），改用自定义
                    // 左侧中央竖排浮动控件（_buildZoomControls）。
                    supportZoom: true,
                    displayZoomControls: false,
                    // 页面内语音输入（dsh 自带 mic 按钮，getUserMedia 采集
                    // 音频 → host 端 SenseVoice 转写）：自动播放策略放宽，
                    // 权限授予见 onPermissionRequest。
                    mediaPlaybackRequiresUserGesture: false,
                  ),
                  // 页面申请麦克风/摄像头（getUserMedia）时直接授予：
                  // 应用层的 RECORD_AUDIO 运行时权限在语音入口先申请。
                  onPermissionRequest: (controller, request) async {
                    debugPrint('[DSH] webview permission: '
                        '${request.resources}');
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    _setupArtifactBridge(controller);
                    _setupPhotoBridge(controller);
                    _setupComposerBridge(controller);
                    _setupTaskBridge(controller);
                    _setupTerminalBridge(controller);
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
                    // 每次页面导航后重新注入文本注入桥
                    _injectComposerBridge();
                    // 每次页面导航后重新注入任务状态桥，并复位可能残留的
                    // 「任务进行中」通知（桥会对齐当前状态，运行中会重新上报）。
                    _injectTaskBridge();
                    TaskNotifier.instance.reset();
                    // 每次页面导航后重新注入终端按键桥
                    _injectTerminalBridge();
                    // 页面就绪：消费冷启动/排队中的分享内容
                    _processPendingShares();
                  },
                  onReceivedError: (controller, request, error) {
                    // 只有主框架加载失败才升级为整页错误。子资源/XHR/SSE 的
                    // 瞬时失败（EventSource 断开重连、切会话关闭旧流、轮询
                    // 抖动等）在长连接页面里是常态，整页报错会反复打断使用
                    // （表现为一点会话切换就「无法加载远程界面 net::ERR_FAILED」）。
                    if (request.isForMainFrame != true) return;
                    _onPageError(
                      '加载失败：${error.description}\n'
                      '（${error.type}）',
                    );
                  },
                  onReceivedHttpError: (controller, request, errorResponse) {
                    // 只处理主文档响应；子资源（图标等）的 401/404 不打扰页面
                    if (request.isForMainFrame != true) return;
                    final code = errorResponse.statusCode ?? 0;
                    if (code == 401 || code == 403) {
                      // Token 鉴权未通过：停掉自动重试，错误页内嵌 Token 输入
                      _onAuthError(code);
                    } else if (code >= 400) {
                      _onPageError('服务器返回错误（HTTP $code），'
                          '请确认远程服务正常运行后重试。');
                    }
                  },
                ),
                // 页面加载中：进度遮罩（不透明白底，避免黑屏观感）
                if (_pageLoading && _pageError == null)
                  _buildPageLoading(context),
                // 页面加载失败/超时：错误界面
                if (_pageError != null) _buildPageError(context),
                // 自定义缩放控件：左侧、竖排，可拖拽上下移动，避开右下角发送按钮。
                // 默认关闭，仅在设置页开启后显示。
                if (_zoomControlsEnabled && !_pageLoading && _pageError == null)
                  _buildZoomControls(context, stackHeight),
                // 相机入口浮动按钮：默认对话区左侧靠屏幕边，可拖拽上下/左右
                // 移动并吸附到最近边缘（方便左右手操作），默认开启。
                if (_photoControlsEnabled &&
                    !_pageLoading &&
                    _pageError == null)
                  _buildPhotoControls(context, stackHeight, stackWidth),
                // 语音输入浮动按钮：对话区右侧靠屏幕边（与相机入口对称），
                // 可拖拽上下移动，长按按住说话，默认开启。
                // 语音并入相机开启时隐藏右侧麦克风按钮（相机按钮承担语音）。
                if (_voiceControlsEnabled &&
                    !_voiceMergeToCamera &&
                    !_pageLoading &&
                    _pageError == null)
                  _buildVoiceControls(context, stackHeight, stackWidth),
                // 天气动效：云/雨/雪/雾/雷锚定相机按钮当前位置（拖拽上下/左右
                // 均跟随），绘制在按钮上层、低不透明度且不拦截触摸；相机入口
                // 隐藏时一并隐藏。
                if (_photoControlsEnabled &&
                    _weatherEffectsEnabled &&
                    !_pageLoading &&
                    _pageError == null)
                  _buildWeatherOverlay(context, stackWidth),
                // 侧边栏终端按键条：xterm 面板可见时显示在底部中央
                //（手机软键盘没有 Esc/Ctrl/方向键，这些是终端刚需）
                if (_terminalVisible && !_pageLoading && _pageError == null)
                  _buildTerminalKeyBar(context),
              ],
            );
          },
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

  /// WebView 加载失败/超时界面。鉴权失败（401/403）时额外内嵌 Token 输入框，
  /// 保存后立即重载，免去跳转设置页再返回的流程。
  Widget _buildPageError(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_authError ? Icons.lock_outline : Icons.cloud_off,
                  size: 56, color: _authError ? Colors.orange : Colors.red),
              const SizedBox(height: 16),
              Text(
                  _authError ? '需要更新 DSH 访问 Token' : '无法加载远程界面',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  '$_pageError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              if (_authError) ...[
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: TextField(
                    controller: _tokenCtrl,
                    obscureText: true,
                    autofillHints: null,
                    decoration: const InputDecoration(
                      labelText: 'DSH 访问 Token',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _saveTokenAndReload(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _saveTokenAndReload,
                  icon: const Icon(Icons.key),
                  label: const Text('保存 Token 并重连'),
                ),
              ],
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

  /// 自定义浮动缩放控件：定位在**左侧**、竖排，替代原生右下角
  /// 缩放控件（后者固定右下、常覆盖发送按钮）。
  ///
  /// 位置可拖拽自由上下移动（顶边像素坐标，默认屏幕中央）；按钮背景透明，
  /// 尽量少遮挡页面内容。stackHeight 为对话区 Stack 实际高度。
  Widget _buildZoomControls(BuildContext context, double stackHeight) {
    return Positioned(
      left: 6,
      top: _zoomControlsTop,
      child: GestureDetector(
        // opaque：占满命中区域以便捕获拖拽；纯点击仍透传给内部按钮
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _onZoomControlsPanStart(details, stackHeight),
        onPanUpdate: (details) =>
            _onZoomControlsPanUpdate(details, stackHeight),
        child: Material(
          color: Colors.transparent,
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
  /// 键盘、缩放控件）。按钮呈现为**真实观测的月相**（夜间）或**全亮日光模式**
  /// （白天，日出日落联动开启时）——细节见 [_MoonCameraButton]。
  Widget _buildPhotoControls(BuildContext context, double stackHeight,
      double stackWidth) {
    final mergeVoice = _voiceMergeToCamera;
    final dragLeft = _photoControlsDragLeft;
    return Positioned(
      top: _photoControlsTop,
      // 可拖拽左右移动并吸附到左/右边缘（方便左右手操作）：
      // 拖拽中用临时左侧 X，非拖拽时按吸附侧用 left/right 固定边距。
      left: dragLeft ?? (_photoControlsOnLeft ? _edgeGap : null),
      right: (dragLeft == null && !_photoControlsOnLeft) ? _edgeGap : null,
      // 占满命中区域捕获拖拽，点击透传给内部相机按钮。
      // 语音并入相机开启时：长按 = 按住说话（端侧识别，同右侧麦克风按钮），
      // 短按仍为相机（拍照/传图）；关闭时相机按钮不承担长按说话。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            _onPhotoControlsPanStart(details, stackHeight, stackWidth),
        onPanUpdate: (details) =>
            _onPhotoControlsPanUpdate(details, stackHeight, stackWidth),
        onPanEnd: (_) => _onPhotoControlsPanEnd(stackWidth),
        onLongPressStart:
            mergeVoice ? (_) => _onVoiceLongPressStart() : null,
        onLongPressMoveUpdate: mergeVoice ? _onVoiceLongPressMoveUpdate : null,
        onLongPressEnd: mergeVoice ? (_) => _onVoiceLongPressEnd() : null,
        onLongPressCancel:
            mergeVoice ? () => _onVoiceLongPressEnd(cancelled: true) : null,
        child: _MoonCameraButton(
          sunSwitchEnabled: _sunSwitchEnabled,
          showMicBadge: mergeVoice,
          onPressed: _pickAndSendImage,
        ),
      ),
    );
  }

  /// 语音输入浮动按钮：默认吸附**右侧**（比相机入口略高一点），可拖拽到
  /// 左/右屏幕边缘吸附（松手按水平位置吸附最近边缘，方便左右手操作），
  /// 也可上下移动。长按按住说话（端侧流式识别，微信式交互）：上滑取消、
  /// 松手把转写文本注入消息输入框并自动发送；点击无动作（拖拽/长按两个
  /// 手势，避免与注入动作误触）。
  ///
  /// 视觉上**只画麦克风图标本身**（无圆圈底/边框，用户要求：小一点也知道是
  /// 干什么）；命中区域仍占满 48×48，保证拖拽与长按好按。按住说话期间图标
  /// 播放声纹扩散动效（[_VoiceMicButton]），上滑取消时变红——让用户一眼
  /// 知道正在监听。
  Widget _buildVoiceControls(BuildContext context, double stackHeight,
      double stackWidth) {
    // 拖拽中用临时左侧 X；非拖拽时按吸附侧用 left/right 固定边距。
    final dragLeft = _voiceControlsDragLeft;
    return Positioned(
      top: _voiceControlsTop,
      left: dragLeft ?? (_voiceControlsOnLeft ? _edgeGap : null),
      right: (dragLeft == null && !_voiceControlsOnLeft) ? _edgeGap : null,
      // 占满命中区域捕获拖拽与长按；无内部按钮，点击不产生动作
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            _onVoiceControlsPanStart(details, stackHeight, stackWidth),
        onPanUpdate: (details) =>
            _onVoiceControlsPanUpdate(details, stackHeight, stackWidth),
        onPanEnd: (_) => _onVoiceControlsPanEnd(stackWidth),
        onLongPressStart: (_) => _onVoiceLongPressStart(),
        onLongPressMoveUpdate: _onVoiceLongPressMoveUpdate,
        onLongPressEnd: (_) => _onVoiceLongPressEnd(),
        onLongPressCancel: () => _onVoiceLongPressEnd(cancelled: true),
        child: _VoiceMicButton(session: _holdSession),
      ),
    );
  }

  /// 天气动效层：锚定相机按钮当前位置（拖拽跟随移动），宽度约 120dp 的
  /// 左侧窄条——不大面积遮挡对话区；整层 IgnorePointer 不拦截触摸。
  /// 天气未知（未查到/已关闭）或晴朗时不绘制任何内容。
  Widget _buildWeatherOverlay(BuildContext context, double stackWidth) {
    return ValueListenableBuilder<WeatherInfo?>(
      valueListenable: WeatherService.current,
      builder: (context, weather, _) {
        if (weather == null || weather.kind == WeatherKind.clear) {
          return const SizedBox.shrink();
        }
        const width = 120.0;
        const height = 200.0;
        // 垂直锚定：按钮中心对齐动效区约 45% 高度处（云在上、雨落到底部），
        // 并 clamp 在对话区内，按钮拖到顶部/底部时动效区不滑出屏幕。
        final maxTop =
            (_bodyHeight - height).clamp(0.0, double.infinity);
        final top = (_photoControlsTop + _photoControlHeight / 2 - height * 0.45)
            .clamp(0.0, maxTop);
        // 水平锚定：天气正对相机正上方——动效区中心对齐相机按钮中心，跟随按钮
        // 左右拖拽/边缘吸附。相机吸附到左/右边缘时动效区宽度收窄（最多收窄到
        // 约按钮宽度），使动效区保持居中且不越出屏幕，避免旧代码把动效区推向
        // 屏幕中心导致天气偏左/偏右偏离相机。
        final photoLeft = _currentPhotoLeft(stackWidth);
        final centerX = photoLeft + _photoControlWidth / 2;
        final effectiveWidth = math.min(
            width, math.min(2 * centerX, 2 * (stackWidth - centerX)));
        final left = centerX - effectiveWidth / 2;
        return Positioned(
          left: left,
          top: top,
          width: effectiveWidth,
          height: height,
          child: IgnorePointer(
            child: WeatherOverlay(kind: weather.kind),
          ),
        );
      },
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
        // 服务器图标标识"实例/主机"，避免与顶栏绿色模式切换图标撞脸
        avatar: Icon(Icons.dns_outlined, size: 16, color: color),
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

/// 月相相机按钮（48×48 圆形）：相机入口的视觉本体。
///
/// - **夜间**（默认）：呈现真实观测的月相——太阳/月球实际位置计算照明度
///   （小时级连续的朔望周期 29.53 天）与盘面朝向（亮缘位置角 + 观测者
///   纬度/经度/时角决定的旋转），满月最亮、新月留微光。
/// - **白天**（日出日落联动开启时）：显示**全亮**月亮（日光模式，月相
///   特效暂停），日出后全亮、日落后恢复真实月相；开关关闭则始终真实月相。
///
/// 独立 State 持有 30 秒时钟分粒度刷新（照明度/昼转夜切换），避免整屏
/// setState 重建 WebView 子树。
class _MoonCameraButton extends StatefulWidget {
  const _MoonCameraButton({
    required this.sunSwitchEnabled,
    required this.onPressed,
    this.showMicBadge = false,
  });

  /// 日出日落联动开关（设置页可关；关闭 = 始终真实月相）。
  final bool sunSwitchEnabled;

  final VoidCallback onPressed;

  /// 是否显示麦克风图标（语音并入相机开启时显示，放在相机图标正下方，
  /// 提示该按钮支持长按说话）。
  final bool showMicBadge;

  @override
  State<_MoonCameraButton> createState() => _MoonCameraButtonState();
}

class _MoonCameraButtonState extends State<_MoonCameraButton> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nowUtc = now.toUtc();
    // 真实月球观测：绝对时间（UTC）+ 当前生效的观测位置（默认北京/手动/GPS，
    // 设置页可改；observer 变化会触发重建）。
    final obs = MoonAstronomy.compute(nowUtc, MoonLocation.observer.value);
    // 日出日落联动：白天（太阳高度 > −0.833°，即日出~日落）显示全亮月亮
    // （月相暂停），夜间恢复真实月相。
    final dayMode =
        widget.sunSwitchEnabled && SunTimes.isDaytimeAt(nowUtc, MoonLocation.observer.value);
    final lit = dayMode ? 1.0 : obs.illumination;
    final phase = dayMode ? 0.5 : obs.phase01;
    final tilt = dayMode ? 0.0 : obs.tiltDeg;
    final borderColor = const Color(0xFF64B5F6);
    // 有日出日落信息时在提示里展示今日时刻（极昼/极夜无事件则省略）。
    final sun = widget.sunSwitchEnabled
        ? SunTimes.compute(nowUtc, MoonLocation.observer.value)
        : null;
    // 月相/日照提示文案；语音并入相机开启时禁用 tooltip（长按=语音），
    // 避免长按弹出月相提示干扰按住说话。
    final tooltip = dayMode
        ? '添加图片/拍照（视觉工具）·白天·日光模式'
            '${_hm(sun?.sunriseUtc)}~${_hm(sun?.sunsetUtc)}'
            '·观测${MoonLocation.observerLabel}'
        : '添加图片/拍照（视觉工具）·${obs.name}'
            '·照明 ${(obs.illumination * 100).round()}%'
            '·农历${_lunarDayOf(now)}'
            '·观测${MoonLocation.observerLabel}';
    return SizedBox(
      width: 48,
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 2), // 圆形边框
          boxShadow: [
            // 发光随月相变化：满月/白天最亮，新月留微光保持入口可见。
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
          painter: MoonPhasePainter(phase, tilt),
          // 相机图标居中；语音并入相机时麦克风放在相机图标正下方，
          // 不加彩色圆底、颜色与相机图标一致（随月相亮暗切换），合二为一。
          child: Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  IconButton(
                    // 语音并入相机时禁用 tooltip：长按留给语音，不弹月相提示。
                    tooltip: widget.showMicBadge ? null : tooltip,
                    icon: Icon(
                      Icons.camera_alt_outlined,
                      color: lit >= 0.5
                          ? const Color(0xFF1565C0) // 亮面：深蓝图标
                          : Colors.white, // 暗面：白色图标
                    ),
                    iconSize: 22,
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onPressed,
                  ),
                  // 麦克风直接放在相机图标正下方：只画图标本身（无彩色圆底），
                  // 颜色与相机图标一致、随月相亮暗切换，与相机合二为一。
                  if (widget.showMicBadge)
                    Positioned(
                      top: 35,
                      child: Icon(
                        Icons.mic,
                        size: 12,
                        color: lit >= 0.5
                            ? const Color(0xFF1565C0)
                            : Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 本地时刻 HH:mm（日出日落提示用）；null（极昼/极夜）返回占位符。
  static String _hm(DateTime? utc) {
    if (utc == null) return '--:--';
    final local = utc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// 农历日（1~29/30）。统一按北京时间（UTC+8）推算农历，避免设备时区差异
/// 导致月相差一天；异常时退回 15（满月，最亮最显眼）。
int _lunarDayOf(DateTime date) {
  try {
    // 本地时间 → UTC → +8h 得到北京日历字段；lunar 只取年月日，忽略时分。
    final beijing = date.toUtc().add(const Duration(hours: 8));
    return Solar.fromDate(beijing).getLunar().getDay();
  } catch (_) {
    return 15;
  }
}

/// 麦克风语音按钮（右侧语音入口的视觉本体）：平时只是图标本身，按住说话
/// 期间播放**声纹扩散动效**——三层声波环从麦克风向外扩散、图标随呼吸微
/// 放大，上滑取消时整体变红——让用户一眼知道正在监听说话。
///
/// 无圆圈底/边框（用户要求）；48×48 命中区由外层 GestureDetector 提供。
class _VoiceMicButton extends StatefulWidget {
  const _VoiceMicButton({required this.session});

  /// 按住说话会话；null = 空闲（静态图标），非 null = 录音中（播放动效）。
  final HoldToTalkSession? session;

  @override
  State<_VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends State<_VoiceMicButton>
    with SingleTickerProviderStateMixin {
  /// 声纹扩散周期：三层环相位各差 1/3，视觉上连续向外推出。
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  /// 空闲时 cancelMode 的占位监听对象（避免可空 listenable 分支）。
  static final ValueNotifier<bool> _notCancelling = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_VoiceMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  /// 会话开始 → 循环播放；结束 → 停止并复位。
  void _syncAnimation() {
    if (widget.session != null) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final idleColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return ValueListenableBuilder<bool>(
      valueListenable: session?.cancelMode ?? _notCancelling,
      builder: (context, cancelling, _) {
        final active = session != null;
        final color = active
            ? (cancelling
                ? Colors.redAccent
                : Theme.of(context).colorScheme.primary)
            : idleColor;
        return AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = active ? _ctrl.value : 0.0;
            // 图标呼吸：0.9→1.12 缓放，随取消态直接切色即可（动效短暂）。
            final scale = active ? 0.9 + 0.22 * (1 - (2 * t - 1).abs()) : 1.0;
            return CustomPaint(
              painter: _MicWavePainter(t: t, color: color),
              child: Center(
                child: Transform.scale(
                  scale: scale,
                  child: Icon(Icons.mic, size: 24, color: color),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 声纹扩散环画笔：三层圆环从麦克风（中心）向外扩散并渐隐。
class _MicWavePainter extends CustomPainter {
  const _MicWavePainter({required this.t, required this.color});

  /// 动画相位 0..1。
  final double t;

  /// 声波颜色（随取消态切换）。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      paint.color = color.withValues(alpha: (1 - p) * 0.45);
      canvas.drawCircle(center, 13 + 15 * p, paint);
    }
  }

  @override
  bool shouldRepaint(_MicWavePainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}
