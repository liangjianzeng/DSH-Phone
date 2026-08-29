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

  /// Unsloth Studio 连接端口默认值。
  static const int defaultUnslothPort = 8888;

  // shared_preferences keys（旧单实例键名，用于迁移）
  static const String keyHost = 'host';
  static const String keySshPort = 'ssh_port';
  static const String keyUsername = 'username';
  static const String keyLocalPort = 'local_port';
  static const String keyAuthType = 'auth_type';
  static const String keyAlias = 'alias';

  // 激活实例 / 超时
  static const String keyActiveProfile = 'active_profile';
  static const String keyLoadTimeout = 'load_timeout_seconds';

  // 工具类功能开关
  static const String keyHostMonitor = 'host_monitor_enabled';
  static const String keyResourceView = 'resource_view_enabled';
  static const String keyResourceDownload = 'resource_download_enabled';

  // 实例级"默认主机资源监控"开关（最多一个实例开启）
  static const String keyInstanceHostMonitor = 'instance_host_monitor';

  // Unsloth Studio 实例级配置（非敏感项）
  static const String keyUnslothEnabled = 'unsloth_enabled';
  static const String keyUnslothPort = 'unsloth_port';
  static const String keyUnslothUseSsh = 'unsloth_use_ssh';

  // secure storage keys（旧单实例键名，用于迁移）
  static const String secPassword = 'password';
  static const String secPrivateKey = 'private_key';
  static const String secKeyPassphrase = 'key_passphrase';

  // Unsloth Studio 登录密码（敏感项）
  static const String secUnslothPassword = 'unsloth_password';

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
  final String alias; // 实例别名（可空，为空时展示名回退为地址）

  /// 实例级"默认主机资源监控"开关：开启后该实例成为全局监控目标，
  /// 顶栏趋势曲线始终显示它的主机数据（与当前连接实例无关）。
  /// 所有实例默认关闭，且全局最多一个实例开启。
  final bool hostMonitorEnabled;

  /// Unsloth Studio 启用开关（实例级，默认关闭；全局仅允许一个实例开启，
  /// 顶栏图标始终打开该实例的 Unsloth Studio，与当前连接实例无关）。
  final bool unslothEnabled;

  /// Unsloth Studio 连接端口（默认 8888）。
  final int unslothPort;

  /// Unsloth Studio 是否走 SSH 隧道（默认否 → HTTP 直连）。
  final bool unslothUseSsh;

  /// Unsloth Studio 登录密码（敏感项，存 secure storage；用于登录页自动登录）。
  final String unslothPassword;

  const SSHConfig({
    this.host = '',
    this.sshPort = 22,
    this.username = '',
    this.localPort = 3081,
    this.authType = authTypeKey,
    this.password = '',
    this.privateKeyPem = '',
    this.keyPassphrase = '',
    this.alias = '',
    this.hostMonitorEnabled = false,
    this.unslothEnabled = false,
    this.unslothPort = defaultUnslothPort,
    this.unslothUseSsh = false,
    this.unslothPassword = '',
  });

  bool get isConfigured =>
      host.isNotEmpty && username.isNotEmpty && sshPort > 0 && localPort > 0;

  bool get useKey => authType == authTypeKey;

  /// 展示名：优先别名；无别名时回退为地址（IP），未配置时显示"未配置"。
  String get label {
    if (alias.isNotEmpty) return alias;
    return host.isNotEmpty ? host : '未配置';
  }

  // ============ 单实例键名（按索引）============

  static String _pfx(int i) => 'profile_$i';

  /// 统一键名：shared_preferences 与 secure storage 共用同一键名空间
  /// （前缀 profile_<i>_ 区分实例，键名后缀区分用途；两者互不冲突）。
  static String _pKey(int i, String k) => '${_pfx(i)}_$k';

  // ============ 多实例读写 ============

  /// 安全读取 secure storage：Android Keystore 在系统更新/备份恢复/应用数据
  /// 还原等场景可能失效并抛异常，这里兜底返回空串，避免启动即崩溃。
  static Future<String> _safeSecRead(
      FlutterSecureStorage storage, String key) async {
    try {
      return await storage.read(key: key) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 读取全部实例（长度恒为 [maxProfiles]，未配置的为空白实例）。
  static Future<List<SSHConfig>> loadAllProfiles() async {
    await _migrateLegacy();
    final prefs = await SharedPreferences.getInstance();
    const storage = FlutterSecureStorage();

    final list = <SSHConfig>[];
    for (var i = 0; i < maxProfiles; i++) {
      final password = await _safeSecRead(storage, _pKey(i, secPassword));
      final privateKeyPem =
          await _safeSecRead(storage, _pKey(i, secPrivateKey));
      final keyPassphrase =
          await _safeSecRead(storage, _pKey(i, secKeyPassphrase));
      final unslothPassword =
          await _safeSecRead(storage, _pKey(i, secUnslothPassword));
      list.add(SSHConfig(
        host: prefs.getString(_pKey(i, keyHost)) ?? '',
        sshPort: prefs.getInt(_pKey(i, keySshPort)) ?? 22,
        username: prefs.getString(_pKey(i, keyUsername)) ?? '',
        localPort: prefs.getInt(_pKey(i, keyLocalPort)) ?? 3081,
        authType: prefs.getString(_pKey(i, keyAuthType)) ?? authTypeKey,
        password: password,
        privateKeyPem: privateKeyPem,
        keyPassphrase: keyPassphrase,
        alias: prefs.getString(_pKey(i, keyAlias)) ?? '',
        hostMonitorEnabled:
            prefs.getBool(_pKey(i, keyInstanceHostMonitor)) ?? false,
        unslothEnabled:
            prefs.getBool(_pKey(i, keyUnslothEnabled)) ?? false,
        unslothPort:
            prefs.getInt(_pKey(i, keyUnslothPort)) ?? defaultUnslothPort,
        unslothUseSsh: prefs.getBool(_pKey(i, keyUnslothUseSsh)) ?? false,
        unslothPassword: unslothPassword,
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
    await prefs.setString(_pKey(i, keyAlias), config.alias);
    await prefs.setBool(
        _pKey(i, keyInstanceHostMonitor), config.hostMonitorEnabled);
    await prefs.setBool(_pKey(i, keyUnslothEnabled), config.unslothEnabled);
    await prefs.setInt(_pKey(i, keyUnslothPort), config.unslothPort);
    await prefs.setBool(_pKey(i, keyUnslothUseSsh), config.unslothUseSsh);

    const storage = FlutterSecureStorage();
    // 敏感项写入/删除双方向同步：用户清空某项时，旧值不能滞留在 keystore。
    if (config.password.isNotEmpty) {
      await storage.write(key: _pKey(i, secPassword), value: config.password);
    } else {
      await storage.delete(key: _pKey(i, secPassword));
    }
    if (config.privateKeyPem.isNotEmpty) {
      await storage.write(
          key: _pKey(i, secPrivateKey), value: config.privateKeyPem);
    } else {
      await storage.delete(key: _pKey(i, secPrivateKey));
    }
    if (config.keyPassphrase.isNotEmpty) {
      await storage.write(
          key: _pKey(i, secKeyPassphrase), value: config.keyPassphrase);
    } else {
      await storage.delete(key: _pKey(i, secKeyPassphrase));
    }
    if (config.unslothPassword.isNotEmpty) {
      await storage.write(
          key: _pKey(i, secUnslothPassword), value: config.unslothPassword);
    } else {
      await storage.delete(key: _pKey(i, secUnslothPassword));
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

  // ============ 工具类功能开关 ============

  /// 读取主机监控开关（默认开启）。
  static Future<bool> loadHostMonitorEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyHostMonitor) ?? true;
  }

  static Future<void> saveHostMonitorEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyHostMonitor, enabled);
  }

  /// 读取资源查看开关（默认开启）。
  static Future<bool> loadResourceViewEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyResourceView) ?? true;
  }

  static Future<void> saveResourceViewEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyResourceView, enabled);
  }

  /// 读取资源下载开关（默认开启）。
  static Future<bool> loadResourceDownloadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyResourceDownload) ?? true;
  }

  static Future<void> saveResourceDownloadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyResourceDownload, enabled);
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
    final password = await _safeSecRead(storage, secPassword);
    final privateKeyPem = await _safeSecRead(storage, secPrivateKey);
    final keyPassphrase = await _safeSecRead(storage, secKeyPassphrase);

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
          key: _pKey(0, secPassword), value: password);
    }
    if (privateKeyPem.isNotEmpty) {
      await storage.write(
          key: _pKey(0, secPrivateKey), value: privateKeyPem);
    }
    if (keyPassphrase.isNotEmpty) {
      await storage.write(
          key: _pKey(0, secKeyPassphrase), value: keyPassphrase);
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

  // ============ 实例级主机资源监控 ============

  /// 读取开启"默认主机资源监控"的实例索引（无则 -1）。
  static Future<int> loadMonitorProfileIndex() async {
    final profiles = await loadAllProfiles();
    return profiles.indexWhere((p) => p.hostMonitorEnabled);
  }

  /// 仅保存指定实例的"默认主机资源监控"开关（不触碰表单其它字段，
  /// 用于设置页即时保存）。
  static Future<void> saveInstanceHostMonitor(int index, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        _pKey(index.clamp(0, maxProfiles - 1), keyInstanceHostMonitor),
        enabled);
  }

  // ============ 实例级 Unsloth Studio（全局唯一）============

  /// 读取开启"Unsloth Studio"的实例索引（无则 -1；全局最多一个实例开启）。
  static Future<int> loadUnslothProfileIndex() async {
    final profiles = await loadAllProfiles();
    return profiles.indexWhere((p) => p.unslothEnabled);
  }

  /// 仅保存指定实例的"Unsloth Studio"开关（不触碰表单其它字段，
  /// 用于设置页即时保存）。
  static Future<void> saveInstanceUnsloth(int index, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        _pKey(index.clamp(0, maxProfiles - 1), keyUnslothEnabled),
        enabled);
  }
}
