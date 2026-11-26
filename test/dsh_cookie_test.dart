import 'package:dsh_phone/dsh_cookie.dart';
import 'package:flutter_test/flutter_test.dart';

/// DSH 登录 cookie 的端口归属计算。
///
/// 期望值不是手算的：`node -e 'createHash("sha256").update("127.0.0.1:<端口>").digest()'`
/// 走 DSH 自己的 `cookieName()` 口径（unpadded base64url）打印出来的，见
/// `tool/dsh_cookie_port_scoping.mjs`。**DSH 改了 cookie 名算法，这组必须一起改**，
/// 否则 App 侧的"按 cookie 名找回端口"会静默失效（找不到匹配 → 永远不去搬端口）。
void main() {
  group('dshAuthCookieName（DSH cookieName 的 Dart 复刻）', () {
    test('unpadded base64url(sha256(authority))，与 DSH 侧逐字节一致', () {
      expect(dshAuthCookieName('127.0.0.1:3080'),
          'dsh-auth-VPhEEcLKeqRDBoBalzN2Nm7CnfxKhLE00pKIDWxt1sw');
      expect(dshAuthCookieName('127.0.0.1:3081'),
          'dsh-auth-w3iJaA6qw3qDSBs2Itl-h4S-Y-ZeYCC-N_iZO-eI_qw');
      expect(dshAuthCookieName('127.0.0.1:3094'),
          'dsh-auth-SY6m8WG1_3FZ2Qow4h1LKipz5xOUbkDL4FHTyAco3AY');
    });

    test('端口不同名字必不同（"换端口 = cookie 作废"的根），且不含 base64 填充', () {
      final a = dshAuthCookieName('127.0.0.1:3094');
      final b = dshAuthCookieName('127.0.0.1:3095');
      expect(a, isNot(b));
      expect(a, isNot(contains('=')));
      // URL 安全字母表：DSH 用 -_ 不用 +/，jar 里读回来的名字也是这个形态。
      expect(a, isNot(anyOf(contains('+'), contains('/'))));
    });

    test('host 也参与哈希：localhost 与 127.0.0.1 是两颗不同 cookie', () {
      expect(dshAuthCookieName('localhost:3081'),
          isNot(dshAuthCookieName('127.0.0.1:3081')));
    });
  });

  group('findAuthorizedPort（从 jar 里的 cookie 名反查该搬回哪个端口）', () {
    test('jar 里只有配置端口的 cookie → 命中配置端口', () {
      expect(
        findAuthorizedPort([
          'dsh-session',
          dshAuthCookieName('127.0.0.1:3081'),
        ], host: '127.0.0.1', candidatePorts: [3081, 3094, 3090]),
        3081,
      );
    });

    test('漂到临时端口后照样认出"活 cookie 在 3081"（本次线上现场）', () {
      // 现场：配置端口 3081 被上一世代 isolate 占着 → 本次借了 3094 → 主文档 401。
      // jar 里那颗 cookie 的名字是当年在 3081 签发的，浏览器照样把它发到 3094。
      final jar = [dshAuthCookieName('127.0.0.1:3081')];
      final pool = List.generate(60, (i) => 3090 + i);
      expect(
        findAuthorizedPort(jar,
            host: '127.0.0.1', candidatePorts: [3081, 3094, ...pool]),
        3081,
      );
      // 契约：调用方必须把**配置端口**放进候选。只喂"当前端口 + 保留池"就永远认不出来
      // （cookie 恰恰签在配置端口上）——这条写死，免得以后有人图省事把候选缩成保留池。
      expect(
        findAuthorizedPort(jar, host: '127.0.0.1', candidatePorts: [3094, ...pool]),
        isNull,
      );
    });

    test('多颗历史 cookie 同时在 jar 里时，取候选列表里排前面的（可信优先）', () {
      final jar = [
        dshAuthCookieName('127.0.0.1:3123'),
        dshAuthCookieName('127.0.0.1:3081'),
      ];
      expect(
        findAuthorizedPort(jar, host: '127.0.0.1', candidatePorts: [3081, 3123]),
        3081,
      );
      expect(
        findAuthorizedPort(jar, host: '127.0.0.1', candidatePorts: [3123, 3081]),
        3123,
      );
    });

    test('jar 里没有 DSH 鉴权 cookie / 端口都不在候选里 → null（别瞎搬）', () {
      expect(
        findAuthorizedPort(['dsh-session', 'csrf'],
            host: '127.0.0.1', candidatePorts: [3081, 3094]),
        isNull,
      );
      // 名字是别的 host 签的：不能因为端口对得上就认。
      expect(
        findAuthorizedPort([dshAuthCookieName('localhost:3081')],
            host: '127.0.0.1', candidatePorts: [3081]),
        isNull,
      );
      // 非法端口不参与比对。
      expect(
        findAuthorizedPort([dshAuthCookieName('127.0.0.1:0')],
            host: '127.0.0.1', candidatePorts: [0, -1, 70000]),
        isNull,
      );
    });
  });

  group('looksLikeDshAuthRequired（兜底识别卡在 401 生肉页面）', () {
    test('整段正文、带首尾空白、被截断的前缀都算命中', () {
      expect(looksLikeDshAuthRequired(dshAuthRequiredText), isTrue);
      expect(looksLikeDshAuthRequired('  $dshAuthRequiredText\n'), isTrue);
      expect(
          looksLikeDshAuthRequired('dsh web authentication required; reopen th'),
          isTrue);
    });

    test('正常页面正文、空正文、太短的巧合前缀都不算命中', () {
      expect(looksLikeDshAuthRequired('DSH\n对话 轨迹 统计'), isFalse);
      expect(looksLikeDshAuthRequired(''), isFalse);
      expect(looksLikeDshAuthRequired(null), isFalse);
      expect(looksLikeDshAuthRequired('dsh web'), isFalse);
    });
  });
}
