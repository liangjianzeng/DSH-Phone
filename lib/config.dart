import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SSH 连接配置 + 持久化。
///
/// 非敏感项（地址/用户名/端口/认证方式）存 shared_preferences；
/// 敏感项（密码、私钥、密钥口令）存 flutter_secure_storage（Android Keystore 加密）。
class SSHConfig {
  static const String keyHost = 'host';
  static const String keySshPort = 'ssh_port';
  static const String keyUsername = 'username';
  static const String keyLocalPort = 'local_port';
  static const String keyAuthType = 'auth_type';

  // secure storage keys
  static const String secPassword = 'password';
  static const String secPrivateKey = 'private_key';
  static const String secKeyPassphrase = 'key_passphrase';

  static const String authTypeKey = 'key';
  static const String authTypePassword = 'password';

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

  /// 读取配置（含从 secure storage 读敏感项）。
  static Future<SSHConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    const storage = FlutterSecureStorage();

    final password = await storage.read(key: secPassword) ?? '';
    final privateKeyPem = await storage.read(key: secPrivateKey) ?? '';
    final keyPassphrase = await storage.read(key: secKeyPassphrase) ?? '';

    return SSHConfig(
      host: prefs.getString(keyHost) ?? '',
      sshPort: prefs.getInt(keySshPort) ?? 22,
      username: prefs.getString(keyUsername) ?? '',
      localPort: prefs.getInt(keyLocalPort) ?? 3081,
      authType: prefs.getString(keyAuthType) ?? authTypeKey,
      password: password,
      privateKeyPem: privateKeyPem,
      keyPassphrase: keyPassphrase,
    );
  }

  /// 保存配置。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyHost, host);
    await prefs.setInt(keySshPort, sshPort);
    await prefs.setString(keyUsername, username);
    await prefs.setInt(keyLocalPort, localPort);
    await prefs.setString(keyAuthType, authType);

    const storage = FlutterSecureStorage();
    if (password.isNotEmpty) {
      await storage.write(key: secPassword, value: password);
    }
    if (privateKeyPem.isNotEmpty) {
      await storage.write(key: secPrivateKey, value: privateKeyPem);
    }
    if (keyPassphrase.isNotEmpty) {
      await storage.write(key: secKeyPassphrase, value: keyPassphrase);
    }
  }

  /// 清除全部配置。
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyHost);
    await prefs.remove(keySshPort);
    await prefs.remove(keyUsername);
    await prefs.remove(keyLocalPort);
    await prefs.remove(keyAuthType);

    const storage = FlutterSecureStorage();
    await storage.delete(key: secPassword);
    await storage.delete(key: secPrivateKey);
    await storage.delete(key: secKeyPassphrase);
  }
}
