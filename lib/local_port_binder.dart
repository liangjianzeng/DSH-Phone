import 'dart:io';

import 'tunnel_policy.dart';

/// 本地转发端口的**绑定阶梯**。
///
/// 从 `TunnelService._bindLocalListener` 抽出来，只为一个目的：这套决策是
/// 「端口被占」这条路上唯一真正干活的东西，必须能在 `flutter test` 里用**真的
/// ServerSocket** 钉死，而不是只能上真机验证。上一版自愈逻辑的翻车点正在这儿——
/// 它只在"配置端口"上回收自家残骸（`s.port != port` 直接 continue），落在临时段
/// 里的孤儿永远没人管，于是每轮重建烧掉一个可借端口，烧满就是"重试也没用、只能
/// 杀进程"。代码看着没毛病，真机才露馅。现在把阶梯写死在这里、由测试用真端口占坑
/// 复现，回归就有了网。
///
/// 本文件刻意只依赖 `dart:io` 与 [tunnel_policy]：不引 Flutter、不引 dartssh2。
/// 一切"状态"（哪些监听是自家残骸、清扫该怎么做、是否同进程重拉起）都由调用方
/// 注入，测试因此能精确复现现场。
class LocalPortBinder {
  LocalPortBinder({
    required this.log,
    required this.onBound,
    required this.sweepOrphans,
    required this.releaseOwnedOn,
    required this.ownedHolds,
    required this.ensureRespawnChecked,
    required this.sameProcessRespawn,
    required this.candidates,
    Future<ServerSocket> Function(InternetAddress address, int port)? bind,
    Duration probeTimeout = const Duration(milliseconds: 400),
  })  : _bind = bind ?? ServerSocket.bind,
        _probeTimeout = probeTimeout;

  /// 事件（进连接诊断页）。`warn` = true 是"用户该知道"级别的。
  final void Function(String message, {required bool warn}) log;

  /// 每次成功绑定后回调：调用方据此登记"这是我们自己开的监听"，并记下本次实际
  /// 生效的是配置端口还是借来的临时端口。
  final void Function(ServerSocket server, int configPort) onBound;

  /// 关掉登记表里所有**不属于当前活动监听**的条目，返回清掉的个数。
  ///
  /// 主隧道同一时刻只该有一个活监听，所以表里除它以外的每一条都是被丢弃的残骸。
  /// 这一步是全量回收，也是修掉"临时段孤儿永不回收"那个坑的主闸。
  final Future<int> Function() sweepOrphans;

  /// 定向关掉仍占着 [port] 的自家残骸，返回是否动过手。
  final Future<bool> Function(int port) releaseOwnedOn;

  /// 登记表里此刻是否还有占着 [port] 的条目：用来区分"自家漏的"与"外部的"。
  final bool Function(int port) ownedHolds;

  /// 惰性做一次"同进程重拉起"判定（pid 自比对），见 [sameProcessRespawn]。
  final Future<void> Function() ensureRespawnChecked;

  /// 本进程此前已跑过一个拉起过隧道的 isolate → 绑不上的端口多半是自家僵尸 FD。
  final bool Function() sameProcessRespawn;

  /// 临时端口尝试顺序（首选段在前、段内打乱）。由调用方给，测试可注入定序。
  final List<int> Function() candidates;

  final Future<ServerSocket> Function(InternetAddress address, int port) _bind;

  final Duration _probeTimeout;

  /// 「本进程已经占着这个端口」的标志性文案（Dart 自己拦的，不是内核 errno）。
  static const String _sharedFlagSignature = 'shared flag to bind';

  static String _text(SocketException e) =>
      '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();

