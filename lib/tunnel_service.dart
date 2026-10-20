import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:charset/charset.dart' show Charset, gbk;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'foreground_service.dart';
import 'tunnel_diagnostics.dart';
import 'tunnel_policy.dart';

/// 隧道连接状态。
///
/// 语义约定（配合 [TunnelState] / [TunnelAlertPolicy] 使用，UI 侧不要再自行
/// 推断"该不该报错"）：
/// - [idle] 从未连接 / 用户主动断开；
/// - [connecting] 正在握手（首次或自动重试中）；
/// - [connected] 传输层在位（是否真的可用看 [TunnelState.probeOk]）；
/// - [disconnected] 链路类中断，**监督器仍在后台退避重试**，界面只需非阻塞提示；
/// - [failed] 配置类失败（密码/指纹/端口/端口占用），重试不会自己变好，
///   必须告诉用户并给"改设置"入口。
enum TunnelStatus { idle, connecting, connected, failed, disconnected }

/// 隧道对外可见的完整状态快照（单一事实来源）。
///
/// 取代"UI 自己数重连次数 + 自己决定弹不弹错误"的旧结构：次数、下次重试
/// 时间、故障类别、探活结果全部由监督器拥有，界面只是渲染。
class TunnelState {
  const TunnelState({
    this.status = TunnelStatus.idle,
    this.kind = TunnelFailureKind.none,
    this.attempt = 0,
    this.nextRetryAt,
    this.lastError,
    this.lastProbeAt,
    this.probeOk = false,
    this.connectedSince,
    this.profileIndex,
    this.everConnected = false,
  });

  final TunnelStatus status;

  /// 最近一次失败的类别（[TunnelFailureKind.none] = 无故障）。
  final TunnelFailureKind kind;

  /// 本次中断以来已尝试的次数（0 = 尚未失败或刚连上）。
  final int attempt;

  /// 下一次自动重试的时刻；null = 暂无计划（已连上或用户主动断开）。
  final DateTime? nextRetryAt;

  /// 最近一次失败的技术细节（只进"详情/诊断页"，不上主界面）。
  final String? lastError;

  final DateTime? lastProbeAt;

  /// 最近一次端到端探活是否成功。connected 但 probeOk=false 表示"自称连着、
  /// 实际探测不通"——即半开假死，正在判定中。
  final bool probeOk;

  /// 当前会话建立时刻（null = 未连接）。
  final DateTime? connectedSince;

  final int? profileIndex;

  /// 本进程内是否**曾经**成功连上过。分级策略用它区分"链路抖动"与"压根没通过"。
  ///
  /// 不能用 `connectedSince != null` 代替：两条失败路径都带 `clearConnectedSince`，
  /// 于是它永远是 null，`attentionAfterAttempts=3` 成了死代码（任何抖动都在第 2
  /// 次就升格成 attention）。
  final bool everConnected;

  bool get isConnected => status == TunnelStatus.connected;

  /// 端到端可用：传输层在位且最近一次探活通过。
  bool get healthy => isConnected && probeOk;

  /// 监督器是否仍在后台自动重试（用户不需要动手）。
  bool get retryScheduled => nextRetryAt != null;

  /// 主界面横幅文案：短、有结论、带"接下来会怎样"。
  ///
  /// 历史上界面把异常原文 + VPN QoS 长文一起糊屏（`_appendQosHintIfTimeout`），
  /// 用户看到的是噪音而不是信息。技术细节去诊断页看。
  String get userMessage {
    switch (status) {
      case TunnelStatus.connected:
        if (probeOk) return '连接正常';
        return kind == TunnelFailureKind.remoteDown
            ? 'SSH 已连通，但云端服务没有应答：请确认远端服务正在运行'
            : '网络波动，正在检测链路…';
      case TunnelStatus.connecting:
        return attempt == 0
            ? '正在建立 SSH 隧道…'
            : '正在自动重连（第 ${attempt + 1} 次）…';
      case TunnelStatus.failed:
        return tunnelFailureSummary(kind);
      case TunnelStatus.disconnected:
        final base = kind == TunnelFailureKind.none
            ? '隧道已断开'
            : tunnelFailureSummary(kind);
        return retryScheduled
            ? '$base · 正在自动重试（第 ${attempt + 1} 次）'
            : '$base · 正在等待网络恢复';
      case TunnelStatus.idle:
        return '未连接';
    }
  }

  /// 提示分级（界面据此决定"静默 / 非阻塞横幅 / 红色指引"）。
  ///
  /// 特例：**自称连着但探活不过**（半开假死判定中、或云端服务不应答）时用户
  /// 正在实打实地经历"点了没反应"，此时绝不能静默——必须给非阻塞横幅说明
  /// "正在检测/云端服务没起"，否则就是当年那种"顶栏绿灯、页面死转圈"。
  TunnelAlertLevel get alertLevel {
    if (isConnected) {
      if (probeOk) return TunnelAlertLevel.silent;
      return TunnelAlertLevel.busy;
    }
    if (status == TunnelStatus.idle) return TunnelAlertLevel.silent;
    return const TunnelAlertPolicy().levelFor(
      attempt: attempt,
      kind: kind,
      connectedBefore: everConnected,
    );
  }

  TunnelState copyWith({
    TunnelStatus? status,
    TunnelFailureKind? kind,
    int? attempt,
    DateTime? nextRetryAt,
    bool clearNextRetry = false,
    String? lastError,
    bool clearLastError = false,
    DateTime? lastProbeAt,
    bool? probeOk,
    DateTime? connectedSince,
    bool clearConnectedSince = false,
    int? profileIndex,
    bool? everConnected,
  }) {
    return TunnelState(
      status: status ?? this.status,
      kind: kind ?? this.kind,
      attempt: attempt ?? this.attempt,
      nextRetryAt: clearNextRetry ? null : (nextRetryAt ?? this.nextRetryAt),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastProbeAt: lastProbeAt ?? this.lastProbeAt,
      probeOk: probeOk ?? this.probeOk,
      connectedSince:
          clearConnectedSince ? null : (connectedSince ?? this.connectedSince),
      profileIndex: profileIndex ?? this.profileIndex,
      everConnected: everConnected ?? this.everConnected,
    );
  }
}

/// 远程主机类型（用于选择采集命令）。
enum HostType { linux, windows }

/// 本次建链已被取消（用户断开 / 切换目标 / dispose）。
///
/// 单独成类型是为了让 `_attemptOnce` 的 catch 能把它与真正的故障区分开：取消
/// **不记失败、不分类、不排退避**，否则会凭空多出一次"隧道已断开·正在自动重试"。
class TunnelAbortedException implements Exception {
  const TunnelAbortedException();
  @override
  String toString() => '隧道连接已取消';
}

/// 主机密钥指纹不匹配（TOFU 拒绝）。
///
/// 以前用一个服务级 `bool _hostKeyMismatch` 传递，而主隧道、`testConnection`、
/// 监控隧道、Unsloth 隧道**共用同一个标志**：设置页点一下"测试连接"连到另一台
/// 指纹已变的主机，主隧道下一次因 DNS 失败进 catch 就被误判成 hostKey，弹出
/// 红色"服务器主机密钥与上次记录不一致"，用户照着去清指纹也治不好。改为随
/// 单次连接上下文抛出的异常类型。
class TunnelHostKeyMismatchException implements Exception {
  const TunnelHostKeyMismatchException();
  @override
  String toString() => 'SSHHostkeyError: Hostkey verification failed';
}

/// 远端文件失败的具体种类。原来所有失败（不存在 / 是目录 / 无权限 / 隧道断 /
/// 超时 / 文件被占用）都合并成一句「路径不存在或无权限」，是这条链路上最费
/// 排查时间的设计——它们的处置方式完全不同。
enum RemoteFailureKind {
  notConnected,
  notFound,
  isDirectory,
  permission,
  timeout,
  tooLarge,
  channelExhausted,
  other,
}

/// 远程文件读取失败（带用户可读原因，查看器据此展示）。
class RemoteReadException implements Exception {
  const RemoteReadException(this.message, {this.kind = RemoteFailureKind.other});
  final String message;
  final RemoteFailureKind kind;
  @override
  String toString() => message;
}

/// [TunnelService.openRemoteFileDetailed] 的结果：句柄 + 失败原因。
///
/// 保留返回裸 `SftpFile?` 的 [TunnelService.openRemoteFile] 以兼容旧调用方，
/// 但下载/预览一律用带原因的版本，否则"文件不存在"会被说成"隧道未连接"。
class RemoteOpenResult {
  const RemoteOpenResult(
    this.file, {
    this.sftp,
    this.reason,
    this.kind = RemoteFailureKind.other,
    this.size,
  });

  final SftpFile? file;

  /// 句柄所属的 SFTP 会话：调用方收尾时一并交还 `TunnelService.closeRemoteFile`，
  /// 以便从存活会话表里摘除（隧道拆毁时才能准确 abort 存活会话）。
  final SftpClient? sftp;
  final String? reason;
  final RemoteFailureKind kind;

  /// `fstat` 得到的大小（未知为 null）：避免上层为拿尺寸再开一次往返。
  final int? size;

  bool get ok => file != null;
}

/// 单次主机采样：GPU 使用率 / GPU 温度 / CPU / 内存使用率。
class HostSample {
  const HostSample({
    required this.cpu,
    required this.mem,
    required this.gpu,
    this.gpuTemp = -1,
  });

  /// CPU 使用率（0-100）。
  final double cpu;

  /// 内存使用率（0-100）。
  final double mem;

  /// GPU 使用率（0-100），-1 表示无 GPU / 无数据。
  final double gpu;

  /// GPU 温度（℃），-1 表示无 GPU / 无数据。
  final double gpuTemp;
}

