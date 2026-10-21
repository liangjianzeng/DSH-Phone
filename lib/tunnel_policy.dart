/// 隧道连接策略：故障分类 + 重连退避 + 提示分级。
///
/// 刻意保持**纯 Dart、零依赖**（不引 Flutter、不引 dartssh2）：这三个决策是
/// 整套"断线自愈"行为的大脑，必须能在 `flutter test` 里被钉死，而不是只能
/// 靠真机上"挂一晚上看它会不会自己活过来"来验证。
///
/// 对应整改项：
/// - 重连不再"5 次烧完就停"（见 [TunnelBackoff]）；
/// - 不再对瞬时抖动弹红色报错（见 [TunnelAlertPolicy]）；
/// - 错误文案按故障类别给结论，而不是把异常原文 + 一大段 VPN 建议糊上去。
library;

/// 隧道**临时端口**首选段：3090–3099。
///
/// 配置端口被占时不再向系统要随机端口（`bind(0)` 会给到 4 万多的 ephemeral 段，
/// 用户在状态栏看到 127.0.0.1:43117 既看不懂也记不住，排查时更没法比对），
/// 而是先在这 10 个里挑——一眼认得出"这是隧道自己临时换的"。
/// 首选段用满后继续往 [tunnelFallbackPoolMax] 方向借，见 [tunnelFallbackPoolMin]。
/// 代价是这个池子被征用：**用户在设置里不允许填它**，否则配置端口与临时端口
/// 会互相撞，见 [isReservedFallbackPort]。
const int tunnelFallbackPortMin = 3090;
const int tunnelFallbackPortMax = 3099;

/// 临时端口**完整保留池**：3090–3149（首选段 3090-3099 + 扩展段 3100-3149）。
///
/// 为什么光有 10 个会把用户逼死（2026-10-21 真机复盘）：端口占用绝大多数是
/// **自家僵尸 FD**。Android 后台回收常常只销毁 Activity，进程被 sticky 前台服务
/// 加 wakelock 拽着不死；从最近任务回来时 Flutter 在**同一个进程里换了个
/// isolate**。而 isolate 死掉**不会**释放它没 `close()` 的 `ServerSocket`——
/// 实测（dart 3.7：同进程 spawn 一个 isolate 绑端口后 `Isolate.kill(immediate)`）
/// 端口一直占到**整个进程退出**为止。于是每"退后台 → 回前台"一轮就烧掉一个可借
/// 端口，10 个烧满之后就是「绑定全失败 → 停止重试 → 只能手动杀进程」。
/// 扩池只是把死锁推迟到几十轮；真正止血在 `TunnelService` 的残骸清扫
/// （`_sweepOrphanListeners`）与「重启应用」一键自救。
/// 仍然全是固定段、一眼认得出是隧道借的，**没有退回 `bind(0)`**。
const int tunnelFallbackPoolMin = tunnelFallbackPortMin;
const int tunnelFallbackPoolMax = 3149;

/// 是否落在临时端口保留池（设置页据此拒绝保存，隧道据此挑临时端口）。
bool isReservedFallbackPort(int port) =>
    port >= tunnelFallbackPoolMin && port <= tunnelFallbackPoolMax;

/// 临时端口的尝试顺序：**首选段先试**（段内打乱），再用扩展段（段内也打乱）。
///
/// 打乱是必要的——同机多路实例配置端口全被占时，若都从 3090 开始抢，第一个
/// 占走 3090 后其余各要多试一次才拿到 3091；随机起点让它们互不干扰。
/// 首选段整体排在前面，是为了让"状态栏里看到的临时端口"绝大多数时候还是
/// 3090-3099 这个用户最眼熟的窗口。
List<int> fallbackPortCandidates({double Function()? random}) {
  List<int> build(int from, int to) {
    final ports = <int>[for (var port = from; port <= to; port++) port];
    final rnd = random;
    if (rnd == null) return ports;
    for (var i = ports.length - 1; i > 0; i--) {
      final j = (rnd() * (i + 1)).floor().clamp(0, i);
      final tmp = ports[i];
      ports[i] = ports[j];
      ports[j] = tmp;
    }
    return ports;
  }

  return [
    ...build(tunnelFallbackPortMin, tunnelFallbackPortMax),
    if (tunnelFallbackPoolMax > tunnelFallbackPortMax)
      ...build(tunnelFallbackPortMax + 1, tunnelFallbackPoolMax),
  ];
}

