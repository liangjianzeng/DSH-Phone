import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SSH 连接配置（单个实例）+ 持久化。
///
/// 支持最多 [maxProfiles] 路 SSH 实例配置（指向不同服务端），
/// 通过静态方法读写；其中一路为当前激活实例。
///
/// 非敏感项（地址/用户名/端口/认证方式/激活实例/加载超时）存 shared_preferences；
/// 敏感项（密码、私钥、密钥口令）存 flutter_secure_storage（Android Keystore 加密）。
class SSHConfig {
  // ============ 常量 ============

  /// 最多支持的 SSH 实例数量。
  static const int maxProfiles = 3;

  /// 页面加载超时（秒）默认值。
  static const int defaultTimeoutSeconds = 60;

  /// 页面加载超时（秒）最大值。
  static const int maxTimeoutSeconds = 180;

  /// 页面加载超时（秒）最小值。
  static const int minTimeoutSeconds = 30;

  // shared_preferences keys（旧单实例键名，用于迁移）
  static const String keyHost = 'host';
  static const String keySshPort = 'ssh_port';
  static const String keyUsername = 'username';
  static const String keyLocalPort = 'local_port';
  static const String keyAuthType = 'auth_type';

  // 激活实例 / 超时
  static const String keyActiveProfile = 'active_profile';
  static const String keyLoadTimeout = 'load_timeout_seconds';

  // secure storage keys（旧单实例键名，用于迁移）
  static const String secPassword = 'password';
  static const String secPrivateKey = 'private_key';
  static const String secKeyPassphrase = 'key_passphrase';

  static const String authTypeKey = 'key';
  static const String authTypePassword = 'password';

  // ============ 字段 ============

  final String host; // SSH 地址，如 100.81.83.59
  final int sshPort; // SSH 端口，默认 22
  final String username; // SSH 用户名，如 jianzengliang
  final int localPort; // 本地隧道端口，默认 3081
  final String authType; // 'key' | 'password'
  final String password; // 密码认证时使用
  final String privateKeyPem; // 密钥认证时使用
  final String keyPassphrase; // 私钥口令（可空）

  const SSHConfig({
    this.host = '',
    this.sshPort = 22,
    this.username = '',
    this.localPort = 3081,
    this.authType = authTypeKey,
    this.password = '',
    this.privateKeyPem = '',
    this.keyPassphrase = '',
  });

  bool get isConfigured =>
      host.isNotEmpty && username.isNotEmpty && sshPort > 0 && localPort > 0;

  bool get useKey => authType == authTypeKey;

  /// 展示名：地址为主，未配置时显示"未配置"。
  String get label => host.isNotEmpty ? host : '未配置';

  // ============ 单实例键名（按索引）============

  static String _pfx(int i) => 'profile_$i';
  static String _pKey(int i, String k) => '${_pfx(i)}_$k';
  static String _sKey(int i, String k) => '${_pfx(i)}_$k';

  // ============ 多实例读写 ============

  /// 读取全部实例（长度恒为 [maxProfiles]，未配置的为空白实例）。
  static Future<List<SSHConfig>> loadAllProfiles() async {
    await _migrateLegacy();
    final prefs = await SharedPreferences.getInstance();
    const storage = FlutterSecureStorage();

    final list = <SSHConfig>[];
    for (var i = 0; i < maxProfiles; i++) {
      final password = await storage.read(key: _sKey(i, secPassword)) ?? '';
      final privateKeyPem =
          await storage.read(key: _sKey(i, secPrivateKey)) ?? '';
      final keyPassphrase =
          await storage.read(key: _sKey(i, secKeyPassphrase)) ?? '';
      list.add(SSHConfig(
        host: prefs.getString(_pKey(i, keyHost)) ?? '',
        sshPort: prefs.getInt(_pKey(i, keySshPort)) ?? 22,
        username: prefs.getString(_pKey(i, keyUsername)) ?? '',
        localPort: prefs.getInt(_pKey(i, keyLocalPort)) ?? 3081,
        authType: prefs.getString(_pKey(i, keyAuthType)) ?? authTypeKey,
        password: password,
        privateKeyPem: privateKeyPem,
        keyPassphrase: keyPassphrase,
      ));
    }
    return list;
  }

  /// 读取当前激活实例（无配置时返回空白实例）。
  static Future<SSHConfig> loadActive() async {
    final index = await loadActiveIndex();
    final profiles = await loadAllProfiles();
    return profiles[index];
  }

