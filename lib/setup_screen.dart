import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'tunnel_service.dart';

/// 首次启动 / 设置页：配置 SSH 地址、用户名、认证方式（密钥或密码）、本地端口，
/// 页面加载超时，以及（已连接时）界面缩放与缓存刷新控制。
///
/// 支持最多 3 路 SSH 实例配置：通过顶部标签切换要编辑的实例。
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.profileIndex,
    required this.timeoutSeconds,
    required this.profiles,
    this.showUiControls = false,
    this.onSaved,
    this.zoomNotifier,
    this.onZoomIn,
    this.onZoomOut,
    this.onResetZoom,
    this.onRefreshCache,
    this.zoomControlsEnabled = false,
    this.onZoomControlsChanged,
  });

  /// 当前编辑的实例索引。
  final int profileIndex;

  /// 当前页面加载超时（秒）。
  final int timeoutSeconds;

  /// 全部实例配置（用于标签切换编辑）。
  final List<SSHConfig> profiles;

  /// 首次启动时 SetupScreen 作为根页面展示，保存成功后通过此回调通知父级
  /// 更新"已配置"状态（而不是 pop 根路由导致黑屏）。为 null 时走
  /// [Navigator.pop(true)]（编辑页场景）。
  final VoidCallback? onSaved;

  /// 是否显示界面控制（缩放/刷新缓存）——仅在已连接时由主界面传入。
  final bool showUiControls;

  /// 缩放比例共享通知器（实时联动显示）。
  final ValueNotifier<double>? zoomNotifier;

  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final VoidCallback? onResetZoom;
  final VoidCallback? onRefreshCache;

  /// 对话区左侧浮动缩放控件是否显示（默认关闭）。
  final bool zoomControlsEnabled;

  /// 切换对话区缩放控件显示（默认关闭）。
  final ValueChanged<bool>? onZoomControlsChanged;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();

  late int _profileIndex;
  late int _timeoutSeconds;

  late TextEditingController _host;
  late TextEditingController _alias;
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

  /// 对话区缩放控件开关的本地状态（设置页是独立路由，父级 setState
  /// 不会重建它，必须本地持有才能即时反映拨动效果）。
  late bool _zoomControlsEnabled;

  @override
  void initState() {
    super.initState();
    _profileIndex = widget.profileIndex.clamp(0, SSHConfig.maxProfiles - 1);
    _timeoutSeconds = widget.timeoutSeconds;
    _zoomControlsEnabled = widget.zoomControlsEnabled;
    _loadFromProfile(_profileIndex);
  }

  /// 把指定实例配置回填到表单控件。
  void _loadFromProfile(int index) {
    final c = widget.profiles[index];
    _host = TextEditingController(text: c.host);
    _alias = TextEditingController(text: c.alias);
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
    _alias.dispose();
    _sshPort.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _keyPassphrase.dispose();
    _localPort.dispose();
    super.dispose();
  }

  /// 切换要编辑的实例标签（放弃未保存的编辑）。
  void _switchProfile(int index) {
    if (index == _profileIndex) return;
    setState(() {
      _profileIndex = index;
      _loadFromProfile(index);
      _testResult = null;
      _testPassed = false;
    });
  }

  /// 校验实例别名：可空；非空时加权长度不超过 15。
  /// 中文（CJK）按 2 计、其他字符按 1 计，从而等价于"最多 7 个中文或 15 个英文字母"。
  String? _validateAlias(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return null; // 空别名合法，展示名回退为地址
    var weight = 0;
    for (final code in t.runes) {
      final isCjk = (code >= 0x4E00 && code <= 0x9FFF) || // 常用汉字
          (code >= 0x3400 && code <= 0x4DBF) || // 扩展 A
          (code >= 0x20000 && code <= 0x2A6DF) || // 扩展 B
          (code >= 0xFF00 && code <= 0xFFEF) || // 全角标点/字母
          code >= 0x2E80 && code <= 0x2EFF; // CJK 部首等
      weight += isCjk ? 2 : 1;
    }
    if (weight > 15) return '别名过长：最多 7 个中文或 15 个英文字母';
    return null;
  }

  SSHConfig _buildConfig() {
    return SSHConfig(
      host: _host.text.trim(),
      alias: _alias.text.trim(),
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
    // 保存当前实例配置 + 页面加载超时
    await SSHConfig.saveProfile(_profileIndex, _buildConfig());
    await SSHConfig.saveTimeoutSeconds(_timeoutSeconds);
    // 首次配置时，若尚无激活实例则把当前编辑实例设为激活
    if (widget.profileIndex == _profileIndex ||
        !(await SSHConfig.loadActive()).isConfigured) {
      await SSHConfig.setActiveIndex(_profileIndex);
    }
    if (mounted) setState(() => _saving = false);
    if (mounted) {
      if (widget.onSaved != null) {
        // 首次启动根页面：通知父级更新状态，不 pop 根路由
        widget.onSaved!();
      } else {
        Navigator.of(context).pop(true);
      }
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
            // 实例标签：最多 3 路 SSH 实例配置
            const Text('连接实例（最多 3 路）', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [
                for (var i = 0; i < SSHConfig.maxProfiles; i++)
                  ButtonSegment<int>(
                    value: i,
                    label: Text('实例${i + 1}'),
                    tooltip: widget.profiles[i].label,
                  ),
              ],
              selected: {_profileIndex},
              showSelectedIcon: true,
              onSelectionChanged: (selection) =>
                  _switchProfile(selection.first),
            ),
            const SizedBox(height: 16),
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
            // 实例别名：可为空（为空时展示名回退为地址 IP）
            TextFormField(
              controller: _alias,
              decoration: const InputDecoration(
                labelText: '实例别名（可选）',
                hintText: '如：家里的服务器 / Home Server',
                helperText: '最多 7 个中文或 15 个英文字母；留空则显示地址（IP）',
                border: OutlineInputBorder(),
              ),
              validator: _validateAlias,
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
            const SizedBox(height: 16),
            const Divider(),
            // 页面加载超时设置
            const Text('加载超时', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '页面加载超时（秒）：$_timeoutSeconds',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const Text('默认 60 · 最大 180',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            Slider(
              value: _timeoutSeconds.toDouble(),
              min: SSHConfig.minTimeoutSeconds.toDouble(),
              max: SSHConfig.maxTimeoutSeconds.toDouble(),
              divisions: 15,
              label: '$_timeoutSeconds 秒',
              onChanged: (v) =>
                  setState(() => _timeoutSeconds = v.round()),
            ),
            Text(
              '大上下文会话历史加载较慢时，可适当调大超时，避免提示超时。',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (widget.showUiControls) ...[
              const SizedBox(height: 16),
              const Divider(),
              const Text('界面设置', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.onZoomOut,
                      icon: const Icon(Icons.zoom_out),
                      label: const Text('缩小'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.onZoomIn,
                      icon: const Icon(Icons.zoom_in),
                      label: const Text('放大'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.onResetZoom,
                      icon: const Icon(Icons.aspect_ratio),
                      label: const Text('重置'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<double>(
                valueListenable:
                    widget.zoomNotifier ?? ValueNotifier<double>(1.0),
                builder: (context, value, _) => Text(
                  '当前缩放：${(value * 100).round()}%',
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              // 对话区左侧浮动缩放控件开关（默认关闭）
              SwitchListTile(
                title: const Text('对话区显示缩放控件'),
                subtitle: const Text(
                  '默认关闭；开启后在对话区左侧显示放大/缩小/重置浮动按钮',
                ),
                value: _zoomControlsEnabled,
                onChanged: (v) {
                  // 本地状态即时反映拨动，同时通知主界面持久化并生效
                  setState(() => _zoomControlsEnabled = v);
                  widget.onZoomControlsChanged?.call(v);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: widget.onRefreshCache,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新缓存'),
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
            const SizedBox(height: 16),
            const Divider(),
            const Text('关于', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('版本'),
                    subtitle: const Text('DSH-Phone v0.1.3'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showAbout,
                  ),
                  ListTile(
                    leading: const Icon(Icons.stars_outlined),
                    title: const Text('项目原理'),
                    subtitle: const Text('通过 SSH 隧道把手机端口转发到远程 DSH Web UI，用 WebView 加载'),
                    onTap: _showAbout,
                  ),
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: const Text('开源地址'),
                    subtitle: const Text('github.com/liangjianzeng/DSH-Phone'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => _openUrl('https://github.com/liangjianzeng/DSH-Phone'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('README'),
                    subtitle: const Text('查看项目说明文档'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => _openUrl(
                        'https://github.com/liangjianzeng/DSH-Phone#readme'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开外部链接（GitHub / README）。
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接，请检查系统浏览器')),
      );
    }
  }

  /// 显示"关于"对话框：版本、原理、开源地址。
  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于 DSH-Phone'),
        content: const SingleChildScrollView(
          child: Text(
            'DSH-Phone v0.1.3\n\n'
            '一个在 Android 上通过 SSH 隧道访问 DeepSeek Harness Web UI 的客户端。\n\n'
            '工作原理：\n'
            '• 应用内置 dartssh2 建立 SSH 隧道\n'
            '• 将手机 127.0.0.1:<端口> 转发到远程 127.0.0.1:3080\n'
            '• 用 WebView 以 loopback 身份加载远程 DSH 界面\n'
            '• 配置/模型等特权接口因 loopback 而可用\n'
            '• 最多配置 3 路 SSH 实例，顶部状态栏自由切换\n\n'
            '开源：github.com/liangjianzeng/DSH-Phone',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _openUrl('https://github.com/liangjianzeng/DSH-Phone');
            },
            child: const Text('访问 GitHub'),
          ),
        ],
      ),
    );
  }
}