/// 本地转发端口彻底起不来：配置端口被占、整个临时端口池也绑不上。
///
/// 带着"谁占着"的探测结论上抛，界面上才能给出可执行的动作——只说
/// 「请关闭其它占用该端口的程序」用户无从下手（手机上根本看不到是谁）。
class TunnelLocalPortOccupiedException implements Exception {
  const TunnelLocalPortOccupiedException(
    this.port,
    this.holder, {
    this.tried = const [],
    this.selfZombieSuspected = false,
    this.occupiedBySelf = const [],
    this.occupiedByOthers = const [],
  });

  /// 配置里要求的本地端口。
  final int port;

  /// 占用情况的一句话结论（见 TunnelService 的端口探测）。
  final String holder;

  /// **实际尝试过并绑定失败**的端口（含配置端口与整个保留池）。
  ///
  /// 必须有：用户第一反应是"你根本没随机试"，而这条列表就是"确实逐个试过了"
  /// 的证据；空列表则说明确实是没走到那一步，两者排查方向完全不同。
  final List<int> tried;

  /// 占用者在本进程内的端口（Dart 报 `shared flag to bind()`）。
  ///
  /// 这一类是本次事故的主因：自家没 `close()` 的残骸，或者**上一个 isolate** 留下
  /// 的僵尸监听（进程没死、isolate 换了，FD 跟着进程一起活着）。前者能被清扫回收，
  /// 后者谁也碰不到。
  final List<int> occupiedBySelf;

  /// 被**别的进程**占着的端口（内核 `EADDRINUSE`）——该让用户去设置里换端口。
  final List<int> occupiedByOthers;

  /// 是否怀疑占着端口的是**本进程上一世代 isolate 留下的僵尸监听**。
  ///
  /// 判据以**错误形态**为准：`ServerSocket.bind` 只有在**本进程**已经绑过这个端口
  /// 时才报 `shared flag to bind()`（`osError.errorCode = -1`），而自家登记表里又
  /// 没有这个端口 —— 那就只能是上一个 isolate 留下的僵尸监听。这种占用从 Dart 侧
  /// 永远关不掉（FD 属于已死的 isolate，只随进程退出而释放），所以界面要把
  /// 「重启应用」提为主按钮，而不是让用户去找"其它占用该端口的程序"：他什么也
  /// 关不掉。pid 自比对（`TunnelService._detectSameProcessRespawn`）只作旁证进日志。
  final bool selfZombieSuspected;

  @override
  String toString() =>
      '本地端口 $port 被占用（$holder），临时端口池 $tunnelFallbackPoolMin-'
      '$tunnelFallbackPoolMax 也全部不可用'
      '（共试过 ${tried.isEmpty ? '0' : tried.length} 个：${tried.join(',')}；'
      '本进程内占用 ${occupiedBySelf.isEmpty ? '无' : occupiedBySelf.join(',')}、'
      '外部进程占用 ${occupiedByOthers.isEmpty ? '无' : occupiedByOthers.join(',')}）'
      '${selfZombieSuspected ? ' → 疑似本进程上一世代 isolate 残留，需重启应用' : ''}';
}

/// 隧道故障类别：决定给用户看什么话、要不要立刻打扰用户。
enum TunnelFailureKind {
  /// 无故障。
  none,

  /// 主机名解析失败：Tailscale/MagicDNS 未就绪是最常见成因。
  dns,

  /// 网络不可达 / 连接超时：链路或 VPN 隧道没通（切网、飞行模式、节点重拨）。
  unreachable,

  /// 连接被拒绝：sshd 没起 / 端口不对。
  refused,

  /// 通用超时：分不清卡在哪一段时的兜底。
  timeout,

  /// 认证失败：密码/私钥不对。
  auth,

  /// 主机密钥指纹不匹配：TOFU 拒绝，或服务器重装换过密钥。
  hostKey,

