/// DSH Web 登录 cookie 的端口归属——纯计算，零依赖，可单测。
///
/// **为什么需要这个文件**：隧道每次重建都可能换本地端口，而 DSH 的登录 cookie 是
/// **按端口签发、按主机发送**的：
///
/// * 名字 = `dsh-auth-<unpadded base64url(sha256(authority))>`，`authority` 就是 Host 头
///   （DSH 侧 `cookieName()`，见 `tool/dsh_cookie_port_scoping.mjs` 的对照实验），
///   端口一变，名字就变；
/// * 浏览器发 cookie **只看 host/path，不看端口**——同主机所有端口共享 jar。
///
/// 于是"换了本地端口"这件事在 App 侧几乎不可见（隧道照常就绪、探活照常通过），
/// 但服务端按新端口算名字 → 查不到那颗 30 天 cookie → 只能退回 URL 上的 `?token=`
/// 重签；token 又是 DSH 进程启动时随机生成的，服务器重启过一次 App 里存的就是废的
/// → 主文档 401「dsh web authentication required」。历史上唯一的解法是杀进程把原端口
/// 腾回来（用户报的"只有杀掉进程重启才行"）。
///
/// 关键突破口就在"浏览器不看端口"这一条上：**jar 里存着的那颗 cookie 的名字，反向唯一
/// 决定了它是在哪个端口签发的**。App 只要在冷启动 / 401 时把 jar 里的 cookie 名列出来，
/// 与候选端口逐个比对，就能问出"哪颗 cookie 是活的、该把本地入口搬回哪个端口"——
/// 不需要任何内存状态，也不需要用户填 Token。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// cookie 名前缀，与 DSH 的 `COOKIE_PREFIX` 同源。
const String dshAuthCookiePrefix = 'dsh-auth-';

/// DSH Web 主文档鉴权失败时返回的**整段正文**（401，纯文本）。
///
/// 界面据此兜底识别"卡在 401 页面上却没有弹出鉴权卡"的情况：`onReceivedHttpError`
/// 对主文档并非在所有路径上都会回调（缓存命中、错误页复用、部分 ROM 的 WebView 实现），
/// 只看回调会把鉴权失败当成"页面加载成功"，用户只剩一屏生肉文本。
const String dshAuthRequiredText =
    'dsh web authentication required; reopen the URL printed by dsh web.';

/// [authority] 对应的 DSH 登录 cookie 名，例：`127.0.0.1:3081` →
/// `dsh-auth-w3iJaA6qw3qDSBs2Itl-h4S-Y-ZeYCC-N_iZO-eI_qw`。
String dshAuthCookieName(String authority) {
  final digest = sha256.convert(utf8.encode(authority)).bytes;
  // base64Url 带 `=` 填充，DSH 侧是**去填充**的；`+/` 换成 `-_` 两边一致。
  return dshAuthCookiePrefix +
      base64Url.encode(digest).replaceAll(RegExp(r'=+$'), '');
}

/// 隧道本地入口的 authority（DSH 看到的 Host 头）。
String dshAuthorityFor(String host, int port) => '$host:$port';

/// 在 WebView cookie jar 的 cookie 名里，找出**归属 [host] 且落在候选端口里**的那颗
/// DSH 登录 cookie，返回它对应的端口；找不到返回 null。
///
/// [cookieNames] 直接喂 `CookieManager.getCookies()` 的 name 列表即可——**故意不按端口
/// 过滤**（浏览器发 cookie 本来就不看端口，jar 里可能有多个端口的历史 cookie）。
/// 多个候选都命中时取 [candidatePorts] 里**排在前面的**（调用方把最可信的端口放前面：
/// 配置端口 → 上次成功鉴权端口 → 当前端口 → 保留池）。
///
/// 注意"存在 cookie 名"只证明**当年在那个端口签过发**，不证明它还没过期/未被服务端
/// 轮换作废；所以调用方拿到结果后要**真的搬过去试一次**（见
/// `TunnelService.rebindLocalPort`），搬过去还是 401 才是真 Token 失效。
int? findAuthorizedPort(
  Iterable<String> cookieNames, {
  required String host,
  required Iterable<int> candidatePorts,
}) {
  final names = cookieNames.toSet();
  for (final port in candidatePorts) {
    if (port <= 0 || port > 65535) continue;
    if (names.contains(
        dshAuthCookieName(dshAuthorityFor(host, port)))) {
      return port;
    }
  }
  return null;
}

/// 页面正文是不是 DSH 的鉴权失败文本（允许前后空白、允许被截断——我们只读前若干字符）。
bool looksLikeDshAuthRequired(String? bodyText) {
  if (bodyText == null) return false;
  final t = bodyText.trim();
  if (t.isEmpty) return false;
  final target = dshAuthRequiredText;
  // 正文可能因 DOM 尚未稳定只读到前缀；也可能是「401 + 正文」这种带状态的错误页排版。
  if (target.startsWith(t)) return t.length >= 16;
  return t.contains(target);
}
