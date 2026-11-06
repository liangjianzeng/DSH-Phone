import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TOFU（Trust On First Use）主机密钥校验器——从 [TunnelService] 的连接流程
/// 中独立出来，可脱离 SSH 单测（test/host_key_verifier_test.dart）。
///
/// 规则：
///  1. `host:port` **绝对首连**：记录算法+指纹并信任（TOFU 首连假设）；
///  2. 再次见到**已记录过的算法**：比对指纹，不一致拒连（中间人或服务器重装）；
///  3. `host:port` 已有记录、却拿出**从未记录过的算法**：一律拒连。
///     旧实现按 `host:port+算法` 分键，每个"该算法首次出现"都走信任记录分支，
///     能影响算法协商的中间人（钉了 ed25519 却降级到弱算法）即可整体绕过
///     指纹钉扎——无法与"服务器合法增改算法"区分，按攻击处理（fail-closed）。
///  4. 存储读写异常：拒连（fail-closed）。指纹既读不出也记不下时放行，
///     等于在这个窗口里跳过全部中间人防护。
///
/// 服务器合法换密钥/换算法导致被拒后的自救：设置页「清除主机密钥指纹」
/// （[clearAll]，连同算法集合一起清），下次连接重新走首连记录。
class HostKeyVerifier {
  const HostKeyVerifier();

  /// 指纹记录键。键名与历史版本保持一致（已装机的既有记录继续有效）。
  static String _fpKey(String host, int port, String algo) =>
      'ssh_hostkey_${host}_${port}_$algo';

  /// 已记录算法集合键（JSON 数组）。`ssh_hostkey_` 前缀与指纹键共用，
  /// [clearAll] 的前缀过滤天然一并清除。
  static String _algosKey(String host, int port) =>
      'ssh_hostkey_algos_${host}_$port';

  /// 校验一次握手拿到的主机密钥。返回 true=信任，false=拒绝。
  ///
  /// [onMismatch] 只在**本次连接**的上下文里回传"校验失败"（指纹不符或
  /// 未记录算法），让调用方抛出带类型的异常；不设全局标志（并发连接会
  /// 互相串档）。
  Future<bool> verify(
    String host,
    int port,
    String hostkeyType,
    Uint8List fingerprint, {
    void Function()? onMismatch,
  }) async {
    final fpKey = _fpKey(host, port, hostkeyType);
    final algosKey = _algosKey(host, port);
    final hex =
        fingerprint.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
    try {
      final prefs = await SharedPreferences.getInstance();
      final algos = _decodeAlgos(prefs.getString(algosKey));
      if (algos == null) {
        // 该 host:port 绝对首连：记录算法+指纹并信任。
        await prefs.setString(fpKey, hex);
        await prefs.setString(algosKey, jsonEncode([hostkeyType]));
        debugPrint('[DSH] host key first-seen for $host:$port ($hostkeyType),'
            ' recorded fingerprint=$hex');
        return true;
      }
      if (!algos.contains(hostkeyType)) {
        // 已钉扎过其它算法的地址冒出没见过的算法——按攻击处理（见类注释 3）。
        debugPrint('[DSH] host key UNSEEN algorithm $hostkeyType for '
            '$host:$port（已记录 $algos），reject（fail-closed；若服务器'
            '确实换了算法，请在设置清除主机密钥指纹后重连）');
        onMismatch?.call();
        return false;
      }
      final saved = prefs.getString(fpKey);
      if (saved == null) {
        // 不应发生：算法集合与指纹同批写入。集合说见过、指纹键却没了，
        // 视为记录被破坏，保守拒绝而不是重新信任。
        debugPrint('[DSH] host key record corrupt for $fpKey（algos 有、'
            '指纹无），reject');
        onMismatch?.call();
        return false;
      }
      if (saved == hex) return true;
      // 指纹变化：拒绝连接并提示（可能是中间人，也可能是服务器重装）
      debugPrint('[DSH] host key MISMATCH for $fpKey: '
          'saved=$saved current=$hex');
      onMismatch?.call();
      return false;
    } catch (e) {
      debugPrint('[DSH] host key store unavailable, reject (fail-closed): $e');
      return false;
    }
  }

  /// 三态解码：null = 从未记录（首连分支）；非 null = 已有记录，集合内是
  /// 允许出现的算法。集合值被写坏时**不能**退成 null（那等于清掉钉扎重新
  /// 首连信任），返回空集让一切算法都被 [verify] 拒绝，与存储故障同级。
  static Set<String>? _decodeAlgos(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw);
      if (list is List) return list.whereType<String>().toSet();
    } catch (_) {}
    return <String>{};
  }

  /// 清除全部已保存的主机密钥指纹与算法集合（设置页「清除主机密钥指纹」）。
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys()
          .where((k) => k.startsWith('ssh_hostkey_'))
          .toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
      debugPrint('[DSH] cleared ${keys.length} host key record(s)');
    } catch (e) {
      debugPrint('[DSH] clear host key fingerprints failed: $e');
    }
  }
}
