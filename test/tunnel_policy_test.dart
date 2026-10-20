import 'package:dsh_phone/tunnel_diagnostics.dart';
import 'package:dsh_phone/tunnel_policy.dart';
import 'package:dsh_phone/tunnel_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 隧道稳定性策略的回归测试。
///
/// 这些决策（什么时候重试、多久重试一次、什么时候才允许打扰用户）是本次
/// 「VPN/SSH 频繁断开 + 频繁误报」专项整改的大脑。它们必须可测：真机上
/// "挂一晚看它会不会自己活过来"不是验证，是许愿。
void main() {
  group('故障分类 classifyTunnelFailure', () {
    test('Tailscale 未就绪时的 DNS 失败要单独识别（不能并进 unknown）', () {
      expect(
        classifyTunnelFailure(
            _err('Failed host lookup: nas.tailnet.ts.net')),
        TunnelFailureKind.dns,
      );
    });

    test('链路不可达 / 连接被拒 分开：一个该重试，一个该提示配置', () {
      expect(classifyTunnelFailure(_err('Network is unreachable')),
          TunnelFailureKind.unreachable);
      expect(classifyTunnelFailure(_err('Connection refused')),
          TunnelFailureKind.refused);
      expect(classifyTunnelFailure(_err('Connection reset by peer')),
          TunnelFailureKind.unreachable);
    });

    test('认证 / 主机密钥 / 私钥 属于配置类，重试不会自己变好', () {
      expect(classifyTunnelFailure(_err('SSHAuthFailError(Unable to authenticate)')),
          TunnelFailureKind.auth);
      expect(classifyTunnelFailure(_err('SSHHostkeyError(Hostkey verification failed)')),
          TunnelFailureKind.hostKey);
      expect(classifyTunnelFailure(_err('SSHKeyDecodeError(Invalid PEM, bad passphrase)')),
          TunnelFailureKind.keyDecode);
      expect(isConfigurationFailure(TunnelFailureKind.auth), isTrue);
      expect(isConfigurationFailure(TunnelFailureKind.hostKey), isTrue);
      expect(isConfigurationFailure(TunnelFailureKind.unreachable), isFalse);
      expect(isConfigurationFailure(TunnelFailureKind.dns), isFalse);
    });

    test('探活失败单独归类为远端服务未应答', () {
      expect(
        classifyTunnelFailure(_err('whatever'), probeFailed: true),
        TunnelFailureKind.remoteDown,
      );
    });

    test('本地端口被占用', () {
      expect(
        classifyTunnelFailure(_err('SocketException: Already bound')),
        TunnelFailureKind.localPort,
      );
    });

    test('认证前的传输层关闭是链路死亡，不是"密码错了"（防误判回归）', () {
      // dartssh2 `_handleTransportClosed` 用的就是这个文案；判成 auth 会在每次
      // 闪断时弹红色"检查用户名密码"，把用户引到完全错误的方向。
      final e = _err('Connection closed before authentication',
          prefix: 'SSHAuthAbortError');
      expect(classifyTunnelFailure(e), TunnelFailureKind.unreachable);
      expect(isConfigurationFailure(classifyTunnelFailure(e)), isFalse);
    });

    test('真正的凭据被拒才判 auth', () {
      expect(
        classifyTunnelFailure(
            _err('Unable to authenticate', prefix: 'SSHAuthFailError')),
        TunnelFailureKind.auth,
      );
      expect(
        classifyTunnelFailure(_err('No supported authentication methods left')),
        TunnelFailureKind.auth,
      );
    });

    test('库内"已关闭"类错误归为链路问题（继续自动重试）', () {
      expect(
        classifyTunnelFailure(
            _err('Transport is closed', prefix: 'SSHStateError')),
        TunnelFailureKind.unreachable,
      );
      expect(
        classifyTunnelFailure(
            _err('SocketException: Connection reset by peer',
                prefix: 'SSHSocketError')),
        TunnelFailureKind.unreachable,
      );
      expect(
        classifyTunnelFailure(
            _err('connect failed', prefix: 'SSHChannelOpenError')),
        TunnelFailureKind.unreachable,
      );
    });
  });

  group('重连退避 TunnelBackoff', () {
    const backoff = TunnelBackoff(
      first: Duration(milliseconds: 800),
      cap: Duration(seconds: 60),
      jitterRatio: 0.25,
    );

    test('单调递增且封顶在 cap —— 永不放弃、也永不越界', () {
      Duration? prev;
      for (var attempt = 1; attempt <= 30; attempt++) {
        final d = backoff.delayFor(attempt, random: () => 0.5);
        expect(d.inMilliseconds, lessThanOrEqualTo(60000));
        expect(d.inMilliseconds, greaterThan(0));
        if (prev != null) {
          expect(d >= prev, isTrue, reason: 'attempt=$attempt 出现倒退');
        }
        prev = d;
      }
      // 封顶后仍然在重试（历史 bug：第 6 次之后根本没有定时器）
      expect(backoff.delayFor(999, random: () => 0.5),
          const Duration(seconds: 60));
    });

    test('抖动限制在 ±jitterRatio 内，避免与 VPN 重拨同频', () {
      for (final r in [0.0, 0.25, 0.5, 0.75, 0.9999]) {
        final d = backoff.delayFor(3, random: () => r);
        final base = backoff.delayFor(3, random: () => 0.5).inMilliseconds;
        expect(d.inMilliseconds,
            inInclusiveRange((base * 0.75).round(), (base * 1.25).round()));
      }
    });

    test('首次重试要快（亚秒级）——用户点"立即重试"后不该等好几秒', () {
      final d = backoff.delayFor(1, random: () => 0.5);
      expect(d.inMilliseconds, lessThanOrEqualTo(1200));
    });
  });

  group('提示分级 TunnelAlertPolicy（降噪的核心）', () {
    const policy = TunnelAlertPolicy();

    test('配置类错误第一次就是 hard：必须立刻告诉用户去改设置', () {
      expect(
        policy.levelFor(
            attempt: 1,
            kind: TunnelFailureKind.auth,
            connectedBefore: true),
        TunnelAlertLevel.hard,
      );
    });

    test('链路抖动前几次只 busy，不升级成红色注意', () {
      for (final attempt in [0, 1, 2]) {
        expect(
          policy.levelFor(
              attempt: attempt,
              kind: TunnelFailureKind.unreachable,
              connectedBefore: true),
          TunnelAlertLevel.busy,
          reason: 'attempt=$attempt 应保持非阻塞',
        );
      }
      expect(
        policy.levelFor(
            attempt: 3,
            kind: TunnelFailureKind.unreachable,
            connectedBefore: true),
        TunnelAlertLevel.attention,
      );
    });

    test('从未连上过时更早升级（多半是地址/网络压根不对）', () {
      expect(
        policy.levelFor(
            attempt: 2,
            kind: TunnelFailureKind.dns,
            connectedBefore: false),
        TunnelAlertLevel.attention,
      );
    });

    test('无网络时只 busy：不该把"没网"渲染成 SSH 故障', () {
      expect(
        policy.levelFor(
            attempt: 9,
            kind: TunnelFailureKind.unknown,
            connectedBefore: true,
            networkAvailable: false),
        TunnelAlertLevel.busy,
      );
    });
  });

  group('TunnelState 文案与分级（界面唯一依据）', () {
    test('自称 connected 但探活失败 = 非阻塞 busy，且不能显示"连接正常"', () {
      const s = TunnelState(
        status: TunnelStatus.connected,
        probeOk: false,
        kind: TunnelFailureKind.none,
      );
      expect(s.healthy, isFalse);
      expect(s.alertLevel, TunnelAlertLevel.busy);
      expect(s.userMessage, contains('检测'));
    });

    test('云端服务没起要说"云端服务没有应答"，而不是含糊的"网络波动"', () {
      const s = TunnelState(
        status: TunnelStatus.connected,
        probeOk: false,
        kind: TunnelFailureKind.remoteDown,
      );
      expect(s.userMessage, contains('云端服务'));
    });

    test('断开且已排定重试时，文案要带上"正在自动重试 + 第几次"', () {
      const s = TunnelState(
        status: TunnelStatus.disconnected,
        kind: TunnelFailureKind.unreachable,
        attempt: 3,
        nextRetryAt: null,
        connectedSince: null,
      );
      expect(s.retryScheduled, isFalse);
      final withRetry = s.copyWith(nextRetryAt: DateTime.now());
      expect(withRetry.userMessage, contains('正在自动重试'));
      expect(withRetry.userMessage, contains('第 4 次'));
    });

    test('everConnected 决定升级节奏（连上过=抖动，没连上=压根不对）', () {
      const transient = TunnelFailureKind.unreachable;
      final dropped = TunnelState(
        status: TunnelStatus.disconnected,
        kind: transient,
        attempt: 2,
        everConnected: true,
      );
      final never = dropped.copyWith(everConnected: false);
      expect(dropped.alertLevel, TunnelAlertLevel.busy,
          reason: '连上过又断，第 2 次仍该是低调横幅');
      expect(never.alertLevel, TunnelAlertLevel.attention,
          reason: '从未连上过，第 2 次就该提示用户检查配置');
    });

    test('健康态是 silent：不加任何遮罩', () {
      const s = TunnelState(
          status: TunnelStatus.connected, probeOk: true, attempt: 0);
      expect(s.healthy, isTrue);
      expect(s.alertLevel, TunnelAlertLevel.silent);
    });
  });

  group('本地端口被占（真机：重试一万次也没用）', () {
    test('端口占用异常分类为 localPort，结论给的是可执行动作', () {
      const e = TunnelLocalPortOccupiedException(3081, '有程序正在监听，且能接受连接');
      expect(classifyTunnelFailure(e), TunnelFailureKind.localPort);
      final summary = tunnelFailureSummary(TunnelFailureKind.localPort);
      // 不能只说"请关闭其它占用的程序"——手机上根本看不到是谁，得给出能做的动作
      expect(summary, contains('换一个本地端口'));
      expect(summary, contains('立即重试'));
      expect('$e', contains('3081'));
      expect('$e', contains('有程序正在监听'));
    });

    test('端口占用属于"重试也不会好"，其它故障仍要永不放弃', () {
      expect(isFutileRetryFailure(TunnelFailureKind.localPort), isTrue);
      // 网络类必须继续退避重试：它们真的会因为重试而变好
      expect(isFutileRetryFailure(TunnelFailureKind.timeout), isFalse);
      expect(isFutileRetryFailure(TunnelFailureKind.unreachable), isFalse);
      expect(isFutileRetryFailure(TunnelFailureKind.dns), isFalse);
      expect(isFutileRetryFailure(TunnelFailureKind.unknown), isFalse);
    });

    test('普通 bind 冲突文案仍被认成 localPort（回归保护）', () {
      expect(
          classifyTunnelFailure(_err('Failed to bind (OS Error: Address already '
              'in use, errno = 98, address = 127.0.0.1, port = 3081)')),
          TunnelFailureKind.localPort);
    });
  });

  group('诊断事件环形缓冲', () {
    test('超出容量丢最旧，导出文本含标签与时间', () {
      var now = DateTime(2026, 10, 8, 9, 0, 0);
      final diag = TunnelDiagnostics.forTest(
        3,
        () => now,
      );
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(seconds: 1));
        diag.info('probe', 'event-$i');
      }
      expect(diag.total, 3);
      expect(diag.events.first.message, 'event-2');
      expect(diag.events.last.message, 'event-4');
      final text = diag.exportText(header: 'HEADER');
      expect(text, contains('HEADER'));
      expect(text, contains('I/probe event-4'));
    });

    test('warn/error 计数用于"只看告警"过滤', () {
      final diag = TunnelDiagnostics.forTest(10, () => DateTime(2026));
      diag.info('connect', 'ok');
      diag.warn('probe', 'no answer');
      diag.error('connect', 'boom');
      expect(
        diag.countWhere((e) => e.level != TunnelEventLevel.info),
        2,
      );
    });
  });
}

/// 异常桩：策略层只依赖 `toString()` 判定类别，所以不必真的 throw。
/// 前缀默认 `SocketException`，与 dart:io 的文案同形（分类规则就是照着它写的）。
Object _err(String message, {String prefix = 'SocketException'}) =>
    _Err(prefix, message);

class _Err {
  const _Err(this.prefix, this.message);
  final String prefix;
  final String message;
  @override
  String toString() => '$prefix: $message';
}