/// 负责建立 SSH 隧道：把手机 `127.0.0.1:<localPort>` 转发到远程
/// `127.0.0.1:3080`（DSH Web UI），并做 SSH 保活。
///
/// 同一时刻只激活一路隧道（WebView 同一时刻加载一个实例），
/// 通过 [activeProfileIndex] 记录当前连接的实例索引。
class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  /// SFTP 单次内存读取上限（8MB）：与成果 JS 桥的 fetch 上限一致。
  /// 超过该大小的文件不读入内存（readBytes），避免移动端 OOM，
  /// 大文件应走 [DownloadManager] 的下载/断点续传流程。
  static const int maxRemoteReadBytes = 8 * 1024 * 1024;

  /// 预览可读上限（可配，默认 20MB）：8MB 是"早期拍脑袋"的值，与 JS 桥那个
  /// 8MB 互不知情，导致大量中等体积的报告/日志点开就说"文件过大"。
  /// 超过 [maxRemoteReadBytes] 但在本上限内的文件仍可读，只是不再一次性
  /// 交给 highlight/markdown 全量排版（由查看器负责截断提示）。
  static int previewMaxBytes = 20 * 1024 * 1024;

  // ---- SFTP 单步超时（必须显式加）----
  //
  // 库侧 `SftpClient` 的 `_waitReply` 是裸 Completer，且构造时**没有**注册
  // channel 的 onDone/onError：TCP 半开（切网/锁屏/被 NAT 掐掉）时
  // `sftp()` / `open()` / `stat()` / `readBytes()` 的 await **永不返回**。
  // 后果不是"报错"而是"永久转圈"：查看器一直转、下载页一直 0%，而
  // `_running` 恒真还会把"重试/继续"永久挡在守卫外。监督器把隧道重建好
  // 也救不回这些旧 await——所以只能在调用侧设边界。
  // 对照：exec 8s、forwardLocal 8s、探活 5s、上传 2min，唯独读文件原来没有。
  static const Duration sftpOpenTimeout = Duration(seconds: 8);
  static const Duration sftpStatTimeout = Duration(seconds: 6);
  static const Duration sftpReadTimeout = Duration(seconds: 30);

  /// 隐藏产物「文件名 → 完整路径」反查的总预算。原来对每个候选目录做
  /// `2 种分隔符 × 3 种路径形态` 的逐个 `open`，5 个目录就是 30 条 SSH 会话
  /// 串行开合（远端 sshd 默认 `MaxSessions=10`），既慢又直接把通道配额打满。
  static const Duration resolveBudget = Duration(seconds: 8);

  /// [resolveRemotePath] 兜底试开的最大次数（目录列表不可读时才走到这里）。
  static const int resolveMaxProbes = 8;

  /// 存活的只读 SFTP 会话（预览/另存为/下载共用一张表）。
  ///
  /// 存在的唯一理由：隧道拆毁时能把它们逐个 `close()`，从而把卡在
  /// `_waitReply` 上的 await 全部 abort 掉。库里没有任何机制做到这点
  /// （`SftpClient` 不监听通道关闭，waiter 也没有超时）。
  final Set<SftpClient> _liveSftpClients = <SftpClient>{};

  // ==================== 连接监督器（单一事实来源）====================
  //
  // 旧结构把「重连」散落在 UI 里（`_scheduleReconnect` / `_reconnectCount` /
  // `_maxReconnect = 5`），造成三个必现故障：
  //   1. 5 次线性退避（2/4/6/8/10s，共 30 秒）烧完后**彻底放弃且不留任何定时器**
  //      → 移动网络/Tailscale 重拨通常要 30 秒以上，于是每次真实断线都永远停在
  //      死错误页，只能用户手动点重试；
  //   2. `connect()` 并发时「早退即成功」，UI 拿到正常返回就点亮绿灯并把重连
  //      计数清零 → 假 connected + 退避节奏被打乱；
  //   3. dartssh2 的 `forwardLocal` 与 keepalive **都没有响应超时**，TCP 半开时
  //      状态会无限期滞留 connected、转发请求永久挂起 → 「看着连着其实死了」。
  // 现在：重试计划 / 周期探活 / 故障分类 / 事件日志全部收拢在本单例（不随根路由
  // 重建而丢失），UI 只订阅 [stateStream] 做渲染，不再自行数次数、自行决定报错。

  /// 连接期间的端到端探活周期。
  static const Duration probeInterval = Duration(seconds: 15);

  /// 单次探活的整体超时（含 TCP + HTTP 应答）。
  static const Duration probeTimeout = Duration(seconds: 5);

  /// 连续探活失败多少次判定"假死"并强制重建。
  static const int probeFailThreshold = 3;

  /// `client.forwardLocal()` 等待上限。dartssh2 内部该 Future **无超时**，
  /// 半开传输层下会永久挂起（见 `_handleForward`）。
  static const Duration forwardOpenTimeout = Duration(seconds: 8);

  /// 连续转发建链超时多少次判定传输层已死。
  static const int forwardOpenFailThreshold = 2;

  /// 最近有转发流量即视为端到端存活的时间窗（SSE/下载期间不重复探活，
  /// 避免拥塞导致的单次误判把好好一条隧道拆掉）。
  static const Duration forwardFreshWindow = Duration(seconds: 10);

  /// 断线期间轮询网络接口变化的周期：用来替代 connectivity_plus（不引新依赖），
  /// WiFi⇄蜂窝切换、Tailscale 重拨后**秒级感知**并立即重试，而不是干等退避定时器。
  static const Duration networkPollInterval = Duration(seconds: 15);

  /// 网络接口变化触发"立即重试"的冷却时间。
  ///
  /// 接口签名是个很吵的信号：WiFi⇄蜂窝交接、Tailscale tun0 反复出现/消失，都会
  /// 让它每 15 秒就变一次。没有冷却时，每次变化都等于发起一轮全量 TCP+KEX+认证
  /// （单次最长 35 秒），等于自己给服务端造认证风暴。
  static const Duration networkRetryCooldown = Duration(seconds: 12);

  /// 重连退避：**永不放弃**。800ms 起指数增长，60 秒封顶后无限次继续。
  static const TunnelBackoff _backoff = TunnelBackoff(
    first: Duration(milliseconds: 800),
    cap: Duration(seconds: 60),
  );

  static final math.Random _rng = math.Random();

  final StreamController<TunnelState> _stateController =
      StreamController<TunnelState>.broadcast();

  TunnelState _state = const TunnelState();

  /// 当前完整状态（界面渲染的唯一依据）。
  TunnelState get state => _state;

  /// 状态流：每次状态变化广播一次完整快照。
  Stream<TunnelState> get stateStream => _stateController.stream;

  /// 兼容旧调用点的状态视图（等价于 `state.status`）。
  TunnelStatus get status => _state.status;

  SSHClient? _client;
  ServerSocket? _server;

  /// 配置端口被外部程序占住时**临时**改用的端口（null = 用的就是配置里那个）。
  /// 本地端口只是 WebView / 预览 / 探活的入口，不是与远端约定好的协议端口，
  /// 所以可以让系统随机分配一个先把隧道跑起来——前提是所有人都取"实际生效"
  /// 的那个，见 [activeLocalPort]。
  int? _localPortFallback;

  /// **实际生效**的本地端口：正在监听的 socket → 临时端口 → 配置端口。
  ///
  /// 任何要访问 `127.0.0.1:<port>` 的地方都必须走它：临时端口模式下，配置里
  /// 那个端口正被别人的服务占着，按配置端口发请求会把请求打到**别人的程序**
  /// 上（表现为"打开了一个莫名其妙的页面"，比连不上更难查）。
  int? get activeLocalPort {
    final s = _server;
    if (s != null) return s.port;
    final f = _localPortFallback;
    if (f != null) return f;
    return _activeConfig?.localPort ?? _desiredConfig?.localPort;
  }

  /// 本次隧道是否在用临时端口（界面要如实告诉用户"端口换了"）。
  bool get usingFallbackLocalPort => _localPortFallback != null;

  /// 当前激活（已连接/正在连接）的实例索引，null 表示无。
  int? _activeProfileIndex;
  int? get activeProfileIndex => _activeProfileIndex;

  /// 当前激活实例的配置（用于上传目录等需要用户名的回退策略）。
  SSHConfig? _activeConfig;

  /// 已建立的转发连接（本地侧 Socket）。模式切换时必须全部销毁：WebView
  /// 按 `127.0.0.1/localPort` 复用 HTTP keep-alive 连接，而每条 TCP 连接在
  /// 建立时已固定转发到"当时"的远端端口——不销毁的话，切换后复用的旧连接
  /// 会把请求送到另一台服务上（DSH⇄Zcode token 互不认，报「token 无效」，
  /// 多切几次连接池里全是错配连接，必现）。
  final Set<Socket> _forwardConns = {};

  /// 已 accept 但还在等 `forwardLocal` 的本地连接。
  ///
  /// 这些 socket 既没进转发、也没人销毁，会在半开场景下无限吊着 WebView 的
  /// 连接池（旧实现 `_forwardConns.clear()` 只清集合不管它们）。重建时必须
  /// 一并 destroy，否则重连成功后 WebView 仍可能复用这条僵尸连接。
  final Set<Socket> _pendingForwards = {};

  // ---- 监督器内部状态 ----
  bool _wantConnected = false;
  int _connectSeq = 0;

  /// 最近一次 `connect()` 的序号（见 [_connectSeq] 的用途）。
  int get connectSeq => _connectSeq;

  SSHConfig? _desiredConfig;
  int? _desiredProfileIndex;

  /// 进行中的尝试：并发 `connect()` 共享同一次结果（修「早退即成功」）。
  ///
  /// 必须连**目标**一起比对（[_inflightKey]）：曾经 `connect(B)` 直接复用了 A 实例
  /// 的在建尝试并把它当成 B 的成功返回，于是"实例 B 的页面跑在实例 A 的隧道上"。
  Future<TunnelState>? _inflight;
  String _inflightKey = '';

  /// 世代号：`disconnect()` / 切换目标 / `dispose()` 时自增，用来作废**在途**的建链
  /// 与已排定的退避定时器。没有它会出两类鬼故事：
  ///  · 用户已断开，一条正在 `SSHSocket.connect`（最长 15s）的尝试回来后照样把
  ///    隧道连回来、绑定本地端口并启动看门狗（没人再会去关它）；
  ///  · 早先某次失败排下的退避定时器，在十几秒后把刚建好的健康隧道整条拆掉重连。
  int _generation = 0;

  Timer? _retryTimer;
  Timer? _watchdogTimer;
  Timer? _networkTimer;
  bool _rebuilding = false;
  int _attempt = 0;
  int _probeFailures = 0;
  int _forwardOpenFailures = 0;
  DateTime? _lastForwardActivity;
  String? _networkSignature;
  DateTime? _lastNetworkRetryAt;

  /// 作废一切在途尝试与已排定的重试。
  ///
  /// 只改 `_wantConnected` 不够：`_attemptOnce` 里 `await SSHSocket.connect(...)`
  /// 回来后无人复查，会把已经"断开"的隧道重新连上；同理 `_retryTimer` 也已排好。
  void _bumpGeneration(String reason) {
    _generation += 1;
    _log('supervisor', '作废旧尝试与重试计划（$reason，gen=$_generation）');
  }

  static String _targetKey(SSHConfig? c, int? profileIndex) => c == null
      ? ''
      : '${profileIndex ?? -1}|${c.host}:${c.sshPort}|${c.username}'
          '|local=${c.localPort}|auth=${c.authType}';

  void _setState(TunnelState next) {
    _state = next;
    // 广播流无监听者时 add 会被安全丢弃，无需 _disposed 守卫。
    _stateController.add(next);
    _syncForegroundService(next);
  }

  /// 前台服务与隧道联动。
  ///
  /// 旧实现只在 `connected` 时启动、其余一律 stop，结果**正在后台重连时
  /// wakelock 被释放**——Doze 下最容易被打断的恰好就是重连过程。改为：
  /// 只要用户期望保持连接（`_wantConnected`）且不是主动断开，就一直持有。
  void _syncForegroundService(TunnelState s) {
    final shouldKeepAlive = _wantConnected && s.status != TunnelStatus.idle;
    if (shouldKeepAlive) {
      ForegroundTunnelService.instance.start();
    } else {
      ForegroundTunnelService.instance.stop();
    }
  }

  // ---------------- 对外连接入口 ----------------

  /// 建立并保持隧道：**幂等、并发安全、不抛异常**。
  ///
  /// 与旧实现的三点关键区别：
  /// - 并发调用共享同一次尝试（旧的 `if (_connecting) return;` 会让第二个调用
  ///   拿到"成功"，UI 于是点亮假绿灯 —— 这是"绿灯但打不开"的根因）；
  /// - 失败不抛，而是返回带故障类别的 [TunnelState]，由监督器按 [TunnelBackoff]
  ///   无限次自动重试（旧实现抛异常 + UI 数 5 次就永久放弃）；
  /// - 已端到端可用且目标未变才幂等早退，否则一律发起尝试（半开假死也能救回）。
  Future<TunnelState> connect(SSHConfig config, {int? profileIndex}) async {
    // 认领序号：页面 dispose 时据此判断隧道是否已被"更新的页面"接管（路由替换时
    // 旧页的 dispose 晚于新页的 connect，无条件 disconnect 会掐掉新页刚拉起的隧道）。
    _connectSeq += 1;
    _wantConnected = true;
    _desiredConfig = config;
    _desiredProfileIndex = profileIndex;

    final active = _activeConfig;
    if (_state.healthy &&
        _client != null &&
        _server != null &&
        active != null &&
        _isSameTarget(active, config)) {
      return _state;
    }
    // 目标与在途尝试不一致（典型：A 还在认证，用户切到 B）：不能把 A 的结果当
    // B 的成功返回，先作废 A，再为 B 发起全新尝试。
    final key = _targetKey(config, profileIndex);
    if (_inflight != null && _inflightKey != key) {
      _bumpGeneration('连接目标切换');
    }
    return _runAttempt(key);
  }

  /// 主动断开（切实例 / 退出 / 改配置前）：停止监督器的自动重试。
  Future<void> disconnect() async {
    _wantConnected = false;
    _bumpGeneration('用户主动断开');
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _networkTimer?.cancel();
    _networkTimer = null;
    _networkSignature = null;
    _attempt = 0;
    _probeFailures = 0;
    _forwardOpenFailures = 0;
    await _teardown();
    // 回到空闲态，但保留「本进程曾经连上过」这一事实：它决定后续失败的升级
    // 节奏（连上过又断 = 链路抖动；从未连上 = 地址/网络根本不对，更早升级）。
    _setState(const TunnelState().copyWith(everConnected: _state.everConnected));
  }

  /// 顶栏「主动刷新」：立刻端到端探活；探不通直接强制重建，探得通也清掉可能
  /// 悬挂的转发连接，逼 WebView 重新建连。用户永远有一个能按的按钮。
  Future<bool> forceRefresh() async {
    _log('ui', '用户主动刷新连接');
    if (_client != null) {
      final ok =
          await _probeEndpoint(reason: 'manual', forceRebuildOnFail: true);
      if (ok) {
        _destroyForwardConns(reason: '手动刷新');
        return true;
      }
      return _state.healthy;
    }
    _resetAttempt();
    await _runAttempt();
    return _state.healthy;
  }

  /// 外部事件（回前台、用户点横幅"重试"等）：立刻重试/探活，不等退避定时器。
  ///
  /// [reason] 进诊断日志，便于事后区分是谁触发的连接风暴。
  void notifyShouldReconnectNow(String reason) {
    if (!_wantConnected) return;
    _log('supervisor', '外部事件 → 立即处理（$reason）');
    if (_client != null) {
      // 自称连着：先探一次，探不通当场重建（回前台时不等 3 次阈值）。
      unawaited(_probeEndpoint(reason: reason, forceRebuildOnFail: true));
      return;
    }
    _resetAttempt();
    unawaited(_runAttempt());
  }

  /// 页面加载失败/超时：请监督器核实链路真伪。
  ///
  /// WebView 报"加载失败"而隧道自称 connected 时，多半是半开假死而不是页面问题；
  /// 交给探活判定，比在 UI 里"再试三次然后弹红字"更接近真相。
  void reportPageFailureAndAsk(String reason) {
    if (_client == null) return; // 本来就没连上，监督器自有安排
    unawaited(_probeEndpoint(reason: 'page:$reason', forceRebuildOnFail: false));
  }

  // ---------------- 监督器内核 ----------------

  Future<TunnelState> _runAttempt([String? key]) async {
    if (!_wantConnected) return _state;
    final wantKey = key ?? _targetKey(_desiredConfig, _desiredProfileIndex);
    final inflight = _inflight;
    // 并发去重：共享同一次尝试。**只有目标相同才算同一次**——否则切实例时会把
    // 上一个实例的建链结果当成本次的成功返回（跨实例串档）。
    if (inflight != null && _inflightKey == wantKey) return inflight;
    _retryTimer?.cancel();
    _retryTimer = null;
    final fut = _attemptOnce(wantKey);
    _inflight = fut;
    _inflightKey = wantKey;
    try {
      return await fut;
    } finally {
      if (identical(_inflight, fut)) {
        _inflight = null;
        _inflightKey = '';
      }
    }
  }

  Future<TunnelState> _attemptOnce(String key) async {
    final config = _desiredConfig;
    if (config == null) return _state;
    final gen = _generation;
    bool aborted() => !_wantConnected || gen != _generation;

    await _teardown();
    // teardown 会让出事件循环：期间用户可能已断开 / 目标已切换。
    if (aborted()) {
      _log('connect', '尝试在排队阶段已被取消，不再建链');
      return _state;
    }
    _setState(_state.copyWith(
      status: TunnelStatus.connecting,
      probeOk: false,
      clearNextRetry: true,
      clearConnectedSince: true,
      profileIndex: _desiredProfileIndex,
    ));

    final started = DateTime.now();
    _log('connect',
        '第 ${_attempt + 1} 次尝试 ssh://${config.username}@${config.host}:${config.sshPort}'
        ' → 本地 :${config.localPort} → 远端 :${config.activeRemotePort}'
        '（目标 $key）');
    try {
      await _openTunnel(config, aborted: aborted);
      // 建链期间被断开/换了目标：这条会话已经没人要了，当场收掉，绝不点亮
      // connected、绝不启动看门狗（旧实现在这里留下一条没人管的活隧道）。
      if (aborted()) {
        _log('connect', '建链完成时已被取消，立即回收会话');
        await _teardown();
        return _state;
      }
      final at = DateTime.now();
      _probeFailures = 0;
      _forwardOpenFailures = 0;
      _attempt = 0;
      // 成功即撤销**一切**遗留的退避定时器：`clearNextRetry` 只清界面字段，
      // 定时器若还在，十几秒后会回调 `_runAttempt` → 无条件 `_teardown` → 把刚
      // 建好的健康隧道整条拆掉重来（表现：连上十几秒莫名重载一次）。
      _retryTimer?.cancel();
      _retryTimer = null;
      _setState(_state.copyWith(
        status: TunnelStatus.connected,
        kind: TunnelFailureKind.none,
        attempt: 0,
        probeOk: true,
        lastProbeAt: at,
        connectedSince: at,
        clearLastError: true,
        clearNextRetry: true,
        everConnected: true,
      ));
      _startWatchdog();
      _stopNetworkWatcher();
      _log('connect',
          '隧道就绪（${at.difference(started).inMilliseconds}ms），看门狗已启动（每 ${probeInterval.inSeconds}s 探活）');
      return _state;
    } on TunnelAbortedException {
      _log('connect', '本次尝试已取消（断开/切换目标），不落状态、不排重试');
      return _state;
    } catch (e) {
      // 用户主动断开/切换目标之后不再落"失败"状态、也不再排重试：否则界面会
      // 在用户按下断开之后显示"隧道已断开·正在自动重试（第 1 次）"这种鬼话。
      if (aborted()) {
        _log('connect', '失败发生在取消之后，忽略（$e）');
        return _state;
      }
      final kind =
          e is TunnelHostKeyMismatchException
              ? TunnelFailureKind.hostKey
              : classifyTunnelFailure(e);
      _attempt += 1;
      final delay = _backoff.delayFor(_attempt, random: _rng.nextDouble);
      final next = DateTime.now().add(delay);
      final hard = isConfigurationFailure(kind);
      // 「重试一万次也没用」的那一类：端口占用不会因为多试几次就空出来
      // （真机实测：界面「第 4 次尝试 · 约 5 秒后自动重试」空转到天荒地老）。
      // 能自己救的在绑定时已经救过（临时端口），走到这里说明真没辙——
      // 停下来把「修改设置 / 立即重试」交给用户，别用空转假装在干活。
      final futile = isFutileRetryFailure(kind);
      _setState(_state.copyWith(
        status: hard ? TunnelStatus.failed : TunnelStatus.disconnected,
        kind: kind,
        attempt: _attempt,
        lastError: '$e',
        nextRetryAt: futile ? null : next,
        probeOk: false,
        clearConnectedSince: true,
      ));
      _log('connect',
          '第 $_attempt 次尝试失败（$kind）：$e',
          level: hard ? TunnelEventLevel.error : TunnelEventLevel.warn);
      if (futile) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _log('connect', '本地端口问题：自动重试不会让它空出来，已停止重试；'
            '请在「修改设置」里换一个本地端口后点「立即重试」',
            level: TunnelEventLevel.error);
        return _state;
      }
      _log('connect',
          hard
              ? '配置类故障：暂停快速重试，每 ${delay.inSeconds}s 兜底再试一次'
              : '${delay.inSeconds}s 后自动重试（永不放弃）');
      _scheduleRetry(delay);
      _startNetworkWatcher();
      return _state;
    }
  }

  /// 真正的建链过程：TCP → KEX → 认证 → 本地监听。抛出的异常交给 [TunnelBackoff] 重试。
  ///
  /// 失败时**立即关掉已建立的会话**：dartssh2 的 `SSHSocket.connect(timeout:)`
  /// 只覆盖 TCP 三次握手，KEX/认证阶段对端沉默不会自己报错（库内全程没有
  /// timer），我们外层的 20s 超时是唯一护网——若不在此处补 `close()`，这条
  /// 半死的 socket 会一直挂到下一次重试才被发现和回收。
  Future<void> _openTunnel(SSHConfig config,
      {bool Function() aborted = _neverAborted}) async {
    // 1) 建立底层 TCP 到 SSH 服务器
    final socket = await SSHSocket.connect(config.host, config.sshPort,
        timeout: const Duration(seconds: 15));

    // 2) 认证：密钥优先，密码兜底
    final List<SSHKeyPair>? identities = config.useKey
        ? SSHKeyPair.fromPem(config.privateKeyPem,
            config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
        : null;

    // 主机密钥不匹配是**本次连接**的属性，用局部变量承接（见
    // [TunnelHostKeyMismatchException] 的说明：全局标志会被并发连接串档）。
    var hostKeyMismatch = false;
    final client = SSHClient(
      socket,
      username: config.username,
      identities: identities,
      onPasswordRequest: config.useKey ? null : () async => config.password,
      // SSH 保活：每 10s 发一次 keepalive，降低移动网络/Tailscale 空闲断连概率。
      // 注意：库内 `ping()` 发 `keepalive@openssh.com` 后 **await 一个没有超时的
      // reply queue**（ssh_client.dart `_globalRequestReplyQueue.next`），半开链路
      // 上永久挂起，因此它**不能**直接用来判定断开——所有 ping 调用都必须由调用方
      // 包 `.timeout(...)`（见 [_pingTransport]），链路是否真活着以端到端探活为准。
      keepAliveInterval: const Duration(seconds: 10),
      // 主机密钥 TOFU：首次记录指纹，后续比对（见 _verifyHostKey）
      onVerifyHostKey: (hostkeyType, fingerprint) => _verifyHostKey(
            config,
            hostkeyType,
            fingerprint,
            onMismatch: () => hostKeyMismatch = true,
          ),
    );

    // 建链过程中用户可能已经断开（`SSHSocket.connect` + KEX 最长十几秒）。
    // 在登记为"当前会话"**之前**收口：否则会出现"用户已断开、这里却把会话
    // 连回来并启动看门狗"的孤儿隧道。
    if (aborted()) {
      try {
        client.close();
      } catch (_) {}
      throw const TunnelAbortedException();
    }

    _client = client;
    _activeConfig = config;

    // 传输异常/断开时通知监督器，并清理资源
    client.done.then(
      (_) => _onTransportClosed(client),
      onError: (Object e) => _onTransportClosed(client, failed: true, error: e),
    );

    try {
      // 3) 等待认证完成（库内此阶段无任何超时，20s 是唯一护网）
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        _log('connect', 'SSH 认证超时', level: TunnelEventLevel.warn);
        throw const SocketException('SSH 认证超时');
      });
      // 3.5) 认证完成后确认未被并发断开/替换（竞态守卫）：
      // 若期间 disconnect() 已执行（_client 被置空/替换），放弃本次连接，
      // 避免绑定一个已失效 client 的"假隧道"并误报 connected。
      if (_client != client || aborted()) {
        throw const TunnelAbortedException();
      }

      // 4) 本地监听端口（占用时自己救自己，见 _bindLocalListener）
      final server = await _bindLocalListener(config);
      // 绑定后再确认一次：期间被断开则释放端口，防止端口被本类残留占住，
      // 也避免给一条没人要的会话挂上监听。
      if (_client != client || aborted()) {
        await server.close();
        throw const TunnelAbortedException();
      }
      _server = server;
      server.listen(_handleLocalConnection);
    } catch (e) {
      // 立即回收半途而废的会话：否则这条 socket 会挂到下一次重试才被 close，
      // 期间既占着远端 sshd 的连接配额，也可能继续往已死的 TCP 里塞保活包。
      if (_client == client) {
        _client = null;
        _activeConfig = null;
        _activeProfileIndex = null;
        try {
          client.close();
        } catch (_) {}
      }
      // TOFU 拒绝要带类型上抛，供上层判成"配置类"而不是泛泛的链路故障。
      if (hostKeyMismatch) throw const TunnelHostKeyMismatchException();
      rethrow;
    }
  }

  /// 是否"地址已被占用"。Android/Linux 上 EADDRINUSE = 98。
  static bool _isAddressInUse(Object e) {
    if (e is! SocketException) return false;
    final code = e.osError?.errorCode;
    if (code == 98 || code == 48 /* macOS EADDRINUSE */) return true;
    final m = e.message.toLowerCase();
    return m.contains('already in use') || m.contains('already bound');
  }

  /// 谁占着这个端口？Android 无 root 拿不到进程表，只能做**可连通性探测**：
  /// 能连上 = 有程序正在监听（上一个没释放干净的隧道，或第三方 App）；
  /// 连不上 = 内核侧残留/半关。给不出进程名，但"有没有人在听"已经足够用户
  /// 判断该去关 App 还是直接换端口。
  Future<String> _describeLocalPortHolder(int port) async {
    try {
      final probe = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 400));
      await probe.close().catchError((_) {});
      try {
        probe.destroy();
      } catch (_) {}
      return '有程序正在监听，且能接受连接';
    } catch (_) {
      return '无进程应答（端口处于内核残留或半关状态）';
    }
  }

  /// 绑定本地监听端口，**占用时不是一路 rethrow 让用户自己想办法**。
  ///
  /// 三步，顺序不能换：
  ///  1. 先怀疑自己人：上一轮 teardown 没走完、或并发 connect 时，`_server`
  ///     可能还占着同一个端口——这时提示"请关闭其它占用该端口的程序"是句废话，
  ///     用户在自己的手机上根本找不到那个"程序"。
  ///  2. 真被外部占住：改用系统分配的临时端口，隧道先通起来。本地端口不是
  ///     协议约定，值得为了"能用"让步；但一定要记下来并让界面可见。
  ///  3. 连临时端口都绑不上（极罕见）：抛带占用结论的异常，上层据此停止
  ///     无意义的自动重试。
  Future<ServerSocket> _bindLocalListener(SSHConfig config) async {
    final stale = _server;
    if (stale != null) {
      _server = null;
      try {
        await stale.close();
      } catch (_) {}
      _log('bind', '释放本进程残留的本地监听 :${config.localPort}',
          level: TunnelEventLevel.warn);
    }
    try {
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, config.localPort);
      _localPortFallback = null;
      return server;
    } on SocketException catch (e) {
      if (!_isAddressInUse(e)) rethrow;
      final holder = await _describeLocalPortHolder(config.localPort);
      try {
        final server =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        _localPortFallback = server.port;
        _log('bind',
            '本地端口 ${config.localPort} 被占用（$holder），本次改用临时端口 '
            '127.0.0.1:${server.port}（功能不受影响，建议在设置里永久换个端口）',
            level: TunnelEventLevel.warn);
        return server;
      } on SocketException catch (e2) {
        if (!_isAddressInUse(e2)) rethrow;
        throw TunnelLocalPortOccupiedException(config.localPort, holder);
      }
    }
  }

  static bool _neverAborted() => false;

  void _scheduleRetry(Duration delay) {
    // 定时器也要绑世代：`_wantConnected` 可能被下一轮 `connect()` 又置回 true，
    // 于是上一段故障排下的旧票会在不该重试的时刻触发重试（最坏情况：把刚建好的
    // 健康隧道拆掉重来）。世代不符即视为作废。
    final gen = _generation;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!_wantConnected || gen != _generation) return;
      unawaited(_runAttempt());
    });
  }

  void _resetAttempt() {
    _attempt = 0;
    _probeFailures = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(_state.copyWith(clearNextRetry: true, attempt: 0));
  }

  /// 探活判定为死 → 当场重建（不等用户、也不等下一次退避）。
  Future<void> _forceRebuild(String reason) async {
    if (!_wantConnected) return;
    // 并发探活（看门狗 / 回前台 / 转发超时）可能同时判定已死：只允许一个重建在跑。
    if (_rebuilding) {
      _log('supervisor', '重建已在进行中，忽略重复请求（$reason）');
      return;
    }
    _rebuilding = true;
    try {
      await _forceRebuildInner(reason);
    } finally {
      _rebuilding = false;
    }
  }

  Future<void> _forceRebuildInner(String reason) async {
    _log('supervisor', '判定链路已死 → 强制重建（$reason）',
        level: TunnelEventLevel.warn);
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    await _teardown();
    // kind 留给接下来的尝试去判定：这里写死 remoteDown 会让"转发建链超时"这类
    // 明明是该重建的场景，闪现一句"云端服务没有应答"的误导性文案。
    _attempt = 0; // 新的一段故障：从快退避重新开始，让用户尽快看到恢复
    _setState(_state.copyWith(
      status: TunnelStatus.disconnected,
      kind: TunnelFailureKind.none,
      probeOk: false,
      // 界面计数必须跟着内部计数一起归零，否则横幅会显示"第 5 次尝试"而内部
      // 其实已经开始第 1 次快退避（纯展示不一致，但正是这种不一致最伤信任）。
      attempt: 0,
      clearConnectedSince: true,
      clearNextRetry: true,
    ));
    await _runAttempt();
  }

  /// 传输层关闭的统一处理：清理 + 交给监督器按退避重连。
  void _onTransportClosed(SSHClient client,
      {bool failed = false, Object? error}) {
    if (_client != client) return; // 旧连接的迟到回调，忽略
    _log('transport',
        failed ? 'SSH 传输层异常关闭：$error' : 'SSH 传输层已关闭',
        level: failed ? TunnelEventLevel.warn : TunnelEventLevel.info);
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _destroyForwardConns(reason: '传输层关闭');

    final server = _server;
    _server = null;
    _localPortFallback = null;
    server?.close();
    _client = null;
    _activeProfileIndex = null;
    _activeConfig = null;

    if (!_wantConnected) {
      _setState(
          const TunnelState().copyWith(everConnected: _state.everConnected));
      return;
    }
    // 对端干净地关掉了会话（sshd 重启、服务端 idle 超时）没有异常对象：这是
    // "断开"而不是"故障"，文案该是"隧道已断开"，不该出现"连接异常"。
    final kind =
        error == null ? TunnelFailureKind.none : classifyTunnelFailure(error);
    _attempt += 1;
    final delay = _backoff.delayFor(_attempt, random: _rng.nextDouble);
    final hard = isConfigurationFailure(kind);
    _setState(_state.copyWith(
      status: hard ? TunnelStatus.failed : TunnelStatus.disconnected,
      kind: kind,
      attempt: _attempt,
      lastError: error?.toString(),
      nextRetryAt: DateTime.now().add(delay),
      probeOk: false,
      clearConnectedSince: true,
    ));
    _scheduleRetry(delay);
    _startNetworkWatcher();
  }

  // ---------------- 周期探活（治"假死"）----------------

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      probeInterval,
      (_) => unawaited(_probeEndpoint(reason: 'periodic')),
    );
  }

  /// 端到端探活。返回 true 表示链路确实可用。
  ///
  /// **为什么不能只做 TCP connect**：本地 `ServerSocket` 是我们自己 accept 的，
  /// 即使 SSH 传输层已经半死，TCP 连接照样立刻成功——它证明不了任何东西。只有
  /// 走到"发出请求并收到响应"才真正跑完 `forwardLocal`（SSH 通道打开的往返）
  /// 与远端服务应答，这才是可用的证据。
  ///
  /// 任何 HTTP 响应（含 303/401 鉴权跳转）都算活着：目的是证明往返，不是鉴权。
  /// 故用**不带 token** 的裸地址，既省一次鉴权链，也不会反复消耗 token 会话。
  Future<bool> _probeEndpoint({
    required String reason,
    bool forceRebuildOnFail = false,
  }) async {
    if (_client == null) return false;
    // 已有建链在途：那条路自己会给出结论，此时探测必然不准，直接跳过。
    if (_inflight != null || _rebuilding) return false;
    // 必须是**实际生效**的端口：临时端口模式下按配置端口探活，探的是别人家
    // 的服务，要么误报"云端无应答"，要么更糟——探通了个不相干的程序。
    final port = activeLocalPort;
    if (port == null) return false;

    final last = _lastForwardActivity;
    if (reason == 'periodic' &&
        _state.probeOk &&
        last != null &&
        DateTime.now().difference(last) < forwardFreshWindow) {
      // 最近 10 秒有**来自远端**的真实数据 = 端到端可用，SSE / 大文件传输期间
      // 不做多余探测（拥塞造成的单次探测失败不该把好好一条隧道拆掉）。
      //
      // 两条硬约束（都是真出过事的）：
      //  · 只有**下行**数据算数（见 `_pipe`）：上行 `forward.sink.add` 只是入队，
      //    半开链路上本地也能"一直在发"，把它当存活证据等于让假死永不可发现；
      //  · 捷径只能**维持**已确认的健康，不能翻案：`probeOk` 为 false 时必须真
      //    做一次探活才能回到 true，不能被陈旧流量单方面点亮（曾经就是这里无条件
      //    写 probeOk=true，把该弹的横幅也一起藏了）。
      _setState(_state.copyWith(lastProbeAt: DateTime.now()));
      return true;
    }

    final ok = await _probeLocalPort(port);
    final at = DateTime.now();
    if (ok) {
      if (_probeFailures > 0) _log('probe', '探活恢复（$reason）');
      _probeFailures = 0;
      _forwardOpenFailures = 0;
      _setState(_state.copyWith(probeOk: true, lastProbeAt: at));
      return true;
    }
    _probeFailures += 1;
    // 区分两种"探活失败"，处置方式完全不同：
    //   · SSH 传输层还活着 → 是**云端服务**没应答。重建 SSH 会话毫无意义（还会
    //     白白重载 WebView、把好端端的隧道拆掉），只标记 remoteDown 并让看门狗
    //     继续探；服务一起来立刻自动恢复。
    //   · SSH 也不回包 → 半开假死，当场强制重建。
    final transportAlive = await _pingTransport();
    if (transportAlive) {
      _setState(_state.copyWith(
        probeOk: false,
        lastProbeAt: at,
        kind: TunnelFailureKind.remoteDown,
      ));
      _log('probe',
          'SSH 传输层正常但远端服务无应答（$reason）：判定云端服务未就绪，'
          '不重建隧道，继续周期探活',
          level: TunnelEventLevel.warn);
      return false;
    }
    _setState(_state.copyWith(probeOk: false, lastProbeAt: at));
    _log('probe',
        '探活失败 第 $_probeFailures/$probeFailThreshold 次（$reason）：'
        '127.0.0.1:$port ${probeTimeout.inSeconds}s 内无应答，且 SSH 传输层无回包',
        level: TunnelEventLevel.warn);
    if (_probeFailures >= probeFailThreshold || forceRebuildOnFail) {
      await _forceRebuild('探活失败（$reason，连续 $_probeFailures 次）');
      return false;
    }
    return false;
  }

  /// 传输层级探活：复用 dartssh2 公开的 `ping()`（全局请求 keepalive@openssh.com）。
  ///
  /// 库内 `ping()` 是 `await _globalRequestReplyQueue.next`——**没有超时**，半开
  /// 连接下会永久挂起，所以超时必须由调用方给。它比 HTTP 探活更轻，用来回答
  /// "是 SSH 死了还是云端服务没起"这一个问题。
  Future<bool> _pingTransport() async {
    final c = _client;
    if (c == null) return false;
    try {
      await c.ping().timeout(const Duration(seconds: 4));
      return true;
    } catch (e) {
      debugPrint('[DSH] transport ping failed: $e');
      return false;
    }
  }

  Future<bool> _probeLocalPort(int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
      req.headers.set('Cache-Control', 'no-cache');
      // 只证明往返，不跟跳转：303/401 同样算"链路活着"，跟随后会多打一次请求。
      req.followRedirects = false;
      final res = await req.close().timeout(probeTimeout);
      await res.drain<void>();
      return true;
    } catch (e) {
      debugPrint('[DSH] probe failed: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------- 网络恢复感知（不引 connectivity_plus）----------------

  /// 断线期间才轮询网络接口；连上即停，避免常态开销。
  void _startNetworkWatcher() {
    if (!_wantConnected) return;
    _networkTimer ??=
        Timer.periodic(networkPollInterval, (_) => _checkNetworkChange());
  }

  void _stopNetworkWatcher() {
    _networkTimer?.cancel();
    _networkTimer = null;
    _networkSignature = null;
  }

  Future<void> _checkNetworkChange() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final sig = (ifaces
          .expand((i) => i.addresses.map((a) => '${i.name}/${a.address}'))
          .toList()
        ..sort())
          .join(',');
      final prev = _networkSignature;
      _networkSignature = sig;
      if (prev != null && prev != sig && !_state.healthy) {
        // 冷却：接口抖一下不等于"网络恢复了"。旧实现在这里 `_resetAttempt()`
        // （`_attempt = 0` + 取消定时器），于是每次签名变化都把指数退避清零，
        // 每 15 秒一轮完整握手，60 秒封顶永远不生效。
        final now = DateTime.now();
        final since = _lastNetworkRetryAt;
        if (since != null && now.difference(since) < networkRetryCooldown) {
          _log('network', '接口再次变化，冷却中忽略（${now.difference(since).inSeconds}s）');
          return;
        }
        _lastNetworkRetryAt = now;
        _log('network', '检测到网络接口变化 → 提前重试一次（保留退避计数）');
        // 降级而非归零：真恢复了可以马上再试，仍然失败则继续按原节奏变慢。
        _attempt = _attempt > 2 ? _attempt - 2 : 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        await _runAttempt();
      }
    } catch (e) {
      debugPrint('[DSH] network watcher failed: $e');
    }
  }

  // ---------------- 资源清理 ----------------

  /// 释放隧道相关的全部本地资源（不含 SSH 会话本身的关闭策略）。
  Future<void> _teardown() async {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    // **同步**把所有权摘走，再做任何 await。顺序很关键：`await server.close()`
    // 会让出事件循环，若此时旧 client 报错，`_onTransportClosed(oldClient)` 的
    // `if (_client != client) return` 守卫因为 `_client` 还没置空而**通过**，
    // 于是给一条即将成功的新隧道排了个退避定时器 → 十几秒后新隧道被自己拆掉。
    final server = _server;
    final client = _client;
    _server = null;
    _client = null;
    _localPortFallback = null; // 下次连接重新按配置端口试，别把临时端口带过去
    _activeProfileIndex = null;
    _activeConfig = null;
    // 上一会话的流量时间不能带进新会话：否则新隧道的第一次周期探活会吃到旧的
    // "10 秒内有流量"窗口而跳过探测。
    _lastForwardActivity = null;
    _destroyForwardConns();
    // 在途的只读 SFTP 会话（预览/另存为/下载）必须在这里主动 abort：库侧 waiter
    // 既没有超时也不监听通道关闭，不主动收尾它们就**永久卡住**——监督器把新隧道
    // 建好也救不回旧的 await（界面表现为"一直转圈 / 一直 0%"，且 `_running`
    // 恒真把"重试"也挡在守卫外）。必须在任何 await 之前做，别给事件循环让路。
    abortLiveSftpSessions(reason: 'teardown');
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
    if (client != null) {
      try {
        client.close();
      } catch (_) {}
    }
  }

  void _destroyForwardConns({String? reason}) {
    final all = <Socket>{..._forwardConns, ..._pendingForwards};
    _forwardConns.clear();
    _pendingForwards.clear();
    if (all.isEmpty) return;
    var n = 0;
    for (final s in all) {
      try {
        s.destroy();
        n++;
      } catch (_) {}
    }
    _log('forward', '销毁 $n 条遗留转发连接${reason == null ? '' : '（$reason）'}');
  }

  /// 目标主机/凭据是否等价：决定能否复用当前会话（模式与远端端口变化不影响，
  /// 那类切换走 [updateActiveConfig] 就地改转发目标）。
  static bool _isSameTarget(SSHConfig a, SSHConfig b) =>
      a.host == b.host &&
      a.sshPort == b.sshPort &&
      a.username == b.username &&
      a.authType == b.authType &&
      a.password == b.password &&
      a.privateKeyPem == b.privateKeyPem &&
      a.keyPassphrase == b.keyPassphrase &&
      a.localPort == b.localPort;

  void _log(String tag, String message,
      {TunnelEventLevel level = TunnelEventLevel.info}) {
    TunnelDiagnostics.instance.record(level, tag, message);
    debugPrint('[DSH][${level.name}] $tag: $message');
  }

  /// 仅验证 SSH 认证是否成功（设置页"测试连接"专用）。
  ///
  /// 与 [connect] 的区别：不建立本地转发、不改变隧道状态、不联动前台服务，
  /// 认证完成后立即关闭会话释放资源，避免测试时通知栏/前台服务启停闪烁，
  /// 也避免污染当前活动隧道。
  ///
  /// 认证成功正常返回；连接/认证失败抛出异常（由调用方呈现错误）。
  Future<void> testConnection(SSHConfig config) async {
    final socket = await SSHSocket.connect(config.host, config.sshPort,
        timeout: const Duration(seconds: 15));
    SSHClient? client;
    try {
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) =>
            _verifyHostKey(config, hostkeyType, fingerprint),
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] test connection auth timed out');
        throw const SocketException('SSH 认证超时');
      });
      debugPrint('[DSH] test connection ok '
          '(${config.host}:${config.sshPort})');
    } finally {
      client?.close();
      // fromPem 解析失败等 client 未建立时，直接关闭底层 socket 防泄漏
      if (client == null) {
        // 忽略异步关闭结果（finally 中无法 await）
        socket.close();
      }
    }
  }

  /// 处理一条本地 TCP 连接：打开远程直连隧道并双向透传。
  void _handleLocalConnection(Socket localSocket) {
    _handleForward(localSocket);
  }

  /// 就地更新当前隧道的转发目标配置（不重建 SSH 会话）。
  ///
  /// 转发通道按连接逐条拨号 [_activeConfig.activeRemotePort]（见 _handleForward），
  /// 因此同实例内切换服务模式（DSH 3080 ⇄ Zcode 8787 ⇄ WorkBuddy 8790）只需更新内存配置。
  /// 但已建立的连接仍固定转发到旧端口，必须全部销毁，迫使 WebView 用新
  /// 端口重建连接，否则复用的 keep-alive 连接会把请求送到旧服务上。
  /// 仅当 [profileIndex] 与当前激活实例一致时生效，防止迟到的旧实例调用串线。
  void updateActiveConfig(SSHConfig config, {int? profileIndex}) {
    if (profileIndex != null &&
        _activeProfileIndex != null &&
        profileIndex != _activeProfileIndex) {
      return; // 不是当前实例的更新：忽略
    }
    final previous = _activeConfig;
    final sameSshTarget = previous != null && _isSameTarget(previous, config);
    _activeConfig = config;
    // 关键：监督器重试读的是 `_desiredConfig`。以前这里只改 `_activeConfig`，
    // 于是"断开期间在设置页改了地址/端口/模式"→ 退避到点仍按**旧**目标重连，
    // 用户观感就是"改了设置也没用，还是连不上"。
    if (_desiredConfig == null ||
        profileIndex == null ||
        profileIndex == _desiredProfileIndex) {
      _desiredConfig = config;
      if (profileIndex != null) _desiredProfileIndex = profileIndex;
    }
    if (_client == null) return;
    if (!sameSshTarget) {
      // 换的是 SSH 目标本身（地址/端口/用户名/凭据/本地端口）：整条会话都得重建。
      unawaited(_forceRebuild('配置变更'));
      return;
    }
    // 只是转发目标端口变了（DSH↔Zcode↔WorkBuddy）：会话保留，通道重建。
    // 含"还在等 forwardLocal"的连接：它们同样会在建好后固定拨向旧端口。
    _destroyForwardConns(reason: '模式切换');
  }

  Future<void> _handleForward(Socket local) async {
    final client = _client;
    if (client == null) {
      local.destroy();
      return;
    }
    _forwardConns.add(local);
    unawaited(local.done
        .whenComplete(() => _forwardConns.remove(local))
        .catchError((Object _) => _forwardConns.remove(local)));
    // 关键修复：dartssh2 的 `forwardLocal()` 等的是一个**没有超时**的 completer
    // （ssh_client.dart `_waitChannelOpenReply`），传输层半开时既不返回也不报错。
    // 旧实现直接 await 它 → 本地 socket 既不 pipe 也不 destroy → WebView 这条连接
    // 永久吊住（用户观感：隧道"已连接"，页面一直转圈，最后报加载失败）。
    _pendingForwards.add(local);
    SSHForwardChannel? forward;
    // 远端服务监听 127.0.0.1:<activeRemotePort>（DSH Web UI=3080 / zcode-phone-server=8787 / WorkBuddy=8790）
    //
    // 必须**自己持有源 Future**：`Future.timeout` 不会取消被等待的 future，超时
    // 之后服务端若晚一拍回 OPEN_CONFIRM，dartssh2 仍会把这条 channel 登记进
    // `SSHClient._channels` 并在远端建立一条到 127.0.0.1:3080 的连接（见
    // ssh_client.dart `_acceptChannel`）。旧实现只 destroy 了本地 socket → 每次
    // 超时永久泄漏一条 SSH channel + 一条远端 TCP（抖动一晚上就能把 sshd 的
    // channel 配额吃光，且 channel id 也不归还）。
    final openFuture = client
        .forwardLocal('127.0.0.1', _activeConfig?.activeRemotePort ?? 3080);
    try {
      forward = await openFuture.timeout(forwardOpenTimeout);
    } on TimeoutException {
      _pendingForwards.remove(local);
      local.destroy();
      unawaited(openFuture.then<void>((channel) {
        _log('forward', '回收超时后迟到的转发通道', level: TunnelEventLevel.warn);
        try {
          channel.destroy();
        } catch (_) {}
      }, onError: (Object _) {}));
      _forwardOpenFailures += 1;
      _log('forward',
          'forwardLocal 超时（第 $_forwardOpenFailures/$forwardOpenFailThreshold 次，'
          '${forwardOpenTimeout.inSeconds}s）：传输层可能已半开',
          level: TunnelEventLevel.warn);
      if (_forwardOpenFailures >= forwardOpenFailThreshold) {
        await _forceRebuild('连续 $_forwardOpenFailures 次转发建链超时');
      }
      return;
    } catch (e) {
      _pendingForwards.remove(local);
      local.destroy();
      // 迟到成功的兜底：若源 future 稍后才完成，同样要把它销毁，不能留给会话。
      unawaited(openFuture.then<void>((channel) {
        try {
          channel.destroy();
        } catch (_) {}
      }, onError: (Object _) {}));
      debugPrint('[DSH] forwardLocal failed: $e');
      return;
    }
    _pendingForwards.remove(local);
    // 建链期间隧道可能已被监督器重建/切换：这条 channel 属于旧会话，直接丢弃，
    // 否则会把请求转发到一个已死的 SSH 会话上。
    if (!identical(_client, client)) {
      try {
        forward.destroy();
      } catch (_) {}
      local.destroy();
      return;
    }
    _forwardOpenFailures = 0;
    _pipe(local, forward);
  }

  /// 双向透传（不自我节流）。
  ///
  /// 早期版本曾加入"有界背压"（在途超过阈值即暂停源、周期恢复），但
  /// dartssh2 的 sink 与 Dart Socket 都不提供逐块消费回调，导致"在途"
  /// 计数只增不减：一旦超过阈值就永久陷入每 120ms 只转发一块的节流，
  /// 吞吐骤降至 ~267KB/s，大体积加载直接超时。
  ///
  /// 这里改为**不做节流**，让数据以隧道能达到的最快速率流动：
  /// - 下载方向（远端→本地）由 loopback Socket 自然缓冲，WebView 持续读取即自动排空；
  /// - 上传方向（本地→远端）请求体通常很小；
  /// - 真正的吞吐上限来自 SSH 通道窗口与 dartssh2 的解密速率，不应由应用层节流。
  ///
  /// 顺带把每条有数据进出的时间记进 [_lastForwardActivity]：看门狗据此判断
  /// "最近有真实流量 = 端到端活着"，SSE / 大文件传输期间不再做多余探测，
  /// 也避免因一次拥塞误判把好好的隧道拆掉重建。
  void _pipe(Socket local, SSHForwardChannel forward) {
    final localSub = local.listen(
      (data) {
        // 故意**不**在这里记"转发活跃"：`forward.sink.add` 只是把数据塞进
        // dartssh2 的发送队列，传输层半开时它既不报错也不真的出去。用它当端到端
        // 存活的证据，会让假死永远探测不到（见 `_probeEndpoint` 的新鲜窗捷径）。
        try {
          forward.sink.add(data);
        } catch (_) {
          forward.destroy();
        }
      },
      onDone: () => forward.destroy(),
      onError: (_) => forward.destroy(),
      cancelOnError: true,
    );

    final forwardSub = forward.stream.listen(
      (data) {
        _noteForwardActivity();
        try {
          local.add(data);
        } catch (_) {
          local.destroy();
        }
      },
      onDone: () => local.destroy(),
      onError: (_) => local.destroy(),
      cancelOnError: true,
    );

    // 任一端关闭则释放另一端
    forward.done.whenComplete(() {
      localSub.cancel().catchError((_) {});
      local.destroy();
    });
    local.done.whenComplete(() {
      forwardSub.cancel().catchError((_) {});
      forward.destroy();
    });
  }

  /// 记录转发流量活跃时刻（1 秒节流，避免每个包都取时钟）。
  void _noteForwardActivity() {
    final now = DateTime.now();
    final last = _lastForwardActivity;
    if (last == null || now.difference(last) > const Duration(seconds: 1)) {
      _lastForwardActivity = now;
    }
  }

  /// 通过现有 SSH 会话读取云端主机上的文件内容（用于成果预览）。
  ///
  /// [remotePath] 为云端文件路径（如 `E:\Work\CaTv\xxx.md` 或 `/home/user/xxx.md`）。
  /// 采用 **SFTP** 读取：绕开 shell 命令对中文路径的编码问题（Windows cmd 用
  /// GBK 而 exec 命令按 UTF-8 发送，中文路径会被误解码）。
  ///
  /// 四条硬性约束（都是真机故障倒推出来的）：
  ///  1. 每一步带超时（[sftpOpenTimeout]/[sftpStatTimeout]/[sftpReadTimeout]）：
  ///     库侧 `_waitReply` 没有超时，链路半开时是"永久转圈"而不是"报错"；
  ///  2. 会话登记进 [_liveSftpClients]，隧道拆毁时统一 abort，唤醒卡死的 await
  ///     （否则监督器把新隧道建好，旧的 `await` 也永远不会醒）；
  ///  3. 收尾一律 best-effort：库里 `SftpFile.close()` 要 await 服务端 CLOSE 并可能
  ///     抛异常，放在 `finally` 里会**顶掉 try 已经拿到的返回值**——字节都在手上了
  ///     还被报成"读取失败"，这就是"点开偶尔失败、再点一下就好"的成因；
  ///  4. 失败原因分类透出（[RemoteFailureKind]），不再一句话糊住六种不同病因。
  Future<String> readRemoteFile(String remotePath) async {
    final opened = await openRemoteFileDetailed(remotePath);
    final file = opened.file;
    if (file == null) {
      throw RemoteReadException(opened.reason ?? '云端文件打不开',
          kind: opened.kind);
    }
    final Uint8List bytes;
    try {
      int? size = opened.size;
      size ??= await _statAttrs(file).then((a) => a?.size);
      if (size != null && size > previewMaxBytes) {
        debugPrint('[DSH] readRemoteFile skipped '
            '($size bytes > ${previewMaxBytes ~/ (1024 * 1024)}MB) '
            'for "$remotePath"');
        throw RemoteReadException(
          '文件过大（${(size / (1024 * 1024)).toStringAsFixed(1)}MB，'
          '预览上限 ${previewMaxBytes ~/ (1024 * 1024)}MB），'
          '请使用"另存为"下载查看',
          kind: RemoteFailureKind.tooLarge,
        );
      }
      bytes = await _readAllBytes(file);
    } on RemoteReadException {
      rethrow; // 超大/超时等原因直接上抛，不再重试
    } catch (e) {
      throw RemoteReadException('读取云端文件失败：${_describeSftpError(e)}',
          kind: _kindOf(e));
    } finally {
      // 解码放在关闭之后做：关闭本身可能耗时，别让它占着句柄。
      await closeRemoteFile(file: file, sftp: opened.sftp);
    }
    return _decodeBytes(bytes);
  }

  /// 解析远程路径并打开 SFTP 文件句柄（用于资源下载/断点续传）。
  ///
  /// 兼容旧调用方：只要句柄或 null。需要失败原因请用
  /// [openRemoteFileDetailed]（下载页正是靠原因区分"隧道未连"与"文件不存在"）。
  Future<SftpFile?> openRemoteFile(String remotePath) async {
    final result = await openRemoteFileDetailed(remotePath);
    return result.file;
  }

  /// 打开远端文件并给出失败原因；**目录在这里就挡掉**。
  ///
  /// 目录必须专门处理：部分 sftp-server 允许 `open` 目录成功、到 READ 才失败，
  /// 错误被归成"路径不存在"；而 [resolveRemotePath] 更糟——它把"open 成功"当成
  /// 解析成功，于是目录被当文件送去下载，最后存出 0 字节文件却显示"完成"。
  Future<RemoteOpenResult> openRemoteFileDetailed(String remotePath) async {
    final client = _client;
    if (client == null) {
      return const RemoteOpenResult(
        null,
        reason: 'SSH 隧道未连接',
        kind: RemoteFailureKind.notConnected,
      );
    }
    String? lastReason;
    var lastKind = RemoteFailureKind.other;
    for (final path in _sftpPathCandidates(remotePath)) {
      SftpClient? sftp;
      SftpFile? file;
      Future<SftpFile>? openFuture;
      try {
        sftp = await client
            .sftp()
            .timeout(sftpOpenTimeout,
                onTimeout: () => throw TimeoutException('sftp session'));
        _liveSftpClients.add(sftp);
        openFuture = sftp.open(path);
        file = await openFuture.timeout(sftpOpenTimeout,
            onTimeout: () => throw TimeoutException('sftp open'));
        final attrs = await _statAttrs(file);
        if (attrs?.type == SftpFileType.directory) {
          await closeRemoteFile(file: file, sftp: sftp);
          file = null;
          lastKind = RemoteFailureKind.isDirectory;
          lastReason = '这是一个目录，不是文件';
          debugPrint('[DSH] openRemoteFile: "$path" is a directory');
          continue;
        }
        return RemoteOpenResult(file, sftp: sftp, size: attrs?.size);
      } on TimeoutException {
        lastKind = RemoteFailureKind.timeout;
        lastReason = '云端文件响应超时（链路可能已半开）';
        debugPrint('[DSH] openRemoteFile timeout for "$path"');
        // 超时的会话必须显式 close：`SftpClient.close()` 会把在途
        // `_replyWaiters` 全部用 SftpAbortError 结掉——既不泄漏通道，也让那个
        // 卡住的 await 尽快结束。迟到的 open 若成功，就地回收句柄。
        openFuture?.then((lateHandle) {
          unawaited(closeRemoteFile(file: lateHandle, sftp: sftp));
        }, onError: (_) {});
        await _closeSftpSession(sftp);
      } catch (e) {
        lastKind = _kindOf(e);
        lastReason = _describeSftpError(e);
        debugPrint('[DSH] openRemoteFile failed for "$path": $e');
        await closeRemoteFile(file: file, sftp: sftp);
      }
    }
    return RemoteOpenResult(null,
        reason: lastReason ?? '云端文件打不开', kind: lastKind);
  }

  /// 用候选目录 + 文件名拼接云端路径，返回第一个真实存在的完整路径；
  /// 全部失败返回 null。
  ///
  /// 用于 DSH 产物 chips 被隐藏（只有文件名、无完整路径）的场景。
  ///
  /// 旧实现对每个候选目录做 `2 种分隔符 × 3 种路径形态` 的逐个 `open`——
  /// 5 个目录 = 30 条 SSH 会话串行开合，而远端 sshd 默认 `MaxSessions=10`，
  /// 于是一次点击就能把通道配额打满，表现为"点什么都失败"。现在：
  ///  1. 目录候选先清洗（页面 `title`/tooltip 常被当成"目录"收进来）；
  ///  2. 首选**一次 `listdir` 批量匹配**（1 条会话顶掉 6 次 open），且目录名
  ///     大小写不敏感匹配（Windows 产物常与 chip 文案大小写不一致）；
  ///  3. 目录列表不可读时才退回逐个试开，并受 [resolveMaxProbes] 与
  ///     [resolveBudget] 双重限制。
  Future<String?> resolveRemotePath(String filename, List<String> dirs) async {
    final client = _client;
    if (client == null || filename.isEmpty) return null;
    final candidates = _cleanDirs(dirs);
    if (candidates.isEmpty) return null;
    final deadline = DateTime.now().add(resolveBudget);
    final lower = filename.toLowerCase();

    // ① 批量列目录：一个目录一条会话，命中即返回。
    for (final dir in candidates) {
      if (!DateTime.now().isBefore(deadline)) break;
      for (final sep in const [r'\', '/']) {
        final joined = (dir.endsWith(r'\') || dir.endsWith('/'))
            ? '$dir$filename'
            : '$dir$sep$filename';
        final listDir = _dirPortion(joined);
        if (listDir == null) continue;
        SftpClient? sftp;
        try {
          sftp = await client
              .sftp()
              .timeout(sftpOpenTimeout,
                  onTimeout: () => throw TimeoutException('sftp session'));
          _liveSftpClients.add(sftp);
          final names = await sftp
              .listdir(listDir)
              .timeout(sftpStatTimeout,
                  onTimeout: () => throw TimeoutException('listdir'));
          for (final n in names) {
            if (n.filename.toLowerCase() == lower) {
              final hit = (dir.endsWith(r'\') || dir.endsWith('/'))
                  ? '$dir${n.filename}'
                  : '$dir$sep${n.filename}';
              debugPrint('[DSH] resolved "$filename" -> "$hit" (listdir)');
              return hit;
            }
          }
        } catch (e) {
          debugPrint('[DSH] resolve listdir "$listDir" failed: $e');
        } finally {
          await _closeSftpSession(sftp);
        }
        // 同一个目录只按第一种分隔符列一次即可（listdir 结果与分隔符无关）。
        break;
      }
    }

    // ② 兜底：目录列表不可读（权限受限 / 非目录）时退回逐个试开，严格限量。
    var probes = 0;
    for (final dir in candidates) {
      for (final sep in const [r'\', '/']) {
        final cand = (dir.endsWith(r'\') || dir.endsWith('/'))
            ? '$dir$filename'
            : '$dir$sep$filename';
        for (final path in _sftpPathCandidates(cand)) {
          if (probes++ >= resolveMaxProbes) return null;
          if (!DateTime.now().isBefore(deadline)) {
            debugPrint('[DSH] resolveRemotePath budget exhausted '
                '($probes probes)');
            return null;
          }
          SftpClient? sftp;
          SftpFile? file;
          try {
            sftp = await client
                .sftp()
                .timeout(sftpOpenTimeout,
                    onTimeout: () => throw TimeoutException('sftp session'));
            _liveSftpClients.add(sftp);
            file = await sftp
                .open(path)
                .timeout(sftpOpenTimeout,
                    onTimeout: () => throw TimeoutException('sftp open'));
            final attrs = await _statAttrs(file);
            if (attrs?.type == SftpFileType.directory) continue;
            debugPrint('[DSH] resolved "$filename" -> "$path" (open)');
            return path;
          } catch (e) {
            debugPrint('[DSH] resolve probe "$path" failed: $e');
          } finally {
            await closeRemoteFile(file: file, sftp: sftp);
          }
        }
      }
    }
    return null;
  }

  /// 清洗页面传来的"候选目录"。
  ///
  /// `collectProducedDirs()` 把任何能取到 `title`/`aria-label` 的元素都当目录，
  /// 于是 `title="在编辑器打开"`、`title="https://x/y"` 这类 tooltip 也进了候选，
  /// 每一个都换来数次无谓的 SFTP 往返。这里过滤掉明显不是目录的串。
  static List<String> _cleanDirs(List<String> dirs) {
    final out = <String>[];
    for (final d in dirs) {
      final t = d.trim();
      if (t.isEmpty || t.length > 255) continue;
      if (t.contains('://')) continue; // 链接被当目录
      if (!t.contains(r'\') && !t.contains('/')) continue; // 连路径都不是
      if (out.contains(t)) continue;
      out.add(t);
      if (out.length >= 8) break; // 再多了就是噪声
    }
    return out;
  }

  /// 取路径的目录部分（用于 listdir）；无目录部分返回 null。
  static String? _dirPortion(String path) {
    final norm = path.replaceAll(r'\', '/');
    final i = norm.lastIndexOf('/');
    if (i <= 0) return null;
    return norm.substring(0, i);
  }

  /// 生成待尝试的 SFTP 路径形态，**去重**（原来 POSIX 绝对路径的第 2、3 个
  /// 候选完全相同，不存在的路径要被白开三次）。
  ///
  /// 覆盖三种真实差异：
  ///  - `~` 开头：SFTP 服务端按字面量解析，`~/x.md` 必然 noSuchFile。sftp-server
  ///    的工作目录就是用户 home，所以去掉 `~/` 即等价于家目录相对路径；
  ///  - Windows 盘符：OpenSSH for Windows 常见要求 `/E:/a/b` 形态；
  ///  - `\` 与 `/` 混用。
  List<String> _sftpPathCandidates(String p) {
    final normalized = p.replaceAll(r'\', '/');
    final out = <String>{};
    void add(String v) {
      if (v.isNotEmpty) out.add(v);
    }

    add(p);
    add(normalized);
    add(normalized.startsWith('/') ? normalized : '/$normalized');
    // `~/x` → `x`（相对 sftp-server 的 cwd = 用户 home）
    final home = normalized.replaceFirst(RegExp(r'^\~/'), '');
    if (home != normalized) {
      add(home);
      add('/$home');
    }
    // `E:/a/b` → `/E:/a/b`（Windows OpenSSH 的常见形态）
    final drive = RegExp(r'^([A-Za-z]:/.*)').firstMatch(normalized);
    if (drive != null) add('/${drive.group(1)}');
    return out.toList(growable: false);
  }

  /// `fstat`：拿不到就返回 null，但**绝不**让它在半开链路上吊死整个读取。
  Future<SftpFileAttrs?> _statAttrs(SftpFile file) async {
    try {
      return await file.stat().timeout(sftpStatTimeout);
    } on TimeoutException {
      debugPrint('[DSH] sftp stat timeout');
      return null;
    } catch (e) {
      debugPrint('[DSH] sftp stat failed: $e');
      return null;
    }
  }

  /// 读取全部字节（带超时）。
  Future<Uint8List> _readAllBytes(SftpFile file) async {
    try {
      return await file.readBytes().timeout(sftpReadTimeout,
          onTimeout: () => throw TimeoutException('sftp readBytes'));
    } on TimeoutException {
      throw const RemoteReadException(
        '读取云端文件超时（链路可能已半开），请稍后重试',
        kind: RemoteFailureKind.timeout,
      );
    }
  }

  /// 关闭远端句柄/会话并从 [_liveSftpClients] 摘除；异常只记日志。
  ///
  /// 为什么两个都要关、且都要吞异常：库里 `SftpFile.close()` 先 `await`
  /// 服务端 CLOSE（可能抛）再 `_client.close()`；抛异常时同块下一句不会执行
  /// （会话泄漏），且 `_isClosed` 已置 true 让重试直接 return。而在 `finally`
  /// 里抛异常还会**顶掉 try 块已经成功的返回值**。
  Future<void> closeRemoteFile({SftpFile? file, SftpClient? sftp}) async {
    if (file != null) {
      try {
        await file.close().timeout(sftpStatTimeout);
      } catch (e) {
        debugPrint('[DSH] sftp file close ignored: $e');
      }
    }
    await _closeSftpSession(sftp);
  }

  Future<void> _closeSftpSession(SftpClient? sftp) async {
    if (sftp == null) return;
    _liveSftpClients.remove(sftp);
    try {
      // void 方法：同步把 `_replyWaiters` 逐个 completeError(SftpAbortError)，
      // 因此它同时是"唤醒卡死 await"和"归还 SSH 通道"两个动作的唯一入口。
      sftp.close();
    } catch (e) {
      debugPrint('[DSH] sftp session close ignored: $e');
    }
  }

  /// 隧道拆毁时调用：强制结束所有存活的只读 SFTP 会话。
  ///
  /// 库侧 `SftpClient` 构造时没有注册通道的 onDone/onError，`_waitReply` 也没有
  /// 超时；transport 掉线后在途的 `open`/`stat`/`readBytes` **永不返回**，界面就
  /// 永久停在转圈/0%，且 `_running` 恒真会把"重试"也挡掉。`SftpClient.close()`
  /// 会把 `_replyWaiters` 逐个 `completeError(SftpAbortError)`，是唯一能唤醒它们
  /// 的入口。
  void abortLiveSftpSessions({String reason = 'tunnel teardown'}) {
    if (_liveSftpClients.isEmpty) return;
    debugPrint('[DSH] abort ${_liveSftpClients.length} live sftp session(s): $reason');
    for (final s in _liveSftpClients.toList(growable: false)) {
      try {
        s.close();
      } catch (e) {
        debugPrint('[DSH] abort sftp session failed: $e');
      }
    }
    _liveSftpClients.clear();
  }

  static RemoteFailureKind _kindOf(Object e) {
    if (e is TimeoutException) return RemoteFailureKind.timeout;
    if (e is RemoteReadException) return e.kind;
    if (e is SftpStatusError) {
      switch (e.code) {
        case SftpStatusCode.noSuchFile:
          return RemoteFailureKind.notFound;
        case SftpStatusCode.permissionDenied:
          return RemoteFailureKind.permission;
        case SftpStatusCode.connectionLost:
        case SftpStatusCode.noConnection:
          return RemoteFailureKind.notConnected;
      }
    }
    final text = '$e';
    if (text.contains('MaxSessions') ||
        text.contains('Channel open failure') ||
        text.contains('channel open failed')) {
      return RemoteFailureKind.channelExhausted;
    }
    return RemoteFailureKind.other;
  }

  /// 把 SFTP 异常翻译成人话。
  static String _describeSftpError(Object e) {
    if (e is SftpStatusError) {
      switch (e.code) {
        case SftpStatusCode.noSuchFile:
          return '云端不存在该文件';
        case SftpStatusCode.permissionDenied:
          return '没有读取权限（或路径被服务端限制）';
        case SftpStatusCode.failure:
          return '服务器拒绝访问（可能是目录、文件被占用或路径形态不支持）';
        case SftpStatusCode.connectionLost:
          return 'SSH 连接已断开';
        case SftpStatusCode.noConnection:
          return 'SSH 未连接';
        case SftpStatusCode.opUnsupported:
          return '服务器不支持该 SFTP 操作';
        case SftpStatusCode.badMessage:
          return 'SFTP 协议不一致（服务端实现不兼容）';
      }
    }
    if (e is TimeoutException) return '云端文件响应超时（链路可能已半开）';
    if (e is SftpAbortError) return 'SSH 会话已关闭';
    return '$e';
  }

  /// 读取云端文件原始字节（用于"另存为"时保留原始编码，如 GBK）。
  ///
  /// 失败**抛** [RemoteReadException]，不再静默返回 null：旧实现返回 null 后
  /// 上层回落 `utf8.encode(内容)`，而那时内容本来就是空的（正因为读失败），
  /// 于是"写一个 0 字节文件并 toast 保存成功"，用户拿到坏文件还毫不知情。
  Future<Uint8List> readRemoteFileBytes(String remotePath) async {
    final opened = await openRemoteFileDetailed(remotePath);
    final file = opened.file;
    if (file == null) {
      throw RemoteReadException(opened.reason ?? '云端文件打不开',
          kind: opened.kind);
    }
    try {
      final attrs = await _statAttrs(file);
      if (attrs?.type == SftpFileType.directory) {
        throw const RemoteReadException('这是一个目录，不是文件',
            kind: RemoteFailureKind.isDirectory);
      }
      final size = attrs?.size;
      if (size != null && size > previewMaxBytes) {
        throw RemoteReadException(
          '文件过大（${(size / (1024 * 1024)).toStringAsFixed(1)}MB，'
          '上限 ${previewMaxBytes ~/ (1024 * 1024)}MB）',
          kind: RemoteFailureKind.tooLarge,
        );
      }
      return await _readAllBytes(file);
    } on RemoteReadException {
      rethrow;
    } catch (e) {
      throw RemoteReadException('读取云端文件失败：${_describeSftpError(e)}',
          kind: _kindOf(e));
    } finally {
      await closeRemoteFile(file: file, sftp: opened.sftp);
    }
  }

  // ================= 文件上传（端侧 → 服务器临时目录）================

  /// 服务器临时上传目录名（建在服务器 home 目录下）。
  static const String uploadDirName = 'dsh_phone_uploads';

  /// 探测服务器 home 目录（用于拼接上传目录）。
  ///
  /// Linux 走 `cd ~ && pwd`；Windows 默认 cmd 走 `echo %USERPROFILE%`，
  /// 若输出仍含 `%USERPROFILE%`（说明远程 shell 是 bash），回退 `cd` 打印
  /// 当前目录。探测失败返回 null。
  Future<String?> _detectHomeDir(SSHClient client) async {
    final type = await _detectHostType(client);
    if (type == HostType.windows) {
      final out = await _execOn(client, 'echo %USERPROFILE%');
      final t = (out ?? '').trim();
      if (t.isNotEmpty && !t.contains('%USERPROFILE%')) {
        return t.replaceAll(r'\', '/');
      }
      // bash 环境（%USERPROFILE% 未展开）或为空：回退 cd 打印当前目录
      final cd = await _execOn(client, 'cd && cd');
      final c = (cd ?? '').trim();
      return c.isNotEmpty ? c.replaceAll(r'\', '/') : null;
    }
    final out = await _execOn(client, 'cd ~ && pwd');
    final t = (out ?? '').trim();
    return t.isNotEmpty ? t : null;
  }

  /// 确保服务器上传临时目录存在，返回可用目录路径（正斜杠，不带结尾分隔符）；
  /// 失败返回 null。
  ///
  /// 目录策略：优先 `<home>/dsh_phone_uploads/`；home 探测失败时回退
  /// `/tmp/dsh_phone_uploads/`（Linux）或 `C:/Users/<用户名>/dsh_phone_uploads/`
  /// （Windows）。
  Future<String?> ensureUploadDir() async {
    final client = _client;
    if (client == null) return null;
    final candidates = <String>[];
    final home = await _detectHomeDir(client);
    if (home != null && home.isNotEmpty) {
      candidates.add('$home/$uploadDirName');
    }
    final type = await _detectHostType(client);
    if (type == HostType.windows) {
      final u = _activeConfig?.username;
      if (u != null && u.isNotEmpty) {
        candidates.add('C:/Users/$u/$uploadDirName');
      }
    } else {
      candidates.add('/tmp/$uploadDirName');
    }
    for (final dir in candidates) {
      SftpClient? sftp;
      try {
        sftp = await client
            .sftp()
            .timeout(sftpOpenTimeout,
                onTimeout: () => throw TimeoutException('sftp session'));
        _liveSftpClients.add(sftp);
        try {
          await sftp.mkdir(dir).timeout(sftpStatTimeout);
        } catch (e) {
          // 目录可能已存在（SFTP mkdir 对已存在目录返回 failure）：
          // stat 确认可访问，失败则换下一个候选。
          await sftp.stat(dir).timeout(sftpStatTimeout);
        }
        debugPrint('[DSH] upload dir ready: $dir');
        return dir;
      } catch (e) {
        debugPrint('[DSH] ensureUploadDir failed for "$dir": $e');
      } finally {
        // 成功分支**必须**关会话。旧实现只在 catch 里关（`return dir` 前既没有
        // finally 也没有 close），于是每成功上传一次就永久泄漏一条 SSH 通道；
        // 远端 sshd 默认 `MaxSessions=10`，约十次上传之后 `client.sftp()` 与
        // `forwardLocal()` 一起被服务端拒绝——所有预览报"路径不存在或无权限"、
        // 所有下载报"隧道可能未连接"，也就是"用着用着全废"的根因。
        await _closeSftpSession(sftp);
      }
    }
    return null;
  }

  /// 清理文件名中的不安全字符（路径分隔符 / 控制字符），避免注入路径混淆。
  static String _sanitizeFilename(String name) {
    final base = name.replaceAll(RegExp(r'[\\/:\*\?"<>\|]'), '_');
    return base.isEmpty ? 'upload.dat' : base;
  }

  /// 把本地文件字节上传到服务器临时目录，返回完整远程路径（正斜杠）；
  /// 隧道未连接 / 上传失败返回 null。
  ///
  /// 文件名自动加时间戳防冲突并保留扩展名；SFTP 以 `write|create|truncate`
  /// 打开后分块写入（fork 的 dartssh2 按 16KB 分块）。
  Future<String?> uploadRemoteFile(
    Uint8List bytes,
    String filename, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final client = _client;
    if (client == null || bytes.isEmpty) return null;
    final dir = await ensureUploadDir();
    if (dir == null) return null;

    final safe = _sanitizeFilename(filename);
    final dot = safe.lastIndexOf('.');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final remoteName = dot > 0
        ? '${safe.substring(0, dot)}.$stamp.${safe.substring(dot + 1)}'
        : '$safe.$stamp';
    final remotePath = '$dir/$remoteName';

    try {
      final sftp = await client
          .sftp()
          .timeout(sftpOpenTimeout,
              onTimeout: () => throw TimeoutException('sftp session'));
      _liveSftpClients.add(sftp);
      try {
        final file = await sftp.open(
          remotePath,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate,
        );
        try {
          // 流式分块写入（16KB 分块 + ack 流控），带真实进度回调；
          // 大文件不一次性入 SFTP 包，避免慢网络下大包悬挂。
          const chunk = 16 * 1024;
          final chunks = <Uint8List>[];
          for (var i = 0; i < bytes.length; i += chunk) {
            chunks.add(Uint8List.sublistView(
                bytes, i, i + chunk > bytes.length ? bytes.length : i + chunk));
          }
          final writer = file.write(
            Stream.fromIterable(chunks),
            onProgress: (total) =>
                onProgress?.call(total, bytes.length),
          );
          await writer.done.timeout(
            const Duration(minutes: 2),
            onTimeout: () => throw TimeoutException('upload timeout'),
          );
          onProgress?.call(bytes.length, bytes.length);
          debugPrint('[DSH] uploaded ${bytes.length} bytes -> $remotePath');
        } finally {
          // 关句柄顺带关会话；异常只记日志（这里抛出会把已成功的上传报成失败）。
          await closeRemoteFile(file: file, sftp: sftp);
        }
      } finally {
        await _closeSftpSession(sftp); // 打开失败分支：释放会话通道，避免泄漏
      }
      return remotePath;
    } catch (e) {
      debugPrint('[DSH] uploadRemoteFile failed: $e');
      return null;
    }
  }

  /// 主机密钥 TOFU（Trust On First Use）校验。
  ///
  /// 首次连接某 `host:port` 时记录其密钥指纹；后续连接比对指纹，
  /// 一致则信任，不一致则拒绝（防止中间人替换主机密钥）。
  /// 指纹按 `host:port + 算法类型` 分别持久化，互不干扰。
  ///
  /// 返回 true 表示信任（首次连接时同时完成记录）；false 表示拒绝。
  /// TOFU 校验：首次记录指纹、后续比对。
  ///
  /// [onMismatch] 只在**本次连接**的上下文里回传"指纹不匹配"，让调用方抛出带类型
  /// 的 [TunnelHostKeyMismatchException]；不设全局标志（并发连接会互相串档）。
  Future<bool> _verifyHostKey(
    SSHConfig config,
    String hostkeyType,
    Uint8List fingerprint, {
    void Function()? onMismatch,
  }) async {
    final key = 'ssh_hostkey_${config.host}_${config.sshPort}_$hostkeyType';
    final hex =
        fingerprint.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved == null) {
        // 首次连接：记录指纹并信任（TOFU 首连假设）
        await prefs.setString(key, hex);
        debugPrint('[DSH] host key first-seen for $key, recorded '
            'fingerprint=$hex');
        return true;
      }
      if (saved == hex) {
        return true;
      }
      // 指纹变化：拒绝连接并提示（可能是中间人，也可能是服务器重装）
      debugPrint('[DSH] host key MISMATCH for $key: '
          'saved=$saved current=$hex');
      onMismatch?.call();
      return false;
    } catch (e) {
      // 存储异常时退回"信任"以保持可用性，但记录日志便于排查
      debugPrint('[DSH] host key store unavailable, fallback trust: $e');
      return true;
    }
  }

  /// 清除全部已保存的主机密钥指纹（TOFU 记录）。
  ///
  /// 服务器重装/更换密钥导致指纹不匹配时调用，清除后下次连接重新记录。
  static Future<void> clearHostKeyFingerprints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys()
          .where((k) => k.startsWith('ssh_hostkey_'))
          .toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
      debugPrint('[DSH] cleared ${keys.length} host key fingerprint(s)');
    } catch (e) {
      debugPrint('[DSH] clear host key fingerprints failed: $e');
    }
  }

  /// 健壮解码：先尝试 UTF-8 严格解码（合法即采用，避免中文文本被
  /// 误判为 GBK 产生乱码），失败再自动检测编码（UTF-8 → GBK/GB2312
  /// → ASCII），检测/解码异常时兜底 UTF-8 宽松解码，避免返回空导致白屏。
  String _decodeBytes(Uint8List bytes) {
    try {
      return utf8.decode(bytes); // 严格模式：含非法字节会抛 FormatException
    } catch (_) {}
    try {
      final detected = Charset.detect(bytes, orders: [utf8, gbk, ascii]);
      if (detected != null) return detected.decode(bytes);
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ================= 主机监控：远程命令采集 =================

  /// 主机类型缓存。
  ///
  /// **按 `host:port:用户名` 缓存，而不是按 SSHClient 实例**：旧实现用 client 做
  /// key，每次重连都留下一个永不回收的条目（泄漏），而且重连后缓存全部失效、
  /// 每台机器每次重连都要重新跑一遍 `uname -s`。主机类型是服务器的属性，与是哪
  /// 条会话无关——换成按主机缓存后，重连不再触发重复探测。
  final Map<String, HostType> _hostTypes = {};

  /// 由配置生成主机类型缓存键。
  static String? _hostKeyOf(SSHConfig? c) =>
      c == null ? null : '${c.host}:${c.sshPort}:${c.username}';

  /// 在指定 SSH 会话上执行命令，返回合并后的 stdout+stderr 文本。
  ///
  /// 执行失败 / 超时返回 null。输出用 [_decodeBytes] 健壮解码
  /// （UTF-8 → GBK → ASCII），兼容 Windows cmd 的 GBK 错误信息。
  Future<String?> _execOn(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final bytes = await client.run(command).timeout(timeout);
      return _decodeBytes(bytes);
    } catch (e) {
      debugPrint('[DSH] executeRemote failed: $e');
      return null;
    }
  }

  /// 在当前活动隧道上执行命令（对外保留的便捷方法）。
  Future<String?> executeRemote(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = _client;
    if (client == null) return null;
    return _execOn(client, command, timeout: timeout);
  }

  /// 探测指定 SSH 会话的主机类型（**按主机 `host:port:user` 缓存**，见 [_hostTypes]）。
  ///
  /// Windows（默认 cmd）执行 `uname -s` 会返回"命令不存在"的 GBK 错误文本，
  /// 因此不能仅凭"输出非空"判定 Unix：须识别命令不存在 / Windows bash 环境
  /// 标识（MINGW / MSYS / CYGWIN / *_NT），否则视为 Unix 系。
  Future<HostType> _detectHostType(SSHClient client, {String? hostKey}) async {
    final key = hostKey ?? _hostKeyOf(_activeConfig) ?? 'unknown';
    final cached = _hostTypes[key];
    if (cached != null) return cached;
    final out = await _execOn(client, 'uname -s');
    final t = (out ?? '').trim();
    if (t.isEmpty) {
      // **采样失败绝不能当成"这是 Windows"**。`_execOn` 超时/链路抖动返回 null，
      // 旧实现把空串归为 windows 并永久写进缓存：Linux 主机从此用 PowerShell 采集
      // （恒失败、曲线停在旧值），`ensureUploadDir` 也开始按 `C:/Users/...` 探测。
      // 失败就不缓存、下次重探，本次按 linux 兜底走。
      debugPrint('[DSH] host type probe got no output; not caching (fallback linux)');
      return HostType.linux;
    }
    final isWindows =
        t.contains('MINGW') ||
        t.contains('MSYS') ||
        t.contains('CYGWIN') ||
        t.contains('_NT') ||
        // 命令不存在类错误 → Windows cmd
        t.contains('不是内部或外部命令') ||
        t.contains('不是内部命令') ||
        t.contains('not recognized') ||
        t.contains('command not found') ||
        t.contains('not found') ||
        t.contains('找不到');
    final type = isWindows ? HostType.windows : HostType.linux;
    _hostTypes[key] = type;
    debugPrint('[DSH] detected host type: $type (uname="$t")');
    return type;
  }

  /// 在指定 SSH 会话上采集一次主机使用率（CPU / 内存 / GPU）。
  /// 会话断开或采集失败返回 null。
  Future<HostSample?> _sampleFrom(SSHClient client, [String? hostKey]) async {
    final type = await _detectHostType(client, hostKey: hostKey);
    final command = _buildSampleCommand(type);
    final out = await _execOn(client, command);
    if (out == null || out.trim().isEmpty) return null;
    return _parseSample(out);
  }

  /// 采集一次当前活动隧道的主机使用率（CPU / 内存 / GPU）。
  Future<HostSample?> collectHostSample() async {
    final client = _client;
    if (client == null) return null;
    return _sampleFrom(client, _hostKeyOf(_activeConfig));
  }

  /// 按主机类型构造采集命令：输出 `CPU=xx` / `MEM=xx` / `GPU=xx` / `GPUTEMP=xx`。
  ///
  /// 用原始字符串避免 Dart 对 `$`（awk 列 / PowerShell 变量）的插值转义。
  /// 注意：dartssh2 的 `client.run()` 本身就是经远程 bash 执行命令，
  /// 不能再包一层 `sh -c '...'`，否则 bash 单引号嵌套冲突（unexpected EOF）
  /// 导致整条命令解析失败（曾实测：Linux 主机采集全失败）。
  ///
  /// Linux 分支对 ARM/精简/容器环境做了健壮化：
  /// - CPU 用 /proc/stat（busybox awk 兼容），无匹配时输出 0；
  /// - MEM 改用 /proc/meminfo（MemTotal - MemAvailable），不依赖 free 命令；
  /// - GPU 使用率 / 温度各一行，无 nvidia-smi 时留空（解析为 -1）。
  ///
  /// Windows 分支：bash 会展开 `$`，PowerShell 变量的 `$` 必须转义为 `\$`，
  /// 否则变量被 bash 展开为空导致采集失败。
  String _buildSampleCommand(HostType type) {
    if (type == HostType.linux) {
      return r'''c=$(awk "/^cpu /{i=\$5+\$6+\$7; t=\$2+\$3+\$4+\$5+\$6+\$7+\$8; if(t>0){printf \"%.0f\",(t-i)*100/t}else{printf \"0\"}}" /proc/stat 2>/dev/null); m=$(awk "/^MemTotal:/{t=\$2} /^MemAvailable:/{a=\$2} END{if(t>0){printf \"%.0f\",(t-a)*100/t}else{printf \"0\"}}" /proc/meminfo 2>/dev/null); g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); gt=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); [ -z "$c" ] && c=0; [ -z "$m" ] && m=0; echo "CPU=$c"; echo "MEM=$m"; echo "GPU=$g"; echo "GPUTEMP=$gt"''';
    }
    // Windows：性能计数器 + nvidia-smi（无 GPU 时 GPU 行留空，解析为 -1）。
    // Get-Counter 首次读取可能返回 null，回退 0 避免解析异常。
    return r'''powershell -NoProfile -Command "\$c=Get-Counter '\Processor(_Total)% Processor Time' -ErrorAction SilentlyContinue; \$cpu=if(\$c.CounterSamples[0].CookedValue -eq \$null){0}else{[int]\$c.CounterSamples[0].CookedValue}; \$m=Get-Counter '\Memory% Committed Bytes In Use' -ErrorAction SilentlyContinue; \$mem=if(\$m.CounterSamples[0].CookedValue -eq \$null){0}else{[int]\$m.CounterSamples[0].CookedValue}; \$gpu=(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>\$null); \$gt=(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>\$null); Write-Output ('CPU='+\$cpu); Write-Output ('MEM='+\$mem); Write-Output ('GPU='+\$gpu); Write-Output ('GPUTEMP='+\$gt)"''';
  }

  /// 解析采集输出（`CPU=xx` / `MEM=xx` / `GPU=xx` / `GPUTEMP=xx`）。
  /// 数值取首个数字；GPU 多卡逗号分隔时取首个；缺行/空值视为 0 / -1。
  HostSample? _parseSample(String out) {
    var cpu = 0.0, mem = 0.0, gpu = -1.0, gpuTemp = -1.0;
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.startsWith('CPU=')) {
        cpu = _firstNumber(t.substring(4));
      } else if (t.startsWith('MEM=')) {
        mem = _firstNumber(t.substring(4));
      } else if (t.startsWith('GPU=')) {
        final s = t.substring(4);
        gpu = s.trim().isEmpty ? -1 : _firstNumber(s);
      } else if (t.startsWith('GPUTEMP=')) {
        final s = t.substring(7);
        gpuTemp = s.trim().isEmpty ? -1 : _firstNumber(s);
      }
    }
    return HostSample(
      cpu: cpu.clamp(0, 100),
      mem: mem.clamp(0, 100),
      gpu: gpu >= 0 ? gpu.clamp(0, 100) : -1,
      // GPU 温度常见 40~90℃，极端值按 0~150 夹取（>100 画在顶栏顶部被裁剪）
      gpuTemp: gpuTemp >= 0 ? gpuTemp.clamp(0, 150) : -1,
    );
  }

  /// 提取字符串中的首个数值（含小数）；无数值返回 0。
  static double _firstNumber(String s) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
    if (m == null) return 0;
    return double.tryParse(m.group(0) ?? '') ?? 0;
  }

  // ================= Unsloth Studio：SSH 模式独立转发 =================

  /// Unsloth Studio 专用 SSH 客户端（与活动隧道/监控隧道相互独立），
  /// 保证顶栏图标可打开任意实例的 Unsloth Studio，即使它不是当前连接实例。
  SSHClient? _unslothClient;
  bool _unslothConnecting = false;

  /// Unsloth Studio 本地监听（SSH 模式时存在），转发到远程 127.0.0.1 上的 unsloth 端口。
  ServerSocket? _unslothServer;

  /// Unsloth Studio 远程端口（取实例配置，默认 8888）。
  int _unslothRemotePort = SSHConfig.defaultUnslothPort;

  /// Unsloth Studio 本地端口（SSH 模式时 OS 动态分配；直连模式为 null）。
  int? get unslothLocalPort => _unslothServer?.port;

  /// 建立 Unsloth Studio 转发：建立到配置实例的独立 SSH 会话，
  /// 本地监听端口由 OS 动态分配（bind 0），转发到远程 127.0.0.1:[unslothPort]。
  ///
  /// 配置未就绪 / 认证失败 / 绑定失败时返回 null，调用方提示错误。
  /// [unslothPort] 可空：为空时使用配置端口（默认 8888）。
  Future<int?> startUnslothForward(SSHConfig config,
      {int? unslothPort}) async {
    await stopUnslothForward();
    if (!config.isConfigured) return null;
    _unslothRemotePort = unslothPort ?? config.unslothPort;
    // 建立独立的 unsloth SSH 会话（不依赖当前活动隧道）
    if (!await _connectUnslothClient(config)) return null;
    try {
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, 0);
      _unslothServer = server;
      server.listen(_handleUnslothForward);
      debugPrint('[DSH] unsloth forward up: '
          '127.0.0.1:${server.port} -> 127.0.0.1:$_unslothRemotePort');
      return server.port;
    } catch (e) {
      debugPrint('[DSH] unsloth forward failed: $e');
      _unslothServer = null;
      await _closeUnslothClient();
      return null;
    }
  }

  /// 建立 Unsloth Studio 独立 SSH 会话（认证流程与监控隧道一致）。
  Future<bool> _connectUnslothClient(SSHConfig config) async {
    if (_unslothConnecting) return _unslothClient != null;
    _unslothConnecting = true;
    try {
      final socket = await SSHSocket.connect(config.host, config.sshPort,
          timeout: const Duration(seconds: 15));
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) =>
            _verifyHostKey(config, hostkeyType, fingerprint),
      );
      _unslothClient = client;
      client.done.then(
        (_) => _onUnslothClientClosed(client),
        onError: (Object e) {
          debugPrint('[DSH] unsloth transport error: $e');
          _onUnslothClientClosed(client, failed: true);
        },
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] unsloth auth timed out');
        throw const SocketException('Unsloth 连接认证超时');
      });
      debugPrint('[DSH] unsloth ssh ready '
          '(${config.host}:${config.sshPort})');
      return true;
    } catch (e) {
      debugPrint('[DSH] unsloth connect failed: $e');
      final c = _unslothClient;
      _unslothClient = null;
      c?.close();
      return false;
    } finally {
      _unslothConnecting = false;
    }
  }

  /// Unsloth 专用 SSH 会话关闭：连带关闭本地转发监听。
  void _onUnslothClientClosed(SSHClient client, {bool failed = false}) {
    if (_unslothClient != client) return;
    _unslothClient = null;
    debugPrint('[DSH] unsloth transport closed'
        '${failed ? ' (with error)' : ''}');
    final server = _unslothServer;
    _unslothServer = null;
    server?.close();
  }

  /// 处理一条 Unsloth Studio 本地连接：经独立 SSH 会话转发到远程端口。
  ///
  /// 与主隧道的 `_handleForward` 同样必须给 `forwardLocal` 加超时：库内该
  /// Future 无超时，会话半死时会永久挂起并把这条本地连接吊住。
  Future<void> _handleUnslothForward(Socket local) async {
    final client = _unslothClient;
    if (client == null) {
      local.destroy();
      return;
    }
    // 同 `_handleForward`：持有源 future，超时/失败后仍要收尾迟到的 channel。
    final openFuture = client.forwardLocal('127.0.0.1', _unslothRemotePort);
    try {
      // 远程 Unsloth Studio 监听 127.0.0.1:<unslothRemotePort>
      final forward = await openFuture.timeout(forwardOpenTimeout);
      if (!identical(_unslothClient, client)) {
        try {
          forward.destroy();
        } catch (_) {}
        local.destroy();
        return;
      }
      _pipe(local, forward);
    } catch (_) {
      local.destroy();
      unawaited(openFuture.then<void>((channel) {
        try {
          channel.destroy();
        } catch (_) {}
      }, onError: (Object _) {}));
    }
  }

  /// 关闭 Unsloth Studio 转发（页面关闭时调用），连带关闭独立 SSH 会话。
  Future<void> stopUnslothForward() async {
    final server = _unslothServer;
    _unslothServer = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
    await _closeUnslothClient();
  }

  Future<void> _closeUnslothClient() async {
    final c = _unslothClient;
    _unslothClient = null;
    if (c != null) c.close();
  }

  // 主动断开见 [disconnect]（监督器统一拥有重试计划，这里不再单独实现一套）。

  // ================= 实例级主机资源监控（独立采集隧道）=================

  /// 开启"默认主机资源监控"的实例索引，null 表示无。
  int? _monitorProfileIndex;
  SSHConfig? _monitorConfig;

  /// 独立的监控采集 SSH 客户端（与活动隧道分开，用于采集指定实例的主机数据）。
  SSHClient? _monitorClient;
  bool _monitorConnecting = false;

  /// 监控隧道的重连退避状态（见 [_ensureMonitorClient] 的说明）。
  int _monitorAttempt = 0;
  DateTime? _monitorNextAllowedAt;

  /// 当前监控实例索引（null 表示无）。
  int? get monitorProfileIndex => _monitorProfileIndex;

  /// 设置监控实例：建立/关闭独立的监控采集隧道。
  ///
  /// [config] 为 null 或未配置时关闭现有监控隧道；
  /// 否则建立到该实例的采集连接（与活动隧道相互独立，切换实例不受影响）。
  Future<void> setupMonitorProfile(
      SSHConfig? config, {int? profileIndex}) async {
    _monitorProfileIndex = profileIndex;
    _monitorConfig = (config != null && config.isConfigured) ? config : null;
    _monitorAttempt = 0;
    _monitorNextAllowedAt = null;
    await _closeMonitorClient();
    final c = _monitorConfig;
    if (c == null) return;
    await _connectMonitor(c);
  }

  Future<void> _connectMonitor(SSHConfig config) async {
    if (_monitorConnecting) return;
    _monitorConnecting = true;
    try {
      final socket = await SSHSocket.connect(config.host, config.sshPort,
          timeout: const Duration(seconds: 15));
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) =>
            _verifyHostKey(config, hostkeyType, fingerprint),
      );
      _monitorClient = client;
      client.done.then(
        (_) => _onMonitorClosed(client),
        onError: (Object e) {
          _log('monitor', '监控传输层异常：$e', level: TunnelEventLevel.warn);
          _onMonitorClosed(client, failed: true);
        },
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        throw const SocketException('监控连接认证超时');
      });
      _monitorAttempt = 0;
      _monitorNextAllowedAt = null;
      _log('monitor',
          '监控隧道就绪（profile=$_monitorProfileIndex ${config.host}:${config.sshPort}）');
    } catch (e) {
      _monitorAttempt += 1;
      final delay = _backoff.delayFor(_monitorAttempt, random: _rng.nextDouble);
      _monitorNextAllowedAt = DateTime.now().add(delay);
      _log('monitor',
          '监控隧道连接失败（第 $_monitorAttempt 次）：$e → ${delay.inSeconds}s 内不再尝试',
          level: TunnelEventLevel.warn);
      final mc = _monitorClient;
      _monitorClient = null;
      try {
        mc?.close();
      } catch (_) {}
    } finally {
      _monitorConnecting = false;
    }
  }

  void _onMonitorClosed(SSHClient client, {bool failed = false}) {
    if (_monitorClient != client) return;
    _monitorClient = null;
    // 传输层掉线同样要退避：否则下一条采样立刻重开握手，服务器不可达时
    // 又是"每 10 秒一次认证"的老问题。
    _monitorAttempt += 1;
    final delay = _backoff.delayFor(_monitorAttempt, random: _rng.nextDouble);
    _monitorNextAllowedAt = DateTime.now().add(delay);
    _log('monitor',
        '监控传输层关闭${failed ? '（异常）' : ''} → ${delay.inSeconds}s 后才允许重连',
        level: failed ? TunnelEventLevel.warn : TunnelEventLevel.info);
  }

  Future<void> _closeMonitorClient() async {
    final mc = _monitorClient;
    _monitorClient = null;
    if (mc != null) mc.close();
  }

  /// 确保监控隧道存在（懒连接）；无法建立返回 null。
  ///
  /// **退避保护**：旧实现每次采样（10s 一次）都会无条件重开一次完整 SSH 握手
  /// ——最坏 15s(TCP)+20s(auth)——服务器不可达时就是一场每 10 秒一次的认证风暴：
  /// 抢带宽、拖慢主隧道重连，还可能踩中 sshd `MaxStartups` 被临时封禁。
  /// 现在失败后按 [TunnelBackoff] 退避，期间直接返回 null（曲线停在最后一条，
  /// 而不是假装还在采样）。
  Future<SSHClient?> _ensureMonitorClient() async {
    if (_monitorClient != null) return _monitorClient;
    final c = _monitorConfig;
    if (c == null || _monitorConnecting) return null;
    final next = _monitorNextAllowedAt;
    if (next != null && DateTime.now().isBefore(next)) return null;
    await _connectMonitor(c);
    return _monitorClient;
  }

  /// 采集监控实例的主机使用率。
  ///
  /// 当前活动隧道恰好是监控实例时直接复用（避免双连接）；
  /// 否则使用独立的监控采集隧道。
  Future<HostSample?> collectMonitorSample() async {
    if (_monitorProfileIndex == null) return null;
    if (_activeProfileIndex == _monitorProfileIndex && _client != null) {
      return _sampleFrom(_client!, _hostKeyOf(_activeConfig));
    }
    final mc = await _ensureMonitorClient();
    if (mc == null) return null;
    return _sampleFrom(mc, _hostKeyOf(_monitorConfig));
  }

  void dispose() {
    // 释放隧道与后台资源。注意：不关闭状态流、不置永久失效标志——
    // TunnelService 是应用级单例，根 State 可能在运行期重建
    // （例如 Flutter 框架重建根路由），关闭后单例将永久不可用，
    // 隧道无法再次建立。进程退出时资源由系统回收即可。
    // 停止前台服务并释放唤醒锁
    ForegroundTunnelService.instance.stop();
    // 关闭 Unsloth Studio 转发
    stopUnslothForward();
    // 关掉监督器的全部定时器：新的 WebViewScreen 挂载时会重新 connect() 拉起。
    _wantConnected = false;
    // 作废在途尝试：否则一条正在 `SSHSocket.connect` 的尝试会在 dispose 之后
    // 把隧道连回来、绑端口、起看门狗，而已经没人负责再关它了。
    _bumpGeneration('服务释放');
    _inflight = null;
    _inflightKey = '';
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _networkTimer?.cancel();
    _networkTimer = null;
    // 关闭独立的监控采集隧道
    final mc = _monitorClient;
    _monitorClient = null;
    try {
      mc?.close();
    } catch (_) {}
    // 断开活动隧道（含本地端口监听、转发 socket 与 SSH 会话）
    unawaited(_teardown());
  }
}