  /// 私钥解析失败（格式错/口令错）。
  keyDecode,

  /// 隧道本身在，但远端 Web 服务无应答（探活失败）——服务没起或被防火墙吃掉。
  remoteDown,

  /// 本地转发端口绑定失败（端口被占）。
  localPort,

  /// 其它。
  unknown,
}

/// 用户可读的故障结论（短、给方向，不带堆栈）。
///
/// 长文技术细节走诊断页，不再往界面上糊——历史上 `_appendQosHintIfTimeout`
/// 把一大段 VPN/运营商建议无差别追加到每条错误里，是"没用的报错"的主要来源。
String tunnelFailureSummary(TunnelFailureKind kind) {
  switch (kind) {
    case TunnelFailureKind.dns:
      return '无法解析服务器地址：VPN 可能尚未就绪。连上 Tailscale 后会自动重试';
    case TunnelFailureKind.unreachable:
      return '到服务器的网络不通：请检查手机网络与 VPN 连接';
    case TunnelFailureKind.refused:
      return '服务器拒绝连接：请确认远端 SSH 服务已启动、端口填写正确';
    case TunnelFailureKind.timeout:
      return '连接服务器超时：网络较慢或链路不稳定，正在继续重试';
    case TunnelFailureKind.auth:
      return 'SSH 认证失败：请检查用户名、密码或私钥';
    case TunnelFailureKind.hostKey:
      return '服务器主机密钥与上次记录不一致，已拒绝连接（若服务器重装过，请在设置里清除指纹）';
    case TunnelFailureKind.keyDecode:
      return '私钥无法解析：请检查私钥格式与口令';
    case TunnelFailureKind.remoteDown:
      return 'SSH 已连通，但云端服务没有应答：请确认远端服务已启动';
    case TunnelFailureKind.localPort:
      return '本地端口被占住，临时端口池（$tunnelFallbackPoolMin-'
          '$tunnelFallbackPoolMax）也已用满：请点「重启应用」收回本进程残留的监听，'
          '或在设置里换一个本地端口（勿填 $tunnelFallbackPoolMin-'
          '$tunnelFallbackPoolMax）后点「立即重试」';
    case TunnelFailureKind.none:
      return '连接正常';
    case TunnelFailureKind.unknown:
      return '连接异常，正在自动重试';
  }
}

/// 该故障属于"配错了、重试也不会好"的配置类错误：
/// 这类要立刻告诉用户并给出改设置的入口；网络类则默默退避重试、不打扰。
bool isConfigurationFailure(TunnelFailureKind kind) {
  switch (kind) {
    case TunnelFailureKind.auth:
    case TunnelFailureKind.hostKey:
    case TunnelFailureKind.keyDecode:
    case TunnelFailureKind.localPort:
    case TunnelFailureKind.refused:
      return true;
    case TunnelFailureKind.dns:
    case TunnelFailureKind.unreachable:
    case TunnelFailureKind.timeout:
    case TunnelFailureKind.remoteDown:
    case TunnelFailureKind.none:
    case TunnelFailureKind.unknown:
      return false;
  }
}

/// 这类故障"多试几次也不会变好"：不该拿快速退避去空转，得由用户改配置或释放资源。
///
/// **语义是"别空转"，不是"从此不再尝试"**：监督器改按
/// [tunnelLocalPortSalvageInterval] 兜底慢试（见 tunnel_service 的 futile 分支）。
/// 早先是直接停止一切重试，于是端口占用被钉成永久失败，用户除了杀进程没有第二条
/// 路；而端口占用常常是暂时的（第三方 App 退出、自家残骸被回收），60s 一次的代价
/// 几乎为零，却把"必须手动干预"变成"多数情况自己活过来"。界面仍是 `hard` 级红色
/// 指引，不会退回"第 4 次尝试 · 约 5 秒后自动重试"那种假装在干活的空转。
bool isFutileRetryFailure(TunnelFailureKind kind) =>
    kind == TunnelFailureKind.localPort;

/// 端口类故障的兜底重试节奏：**不再永久停止**，但也不再快速空转。
const Duration tunnelLocalPortSalvageInterval = Duration(seconds: 60);