  /// 读取激活实例索引。
  static Future<int> loadActiveIndex() async {
    await _migrateLegacy();
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(keyActiveProfile);
    return (v == null || v < 0 || v >= maxProfiles) ? 0 : v;
  }

  /// 设置激活实例索引。
  static Future<void> setActiveIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyActiveProfile,
        index.clamp(0, maxProfiles - 1));
  }

  /// 保存指定索引的实例配置（保存前做基础校验/归一化）。
  static Future<void> saveProfile(int index, SSHConfig config) async {
    final i = index.clamp(0, maxProfiles - 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pKey(i, keyHost), config.host);
    await prefs.setInt(_pKey(i, keySshPort), config.sshPort);
    await prefs.setString(_pKey(i, keyUsername), config.username);
    await prefs.setInt(_pKey(i, keyLocalPort), config.localPort);
    await prefs.setString(_pKey(i, keyAuthType), config.authType);

    const storage = FlutterSecureStorage();
    if (config.password.isNotEmpty) {
      await storage.write(key: _sKey(i, secPassword), value: config.password);
    }
    if (config.privateKeyPem.isNotEmpty) {
      await storage.write(
          key: _sKey(i, secPrivateKey), value: config.privateKeyPem);
    }
    if (config.keyPassphrase.isNotEmpty) {
      await storage.write(
          key: _sKey(i, secKeyPassphrase), value: config.keyPassphrase);
    }
  }

  /// 读取页面加载超时（秒），默认 [defaultTimeoutSeconds]。
  static Future<int> loadTimeoutSeconds() async {
    await _migrateLegacy();
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(keyLoadTimeout);
    return (v == null || v < minTimeoutSeconds) ? defaultTimeoutSeconds : v;
  }

  /// 保存页面加载超时（秒），自动夹取在 [minTimeoutSeconds]~[maxTimeoutSeconds]。
  static Future<void> saveTimeoutSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyLoadTimeout,
        seconds.clamp(minTimeoutSeconds, maxTimeoutSeconds));
  }

  // ============ 旧单实例配置迁移 ============

  /// 若存在旧版单实例配置且尚未迁移，则迁移到实例 0。
  static Future<void> _migrateLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    // 已有 profile_0_host 说明已迁移
    if (prefs.containsKey(_pKey(0, keyHost))) return;

    final legacyHost = prefs.getString(keyHost);
    if (legacyHost == null || legacyHost.isEmpty) return;

    const storage = FlutterSecureStorage();
    final password = await storage.read(key: secPassword) ?? '';
    final privateKeyPem = await storage.read(key: secPrivateKey) ?? '';
    final keyPassphrase = await storage.read(key: secKeyPassphrase) ?? '';

    await prefs.setString(_pKey(0, keyHost), legacyHost);
    await prefs.setInt(
        _pKey(0, keySshPort), prefs.getInt(keySshPort) ?? 22);
    await prefs.setString(
        _pKey(0, keyUsername), prefs.getString(keyUsername) ?? '');
    await prefs.setInt(
        _pKey(0, keyLocalPort), prefs.getInt(keyLocalPort) ?? 3081);
    await prefs.setString(
        _pKey(0, keyAuthType),
        prefs.getString(keyAuthType) ?? authTypeKey);
    if (password.isNotEmpty) {
      await storage.write(
          key: _sKey(0, secPassword), value: password);
    }
    if (privateKeyPem.isNotEmpty) {
      await storage.write(
          key: _sKey(0, secPrivateKey), value: privateKeyPem);
    }
    if (keyPassphrase.isNotEmpty) {
      await storage.write(
          key: _sKey(0, secKeyPassphrase), value: keyPassphrase);
    }

    // 清理旧键
    await prefs.remove(keyHost);
    await prefs.remove(keySshPort);
    await prefs.remove(keyUsername);
    await prefs.remove(keyLocalPort);
    await prefs.remove(keyAuthType);
    await storage.delete(key: secPassword);
    await storage.delete(key: secPrivateKey);
    await storage.delete(key: secKeyPassphrase);
  }

  // ============ 兼容旧调用（首次启动判断）============

  /// 判断是否存在任一已配置实例。
  static Future<bool> anyConfigured() async {
    final profiles = await loadAllProfiles();
    return profiles.any((p) => p.isConfigured);
  }
}
