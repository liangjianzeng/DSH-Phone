import 'dart:io';

import 'package:dsh_phone/local_port_binder.dart';
import 'package:dsh_phone/tunnel_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地端口绑定阶梯的回归测试。
///
/// 为什么值得单独钉一组：`localPort` 这条路上唯一真正干活的就是这条阶梯，而它已经
/// 用"代码看着完全合理、纯策略测试全绿、真机才炸"的方式翻过**两次**车：
///
///  1. 回收残骸写成 `if (s.port != port) continue` —— 只在**配置端口**上回收，
///     落在临时段里的自家孤儿永远没人管，每轮重建烧掉一个可借端口。
///  2. 占用判定只认 `EADDRINUSE` —— 可 Dart 对"本进程已经占着的端口"报的是
///     **另一套错误**（`osError.errorCode = -1` + `shared flag to bind()`，实测
///     见下），于是最常见的"自己占自己"在**第一次绑定就 rethrow**：临时端口池一个
///     都没试，界面却按 localPort 显示"临时端口段（3090-3099）也已用满"——那句是
///     假的。用户因此"重试也没用、只能杀进程"。
///
/// 所以这里既用**真的 ServerSocket**（复现 shared-flag 形态），也用**注入的异常**
/// （复现真·外部进程的 EADDRINUSE 形态，测试进程内部无法造出这个），两条形态都钉。
void main() {
  late _Registry registry;
  final inProcessHolders = <ServerSocket>[];
  late List<int> bindLog;

  setUp(() {
    registry = _Registry();
    inProcessHolders.clear();
    bindLog = [];
  });

  tearDown(() async {
    for (final s in [...inProcessHolders, ...registry.owned]) {
      try {
        await s.close();
      } catch (_) {}
    }
    inProcessHolders.clear();
    registry.owned.clear();
  });

  /// 真 bind 一个端口**但不进登记表**：模拟"占着它的东西不归本 isolate 管"
  /// （第三方 App，或已死 isolate 的僵尸 FD）。同进程内这样占，Dart 报的就是
  /// shared-flag 形态——正好是真机上最常见、也最容易被误判成"别的程序占用"的那种。
  Future<ServerSocket> holdUnregistered(int port) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    inProcessHolders.add(s);
    return s;
  }

  /// 真 bind 并**登记**：模拟自家漏关的残骸（清扫本该把它收掉）。
  Future<ServerSocket> holdAsOurOrphan(int port) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    registry.owned.add(s);
    return s;
  }

  LocalPortBinder makeBinder({
    required List<int> Function() candidates,
    bool sameProcessRespawn = false,
    Future<ServerSocket> Function(InternetAddress, int)? bind,
  }) {
    return LocalPortBinder(
      log: (_, {required bool warn}) {},
      onBound: (server, configPort) => registry.owned.add(server),
      sweepOrphans: registry.sweep,
      releaseOwnedOn: (port) async {
        if (registry.disableReclaim) return false; // 复现翻车姿势 1
        var touched = false;
        for (final s in registry.owned.toList(growable: false)) {
          if (s.port != port) continue;
          touched = true;
          registry.owned.remove(s);
          await s.close();
        }
        return touched;
      },
      ownedHolds: registry.holds,
      ensureRespawnChecked: () async {},
      sameProcessRespawn: () => sameProcessRespawn,
      candidates: candidates,
      bind: (address, port) async {
        bindLog.add(port);
        if (bind != null) return bind(address, port);
        return ServerSocket.bind(address, port);
      },
    );
  }

  /// 真·外部进程占用时长这样（用子进程占端口实测抄下来的字段）。
  SocketException eaddrInUse(int port) => SocketException(
        'Failed to create server socket',
        osError: const OSError('Address already in use', 98),
        address: InternetAddress.loopbackIPv4,
        port: port,
      );

  /// 自家进程（含已死 isolate 的僵尸 FD）占用时长这样 —— 上一版把它当成
  /// "不是端口占用"直接 rethrow，于是阶梯在第一步就整体抛出。
  SocketException sharedFlag(int port) => SocketException(
        'Failed to create server socket',
        osError: const OSError(
            'The shared flag to bind() needs to be `true` if binding multiple '
            'times on the same (address, port) combination.',
            -1),
        address: InternetAddress.loopbackIPv4,
        port: port,
      );

  Future<Object?> runBinder(
          LocalPortBinder binder, int port) =>
      binder.bindListener(port).then<Object?>((_) => null).catchError((Object e) => e);

  group('占用形态判定（翻车姿势 2 的核心）', () {
    test('EADDRINUSE 与 shared-flag **两种形态都算"端口没了"**', () {
      expect(LocalPortBinder.isPortUnavailableToUs(eaddrInUse(3081)), isTrue);
      expect(LocalPortBinder.isPortUnavailableToUs(sharedFlag(3081)), isTrue,
          reason: '漏了这一条，"自己占自己"就永远走不到临时端口那一步');
      // 老的字符串判定看不到 osError.message，正是它把 shared-flag 判成"不是占用"
      expect(sharedFlag(3081).message.toLowerCase(), isNot(contains('in use')));

      // 权限类失败不是端口占用：判成 localPort 会把用户骗去杀进程 / 换端口。
      final denied = SocketException('Failed to create server socket',
          osError: const OSError('Permission denied', 13));
      expect(LocalPortBinder.isPortUnavailableToUs(denied), isFalse);
    });

    test('shared-flag 形态必须**继续试下一个候选**，不许在第一步 rethrow',
        () async {
      final port = await _freePort();
      final binder = makeBinder(
        candidates: () => [tunnelFallbackPoolMin],
        bind: (address, p) {
          if (p == port) throw sharedFlag(p); // 本进程占着配置端口
          return ServerSocket.bind(address, p);
        },
      );

      final result = await binder.bindListener(port);

      expect(bindLog, [port, tunnelFallbackPoolMin],
          reason: '这正是用户怀疑"你根本没随机重试"的那一步：必须真的试下去');
      expect(result.port, tunnelFallbackPoolMin);
      await result.close();
    });

    test('EADDRINUSE 形态同样继续试，且不算自家僵尸', () async {
      final port = await _freePort();
      final binder = makeBinder(
        candidates: () => [tunnelFallbackPoolMin],
        bind: (address, p) {
          if (p == port) throw eaddrInUse(p);
          return ServerSocket.bind(address, p);
        },
      );

      final result = await binder.bindListener(port);
      expect(result.port, tunnelFallbackPoolMin);
      await result.close();
    });

    test('非占用类 bind 异常原样上抛（不许冒充端口占用）', () async {
      final port = await _freePort();
      final binder = makeBinder(
        candidates: () => [tunnelFallbackPoolMin],
        bind: (address, p) async {
          throw SocketException('Failed to create server socket',
              osError: const OSError('Permission denied', 13));
        },
      );
      await expectLater(
        binder.bindListener(port),
        throwsA(isA<SocketException>()
            .having((e) => e.osError?.errorCode, 'errorCode', 13)),
      );
      expect(bindLog, [port], reason: '第一个端口就失败，不该继续扫池子');
    });
  });

  group('绑定阶梯（真 ServerSocket）', () {
    test('配置端口空着就直接绑上，一个临时端口都不碰', () async {
      final port = await _freePort();
      final server =
          await makeBinder(candidates: () => [3090, 3091]).bindListener(port);

      expect(server.port, port);
      expect(bindLog, [port],
          reason: '不该浪费候选端口，更不该无声无息把入口换到别的端口上');
      await server.close();
    });

    test('配置端口被**自家残骸**占住 → 清扫后原地复活，根本不借临时端口',
        () async {
      final port = await _freePort();
      await holdAsOurOrphan(port); // 上一轮 teardown 没关干净的监听

      final server =
          await makeBinder(candidates: () => [3090]).bindListener(port);

      expect(server.port, port,
          reason: '是自己人占的就该原地解决；这时提示用户"关闭其它程序"是误导');
      expect(registry.swept, greaterThanOrEqualTo(1));
      await server.close();
    });

    test('候选端口被自家残骸占住 → **先回收再绑**（翻车姿势 1）', () async {
      final port = await _freePort();
      const candidate = tunnelFallbackPortMin; // 3090
      await holdUnregistered(port); // 配置端口：外部/僵尸，让路
      await holdAsOurOrphan(candidate); // 上一轮借走没还的临时端口

      final server =
          await makeBinder(candidates: () => [candidate]).bindListener(port);

      expect(server.port, candidate,
          reason: '自家残骸就该被回收后复用，而不是当成"这个端口没了"跳过');
      expect(registry.owned.where((s) => s.port == candidate).length, 1,
          reason: '同一个端口上只该剩下新绑的那个监听 = 孤儿确实被关掉了');
      await server.close();
    });

    test('回归保护：少了"候选也回收"这一步，自家孤儿端口就是永久烧掉', () async {
      final port = await _freePort();
      const candidate = tunnelFallbackPortMin;
      await holdUnregistered(port);
      final orphan = await holdAsOurOrphan(candidate);
      registry.disableReclaim = true; // 复现：只按配置端口回收，临时段没人管

      final caught = await runBinder(
          makeBinder(candidates: () => [candidate]), port)
          as TunnelLocalPortOccupiedException;
      expect(caught.tried, [port, candidate],
          reason: '两个端口都真的试过了（这条列表就是"确实随机重试过"的证据）');
      expect(orphan.port, candidate, reason: '孤儿还活着：端口确实没被释放');
      registry.disableReclaim = false;
    });

    test('整池被占 → 试过配置端口 + 全部候选，一个都不能少', () async {
      final port = await _freePort();
      final pool = List<int>.generate(6, (i) => tunnelFallbackPoolMin + i);
      await holdUnregistered(port);
      for (final p in pool) {
        await holdUnregistered(p);
      }

      final caught = await runBinder(
          makeBinder(candidates: () => pool), port)
          as TunnelLocalPortOccupiedException;
      expect(caught.tried, [port, ...pool]);
      expect(bindLog, [port, ...pool]);
      expect(caught.holder, isNotEmpty);
      expect('$caught', contains('$port'));
      expect('$caught', contains('${pool.length + 1} 个'));
    });
  });

  group('自家僵尸 vs 第三方 App（决定界面主按钮是哪一个）', () {
    test('本进程占着且不在登记表 → 判成自家僵尸，界面给「重启应用」', () async {
      final port = await _freePort();
      const candidate = tunnelFallbackPoolMin;
      await holdUnregistered(port); // 真机现场：上一世代 isolate 的僵尸监听
      await holdUnregistered(candidate);

      final caught = await runBinder(
          makeBinder(candidates: () => [candidate], sameProcessRespawn: false),
          port) as TunnelLocalPortOccupiedException;

      expect(caught.selfZombieSuspected, isTrue,
          reason: 'shared-flag 形态本身就证明占用者在本进程里，'
              '不需要 pid 旁证也该给「重启应用」');
      expect(caught.occupiedBySelf, [port, candidate]);
      expect(caught.occupiedByOthers, isEmpty);
      expect('$caught', contains('需重启应用'));
    });

    test('全是内核 EADDRINUSE → 判成外部 App，让用户去改设置', () async {
      final port = await _freePort();
      const candidate = tunnelFallbackPoolMin;
      final binder = makeBinder(
        candidates: () => [candidate],
        sameProcessRespawn: true, // 即便是同进程重拉起，形态是 EADDRINUSE 就不该甩锅自家
        bind: (address, p) async =>
            throw eaddrInUse(p),
      );

      final caught = await runBinder(binder, port) as TunnelLocalPortOccupiedException;
      expect(caught.selfZombieSuspected, isFalse);
      expect(caught.occupiedByOthers, [port, candidate]);
      expect(caught.occupiedBySelf, isEmpty);
    });
  });
}

/// 取一个当下空闲的端口当"配置端口"，避免与本机真实服务撞车。
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// 本 isolate 的"自家监听登记表"替身（对齐 `TunnelService._ownedListeners` 语义）。
class _Registry {
  final List<ServerSocket> owned = [];
  int swept = 0;

  /// true = 清扫与定向回收都变空操作，用来复现"临时段孤儿没人回收"那次翻车。
  bool disableReclaim = false;

  Future<int> sweep() async {
    if (disableReclaim) return 0;
    var n = 0;
    for (final s in owned.toList(growable: false)) {
      owned.remove(s);
      try {
        await s.close();
        n++;
      } catch (_) {}
    }
    swept += n;
    return n;
  }

  bool holds(int port) => owned.any((s) => s.port == port);
}