/// 从异常推断故障类别。
///
/// 只依赖 `toString()`：dartssh2 的异常类型（SSHAuthFailError 等）不进入本文件，
/// 保证纯 Dart 可测。传入 [probeFailed] 表示"TCP 能连上但 HTTP 探活无应答"。
TunnelFailureKind classifyTunnelFailure(Object error, {bool probeFailed = false}) {
  if (probeFailed) return TunnelFailureKind.remoteDown;
  final s = error.toString();
  final lower = s.toLowerCase();

  bool containsAny(List<String> needles) => needles.any(lower.contains);

  // 先判"明确语义"的，再判泛化关键词：SocketException 的文案里也含 connect/
  // socket 等词，顺序反了会把 DNS 失败误判成 unknown。
  if (containsAny(const ['sshhostkeyerror', '主机密钥', 'host key'])) {
    return TunnelFailureKind.hostKey;
  }
  // 认证完成**之前**传输层就断了：dartssh2 用 `SSHAuthAbortError('Connection
  // closed before authentication')` 表达这件事（见 ssh_client.dart
  // `_handleTransportClosed`）。它是链路死亡，不是凭据错误——曾经这里用
  // 'authentication' 关键词把它一并算进 auth，于是每次闪断都弹红色
  // 「SSH 认证失败：请检查用户名、密码或私钥」，用户照着去改密码只会越改越
  // 连不上。这条必须排在 auth 规则前面。
  if (containsAny(const [
    'sshauthaborterror',
    'connection closed before authentication',
  ])) {
    return TunnelFailureKind.unreachable;
  }
  if (containsAny(const [
    'sshauthfailerror',
    'unable to authenticate',
    'no supported authentication methods',
    'permission denied',
    'invalid user',
    '认证失败',
  ])) {
    return TunnelFailureKind.auth;
  }
  if (containsAny(const ['sshkeydecodeerror', 'sshkeydecrypterror', 'pem', 'passphrase'])) {
    return TunnelFailureKind.keyDecode;
  }
  if (containsAny(const ['failed host lookup', 'name or service not known',
        'nodename nor servname', 'temporary failure in name resolution',
        'no address associated with hostname'])) {
    return TunnelFailureKind.dns;
  }
  if (error is TunnelLocalPortOccupiedException) {
    return TunnelFailureKind.localPort;
  }
  if (containsAny(const ['already bound', 'address already in use', 'bind'])) {
    return TunnelFailureKind.localPort;
  }
  if (containsAny(const ['connection refused', 'econnrefused'])) {
    return TunnelFailureKind.refused;
  }
  if (containsAny(const ['network is unreachable', 'network unreachable',
        'host is unreachable', 'no route to host', 'enetreunreach'])) {
    return TunnelFailureKind.unreachable;
  }
  if (containsAny(const ['timed out', 'timeout', '超时'])) {
    return TunnelFailureKind.timeout;
  }
  if (containsAny(const ['connection reset', 'econnreset', 'socketexception',
        'broken pipe'])) {
    // 移动网络/VPN 链路被掐断的典型表现，属于链路问题而非配置问题。
    return TunnelFailureKind.unreachable;
  }
  // 库内自述"已关闭"的错误：多为对端/链路把会话拆了，属链路类，继续重试。
  if (containsAny(const [
    'transport is closed',
    'socket is closed',
    'sshsocketerror',
    'sshchannelopenerror',
  ])) {
    return TunnelFailureKind.unreachable;
  }
  return TunnelFailureKind.unknown;
}

/// 重连退避：**永不放弃**，指数增长到上限后封顶，带抖动避免与 VPN 重拨同频。
///
/// 历史实现是"线性 2/4/6/8/10s，5 次共 30 秒后彻底停止且不再有任何定时器"。
/// 移动网络与 Tailscale 重拨通常要 30 秒到几分钟，于是每次真实断线都会停在
/// 死错误页上，只能用户手动重试——正是本次整改要消灭的行为。
class TunnelBackoff {
  const TunnelBackoff({
    this.first = const Duration(milliseconds: 800),
    this.cap = const Duration(seconds: 60),
    this.growth = 2.0,
    this.jitterRatio = 0.25,
  });

