import 'package:flutter/material.dart';

import 'config.dart';
import 'tunnel_service.dart';

/// 首次启动 / 设置页：配置 SSH 地址、用户名、认证方式（密钥或密码）、本地端口。
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.initial});

  /// 已有配置时传入，用于回填（从设置页进入时）。
  final SSHConfig? initial;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _host;
  late TextEditingController _sshPort;
  late TextEditingController _username;
  late TextEditingController _password;
  late TextEditingController _privateKey;
  late TextEditingController _keyPassphrase;
  late TextEditingController _localPort;

  late String _authType;

  bool _saving = false;
  String? _testResult;
  bool _testPassed = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initial ?? const SSHConfig();
    _host = TextEditingController(text: c.host);
    _sshPort = TextEditingController(text: '${c.sshPort}');
    _username = TextEditingController(text: c.username);
    _password = TextEditingController(text: c.password);
    _privateKey = TextEditingController(text: c.privateKeyPem);
    _keyPassphrase = TextEditingController(text: c.keyPassphrase);
    _localPort = TextEditingController(text: '${c.localPort}');
    _authType = c.authType;
  }

  @override
  void dispose() {
    _host.dispose();
    _sshPort.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _keyPassphrase.dispose();
    _localPort.dispose();
    super.dispose();
  }

  SSHConfig _buildConfig() {
    return SSHConfig(
      host: _host.text.trim(),
      sshPort: int.tryParse(_sshPort.text.trim()) ?? 22,
      username: _username.text.trim(),
      localPort: int.tryParse(_localPort.text.trim()) ?? 3081,
      authType: _authType,
      password: _authType == SSHConfig.authTypePassword
          ? _password.text
          : '',
      privateKeyPem: _authType == SSHConfig.authTypeKey
          ? _privateKey.text.trim()
          : '',
      keyPassphrase: _keyPassphrase.text,
    );
  }

  Future<void> _testConnection() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _testResult = null;
      _testPassed = false;
      _saving = true;
    });
    final config = _buildConfig();
    try {
      await TunnelService.instance.connect(config);
      await TunnelService.instance.disconnect();
      setState(() {
        _testPassed = true;
        _testResult = '连接成功 ✅';
      });
    } catch (e) {
      setState(() {
        _testResult = '连接失败: $e';
      });
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final config = _buildConfig();
    await config.save();
    if (mounted) setState(() => _saving = false);
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DSH-Phone 设置'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('SSH 连接配置', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'SSH 地址',
                hintText: '如 100.81.83.59',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? '请输入 SSH 地址'
                  : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      hintText: '如 jianzengliang',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? '请输入用户名'
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _sshPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'SSH 端口',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => int.tryParse(v ?? '') == null
                        ? '端口无效'
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _localPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '本地隧道端口',
                helperText: '默认 3081，DSH 界面将通过 http://127.0.0.1:<端口> 访问',
                border: OutlineInputBorder(),
              ),
              validator: (v) => int.tryParse(v ?? '') == null
                  ? '端口无效'
                  : null,
            ),
            const SizedBox(height: 16),
            const Text('认证方式', style: TextStyle(fontSize: 16)),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('SSH 密钥（推荐）'),
                    value: SSHConfig.authTypeKey,
                    groupValue: _authType,
                    onChanged: (v) =>
                        setState(() => _authType = v ?? SSHConfig.authTypeKey),
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('密码'),
                    value: SSHConfig.authTypePassword,
                    groupValue: _authType,
                    onChanged: (v) => setState(
                        () => _authType = v ?? SSHConfig.authTypeKey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_authType == SSHConfig.authTypePassword) ...[
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'SSH 密码',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
              ),
            ] else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '私钥内容 (PEM)',
                  hintText:
                      '粘贴 -----BEGIN ... PRIVATE KEY----- 全文\n（留空则仅用密码）',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? '请输入私钥内容'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _keyPassphrase,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '私钥口令（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _testResult!,
                  style: TextStyle(
                    color: _testPassed ? Colors.green : Colors.red,
                    fontSize: 16,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: Text(_saving ? '测试中…' : '测试连接'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check),
                    label: const Text('保存并连接'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