  /// 是否"这个端口对我们不可用"——该记进 `tried` 并继续试下一个候选。
  ///
  /// **两种形态都必须认，缺一个就会把最常见的那种整个漏掉**（真机实测，dart 3.7）：
  ///
  /// | 占用者 | `osError.errorCode` | `osError.message` |
  /// |---|---|---|
  /// | 另一个**进程**（真·第三方 App） | 98 `EADDRINUSE`（macOS 48） | `Address already in use` |
  /// | **本进程**占着：自家没 close 的残骸、别的 isolate、**已死 isolate 留下的僵尸 FD** | **-1** | `The shared flag to bind() needs to be `true` if binding multiple times on the same (address, port) combination.` |
  ///
  /// 上一版只认第一种（`code == 98 || 48`，且只翻 `e.message` 不翻
  /// `e.osError.message`）。于是"自己占自己"这个**最常见**的场景在第一次绑定就
  /// `rethrow`：临时端口池一个都没试过，界面上却写着"临时端口段也已用满"——那句
  /// 是假的（裸 SocketException 被 `classifyTunnelFailure` 按 `bind` 关键词归成了
  /// localPort，直接套用同一句文案）。用户看到的"第 1 次尝试、也没有 N 秒后重试"
  /// 就是这么来的。
  static bool isPortUnavailableToUs(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == 98 || code == 48 /* macOS EADDRINUSE */) return true;
    final text = _text(e);
    return text.contains('already in use') ||
        text.contains('already bound') ||
        text.contains(_sharedFlagSignature);
  }

  /// 这次失败是不是"**本进程**占着端口"（shared-flag 形态）。
  ///
  /// 它是比 pid 自比对更硬的证据：Dart 只有在自己的绑定表里查到占用者时才报这条，
  /// 所以它等价于"占用者就在本进程里"。若此时自家登记表又没有这个端口，那它就是
  /// **上一个 isolate 留下的僵尸监听**——Dart 侧永远关不掉，只有进程重开才收得回来。
  static bool isOccupiedByOurOwnProcess(SocketException e) =>
      _text(e).contains(_sharedFlagSignature);

  /// 走完整条阶梯，返回可用的监听。
  ///
  /// 五步，顺序不能换（每一步都对应一种真实翻车过的现场）：
  ///  1. **全量清扫**自家残骸后绑配置端口。绝大多数"端口被占"是自己人没释放，
  ///     此时提示用户"关闭其它程序"是误导。
  ///  2. 仍被占 → 定向回收该端口上的残骸 + 再清扫一次，重试一次（并发尝试可能
  ///     刚好在让路期间又漏下一个）。
  ///  3. 让路给临时池：**每个候选先回收自家残骸再绑**。少了这一步，临时段里的
  ///     孤儿就永远没人管——上一版正是这样把可借端口一个个烧光的。
  ///  4. 两种"端口被占"的形态都算数（见 [isPortUnavailableToUs] 的实测对照表）：
  ///     内核 `EADDRINUSE` = 别的进程占着；Dart 的 `shared flag to bind()` =
  ///     **本进程**占着。其它 bind 异常原样上抛（权限、地址族之类不是端口占用，
  ///     把它判成 localPort 会把用户骗去杀进程）。
  ///  5. 整池皆满 → 抛 [TunnelLocalPortOccupiedException]，带**试过的端口**与
  ///     "是否疑似自家僵尸 FD"的判断：前者回应用户"你到底随机试了没有"，后者
  ///     决定界面把「重启应用」还是"改设置"摆成主行动。
  Future<ServerSocket> bindListener(int configPort) async {
    final tried = <int>[];
    /// 本进程占着、却不在自家登记表里的端口 = **上一个 isolate 留下的僵尸监听**
    /// （Android 回前台常见：进程没死、isolate 换了一个，老 isolate 没 close 的
    /// `ServerSocket` 会一直占着端口直到整个进程退出）。
    final zombiePorts = <int>[];
    /// 被**别的进程**占着的端口（真·第三方 App）——处置方式完全不同：那种该让用户
    /// 去设置里换端口，而不是重启应用。
    final externalPorts = <int>[];

    Future<ServerSocket?> tryBind(int p) async {
      try {
        final server = await _bind(InternetAddress.loopbackIPv4, p);
        onBound(server, configPort);
        return server;
      } on SocketException catch (e) {
        // 第 4 步：只有"这个端口没了"才继续往下试。权限、地址族之类的失败原样上抛
        // ——把它判成 localPort 会把用户骗去杀进程 / 换端口，全是错方向。
        if (!isPortUnavailableToUs(e)) rethrow;
        tried.add(p);
        // 按**错误形态**分家：shared-flag = 占用者就在本进程（自家残骸或僵尸 FD），
        // EADDRINUSE = 别人家的进程。上一版只认 EADDRINUSE，于是自家占用直接
        // rethrow、临时端口池一个都没试。
        if (isOccupiedByOurOwnProcess(e)) {
          if (!ownedHolds(p)) zombiePorts.add(p);
        } else {
          externalPorts.add(p);
        }
        return null;
      }
    }

    // 1) 先归位自己人，再谈现实。
    final swept = await sweepOrphans();
    if (swept > 0) {
      log('清扫了 $swept 个不属于当前隧道的遗留监听（含临时段）', warn: true);
    }
    final direct = await tryBind(configPort);
    if (direct != null) return direct;

    // 2) 再怀疑一次自己人：定向回收 + 全量清扫，然后重试一次。
    final released = await releaseOwnedOn(configPort);
    final sweptAgain = await sweepOrphans();
    if (released || sweptAgain > 0) {
      log('回收了 :$configPort 上的自家残留（定向 $released、全量 $sweptAgain），重试绑定',
          warn: true);
      final again = await tryBind(configPort);
      if (again != null) return again;
    }

    // 3) 让路：扫遍整个保留池。
    final holder = await _describeHolder(configPort);
    await ensureRespawnChecked();
    for (final candidate in candidates()) {
      if (await releaseOwnedOn(candidate)) {
        log('候选 :$candidate 正被自家残骸占着，已回收后重试', warn: true);
      }
      final borrowed = await tryBind(candidate);
      if (borrowed != null) {
        log(
            '本地端口 $configPort 被占用（$holder），本次改用临时端口 '
            '127.0.0.1:${borrowed.port}（保留池 $tunnelFallbackPoolMin-'
            '$tunnelFallbackPoolMax，功能不受影响；建议在设置里永久换个端口）',
            warn: true);
        return borrowed;
      }
    }

    // 5) 整池皆满。把"到底试过了什么"如实带上，别再让用户猜。
    // 判据以**错误形态**为准（比 pid 自比对硬得多）：shared-flag 只在"本进程已经
    // 绑过这个端口"时出现，而登记表又没有它 —— 那就只能是上一个 isolate 留下的
    // 僵尸监听，Dart 侧关不掉，唯一出路是让进程重开。
    final zombie = zombiePorts.isNotEmpty;
    final verdict = zombie
        ? '判定为自家上一世代 isolate 的僵尸监听（Dart 侧关不掉，界面给「重启应用」）'
        : externalPorts.isNotEmpty
            ? '判定为其它进程占用（内核 EADDRINUSE，在设置里换个本地端口即可）'
            : '占用者不明（既非 shared-flag 也非 EADDRINUSE），按外部占用处理';
    log(
        '本地端口 $configPort 与保留池 $tunnelFallbackPoolMin-$tunnelFallbackPoolMax '
        '全部绑定失败：共试过 ${tried.length} 个'
        '（${tried.isEmpty ? '无' : tried.join(',')}）；'
        '本进程内未登记占用 ${zombiePorts.isEmpty ? '无' : zombiePorts.join(',')}、'
        '外部进程占用 ${externalPorts.isEmpty ? '无' : externalPorts.join(',')}；'
        '同进程重拉起=${sameProcessRespawn()} → $verdict',
        warn: true);
    throw TunnelLocalPortOccupiedException(
      configPort,
      holder,
      tried: List<int>.unmodifiable(tried),
      selfZombieSuspected: zombie,
      occupiedBySelf: List<int>.unmodifiable(zombiePorts),
      occupiedByOthers: List<int>.unmodifiable(externalPorts),
    );
  }

  /// 谁占着这个端口？Android 无 root 拿不到进程表，只能做**可连通性探测**：
  /// 能连上 = 有程序正在监听（残留隧道或第三方 App）；连不上 = 内核侧残留/半关。
  Future<String> _describeHolder(int port) async {
    try {
      final probe = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: _probeTimeout);
      await probe.close().catchError((_) {});
      try {
        probe.destroy();
      } catch (_) {}
      return '有程序正在监听，且能接受连接';
    } catch (_) {
      return '无进程应答（端口处于内核残留或半关状态）';
    }
  }
}