  /// 第 1 次重试的间隔。
  final Duration first;

  /// 间隔上限（封顶后无限次按此节奏继续试）。
  final Duration cap;

  /// 指数底数。
  final double growth;

  /// 抖动比例：实际间隔在 `[1-r, 1+r]` 倍之间取值，避免与链路重拨同频互踩。
  final double jitterRatio;

  /// 第 [attempt] 次重试（1 基）应等待多久。[random] 注入以便测试确定性。
  Duration delayFor(int attempt, {double Function() random = _defaultRandom}) {
    if (attempt < 1) attempt = 1;
    final base = first.inMilliseconds *
        _pow(growth, (attempt - 1).toDouble(), cap.inMilliseconds.toDouble());
    var ms = base.clamp(0.0, cap.inMilliseconds.toDouble());
    if (jitterRatio > 0) {
      final r = random();
      final jitter = (r * 2 - 1) * jitterRatio;
      ms = (ms * (1 + jitter)).clamp(0.0, cap.inMilliseconds.toDouble());
    }
    return Duration(milliseconds: ms.round());
  }

  /// 封顶后的稳态间隔（诊断页展示"约每 X 秒重试一次"用）。
  Duration steadyStateInterval() => cap;
}

double _defaultRandom() => 0.5;

/// `pow` 的防溢出版本：指数结果一旦超过 [stopAt] 就返回 stopAt。
double _pow(double base, double exp, double stopAt) {
  var v = 1.0;
  for (var i = 0; i < exp.toInt(); i++) {
    v *= base;
    if (v >= stopAt) return stopAt;
  }
  return v;
}

/// 界面提示分级：把"要不要打扰用户"这个决策从 UI 代码里抽出来集中判定。
enum TunnelAlertLevel {
  /// 完全静默：连接正常、或用户主动断开——界面保持原样，不加任何遮罩。
  silent,

  /// 忙碌：顶部非阻塞横幅显示"正在自动重连（第 N 次，X 秒后）"。
  /// **不出现红色、不出现异常原文**：绝大多数链路抖动止步于此、自愈收场。
  busy,

  /// 需要用户注意：持续失败，横幅带上故障结论与"立即重试"按钮。
  attention,

  /// 硬失败：配置类错误（密码/指纹/私钥/端口），横幅升级为明确指引 + 改设置入口。
  hard,
}

/// 提示策略。核心原则：**网络抖动只给非阻塞提示，配置错误立刻说清楚**。
///
/// 反面教材是旧实现：第一次连接失败就把异常原文 + VPN QoS 长文糊成红色全屏，
/// 而实际上 90% 的抖动在 1~2 次退避重试后就自愈了——用户看到的是噪音和恐慌。
class TunnelAlertPolicy {
  const TunnelAlertPolicy({
    this.attentionAfterAttempts = 3,
    this.attentionAfterAttemptsFirstEver = 2,
  });

  /// 曾成功连上过时，连续失败达到此次数才升级为"需要注意"。
  final int attentionAfterAttempts;

  /// 从未连上过（多半是地址/网络压根不对）时更早升级，避免用户干等。
  final int attentionAfterAttemptsFirstEver;

  TunnelAlertLevel levelFor({
    required int attempt,
    required TunnelFailureKind kind,
    required bool connectedBefore,
    bool networkAvailable = true,
  }) {
    // 配置类错误：第一次就说清楚，重试没有意义。
    if (isConfigurationFailure(kind)) return TunnelAlertLevel.hard;
    // 系统明确无网络：只说"网络不可用"，不描述 SSH 细节。
    if (!networkAvailable) return TunnelAlertLevel.busy;
    final escalateAt = connectedBefore
        ? attentionAfterAttempts
        : attentionAfterAttemptsFirstEver;
    // 链路类中断一律至少 busy：用户至少要知道"正在自动重连"，
    // 而不是对着一张不再更新的旧页面瞎猜要不要重启 App。
    return attempt < escalateAt
        ? TunnelAlertLevel.busy
        : TunnelAlertLevel.attention;
  }
}
