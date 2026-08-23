import 'dart:async';

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
    this.hostMonitorEnabled = true,
    this.onHostMonitorChanged,
    this.resourceViewEnabled = true,
    this.onResourceViewChanged,
    this.resourceDownloadEnabled = true,
    this.onResourceDownloadChanged,

    /// 实例级"默认主机资源监控"开关即时保存后通知父级刷新监控隧道。
    this.onInstanceMonitorChanged,
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

  /// 主机监控开关（默认开启；关闭则不请求不呈现曲线）。
  final bool hostMonitorEnabled;
  final ValueChanged<bool>? onHostMonitorChanged;

  /// 资源查看开关（默认开启；关闭后不触发查看能力）。
  final bool resourceViewEnabled;
  final ValueChanged<bool>? onResourceViewChanged;

  /// 资源下载开关（默认开启；关闭后不触发下载能力）。
  final bool resourceDownloadEnabled;
  final ValueChanged<bool>? onResourceDownloadChanged;

  /// 实例级"默认主机资源监控"开关即时保存后通知父级刷新监控隧道。
  final ValueChanged<bool>? onInstanceMonitorChanged;

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

  /// 当前编辑实例的"默认主机资源监控"开关（实例级，随实例切换回填）。
  late bool _instanceHostMonitorEnabled;

  bool _saving = false;
  String? _testResult;
  bool _testPassed = false;

  /// 表单自动保存防抖计时器（编辑停止 800ms 后保存，无需手动点"保存"）。
  Timer? _autoSaveTimer;

  /// 对话区缩放控件开关的本地状态（设置页是独立路由，父级 setState
  /// 不会重建它，必须本地持有才能即时反映拨动效果）。
  late bool _zoomControlsEnabled;

  /// 工具类功能开关本地状态（同样本地持有以即时反映拨动）。
  late bool _hostMonitorEnabled;
  late bool _resourceViewEnabled;
  late bool _resourceDownloadEnabled;

  @override
  void initState() {
    super.initState();
    _profileIndex = widget.profileIndex.clamp(0, SSHConfig.maxProfiles - 1);
    _timeoutSeconds = widget.timeoutSeconds;
    _zoomControlsEnabled = widget.zoomControlsEnabled;
    _hostMonitorEnabled = widget.hostMonitorEnabled;
    _resourceViewEnabled = widget.resourceViewEnabled;
    _resourceDownloadEnabled = widget.resourceDownloadEnabled;
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
    _instanceHostMonitorEnabled = c.hostMonitorEnabled;
  }

  @override
  void dispose() {
    // 最后一次编辑可能仍在防抖中：取消计时器并立即保存当前表单快照。
    // 函数同步段会先读取表单文本，再进入异步保存，不受下方 controller.dispose 影响。
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _persistCurrent();
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

  /// 切换要编辑的实例标签（自动保存模式下，切换前先落盘当前编辑内容）。
  void _switchProfile(int index) {
    if (index == _profileIndex) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _persistCurrent(); // 切换前保存当前编辑实例，不再"放弃未保存的编辑"
    setState(() {
      _profileIndex = index;
      _loadFromProfile(index);
      _testResult = null;
      _testPassed = false;
    });
  }

  /// 表单编辑后触发防抖自动保存：停止输入 800ms 后落盘。
  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 800), () {
      _autoSaveTimer = null;
      _persistCurrent();
    });
  }

  /// 立即持久化当前编辑的实例配置 + 页面加载超时（自动保存核心）。
  ///
  /// 不弹出/不重连，仅落盘；由父级在返回设置页时统一重连生效。
  Future<void> _persistCurrent() async {
    await SSHConfig.saveProfile(_profileIndex, _buildConfig());
    await SSHConfig.saveTimeoutSeconds(_timeoutSeconds);
    // 首次配置时，若尚无激活实例则把当前编辑实例设为激活
    if (widget.profileIndex == _profileIndex ||
        !(await SSHConfig.loadActive()).isConfigured) {
      await SSHConfig.setActiveIndex(_profileIndex);
    }
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

  /// 端口校验：必须是 1~65535 的整数（0 与超界无法绑定）。
  String? _validatePort(String? v) {
    final p = int.tryParse(v ?? '');
    if (p == null || p < 1 || p > 65535) return '端口无效（1-65535）';
    return null;
  }

  /// 即时保存实例级监控开关：只写开关字段，不触碰表单其它未保存内容；
  /// 开启时互斥关闭其他实例，并通知父级刷新监控隧道。
  Future<void> _applyInstanceMonitorImmediately(bool on) async {
    await SSHConfig.saveInstanceHostMonitor(_profileIndex, on);
    if (on) {
      // 全局仅允许一个实例开启：关闭其他实例的开关（从内存配置读取完整信息）
      for (var i = 0; i < SSHConfig.maxProfiles; i++) {
        if (i == _profileIndex) continue;
        final other = widget.profiles[i];
        if (!other.hostMonitorEnabled) continue;
        await SSHConfig.saveProfile(i, SSHConfig(
          host: other.host,
          sshPort: other.sshPort,
          username: other.username,
          localPort: other.localPort,
          authType: other.authType,
          password: other.password,
          privateKeyPem: other.privateKeyPem,
          keyPassphrase: other.keyPassphrase,
          alias: other.alias,
          hostMonitorEnabled: false,
        ));
      }
    }
    widget.onInstanceMonitorChanged?.call(on);
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
      hostMonitorEnabled: _instanceHostMonitorEnabled,
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
    // 自动保存模式下，表单已随编辑落盘；这里仅做校验 + 提交动作
    // （首次启动根页面通知父级 / 编辑页返回并重连）。
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    await _persistCurrent();
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
    // 分类管理：主机 / 工具 / 关于，三类独立 Tab 呈现，不再堆叠。
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('DSH-Phone 设置'),
          // 设置自动保存：表单编辑停止即落盘，无需右上角"保存"按钮
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.dns_outlined), text: '主机'),
              Tab(icon: Icon(Icons.build_outlined), text: '工具'),
              Tab(icon: Icon(Icons.info_outline), text: '关于'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildHostTab(context),
            _buildToolsTab(context),
            _buildAboutTab(context),
          ],
        ),
      ),
    );
  }

  /// 主机分类：SSH 实例配置（最多 3 路）+ 测试 / 保存。
  Widget _buildHostTab(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            onChanged: (_) => _scheduleAutoSave(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _alias,
            decoration: const InputDecoration(
              labelText: '实例别名（可选）',
              hintText: '如：家里的服务器 / Home Server',
              helperText: '最多 7 个中文或 15 个英文字母；留空则显示地址（IP）',
              border: OutlineInputBorder(),
            ),
            validator: _validateAlias,
            onChanged: (_) => _scheduleAutoSave(),
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
                  onChanged: (_) => _scheduleAutoSave(),
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
                  validator: _validatePort,
                  onChanged: (_) => _scheduleAutoSave(),
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
            validator: _validatePort,
            onChanged: (_) => _scheduleAutoSave(),
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
                  onChanged: (v) {
                    setState(() => _authType = v ?? SSHConfig.authTypeKey);
                    _scheduleAutoSave();
                  },
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('密码'),
                  value: SSHConfig.authTypePassword,
                  groupValue: _authType,
                  onChanged: (v) {
                    setState(() => _authType = v ?? SSHConfig.authTypeKey);
                    _scheduleAutoSave();
                  },
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
              onChanged: (_) => _scheduleAutoSave(),
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
              onChanged: (_) => _scheduleAutoSave(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _keyPassphrase,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '私钥口令（可选）',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _scheduleAutoSave(),
            ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('默认主机资源监控'),
            subtitle: const Text(
              '开启后该实例成为全局监控目标，顶栏曲线始终显示它的主机数据'
              '（与当前连接实例无关）；仅允许一个实例开启',
            ),
            value: _instanceHostMonitorEnabled,
            onChanged: (v) {
              setState(() => _instanceHostMonitorEnabled = v);
              // 即时保存：切换即生效，无需等待"保存"按钮
              _applyInstanceMonitorImmediately(v);
              if (v) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(
                    content: Text('已开启实例 ${_profileIndex + 1} 的主机资源监控，'
                        '其他实例已自动关闭该开关'),
                  ));
              }
            },
          ),
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
    );
  }

  /// 工具分类：加载超时、界面缩放 / 缓存、主机监控、资源查看 / 下载开关。
  Widget _buildToolsTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
          onChanged: (v) {
            setState(() => _timeoutSeconds = v.round());
            _scheduleAutoSave();
          },
        ),
        Text(
          '大上下文会话历史加载较慢时，可适当调大超时，避免提示超时。',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const Divider(),
        // 主机监控：默认开启，关闭则不请求不呈现
        SwitchListTile(
          title: const Text('主机监控'),
          subtitle: const Text(
            '默认开启；通过 SSH 隧道每 10s 采集远程主机使用率，'
            '顶部状态栏背景显示最近 10 分钟趋势曲线\n'
            '曲线颜色：紫色=GPU 使用率 · 黄色=CPU · 蓝色=内存 · 红色=GPU 温度；'
            '左侧最老右侧最新，最新采样点以实心圆点标记',
          ),
          value: _hostMonitorEnabled,
          onChanged: (v) {
            setState(() => _hostMonitorEnabled = v);
            widget.onHostMonitorChanged?.call(v);
          },
        ),
        // 资源查看 / 下载：默认开启，关闭不触发能力
        SwitchListTile(
          title: const Text('资源查看'),
          subtitle: const Text(
            '默认开启；关闭后点击文件型成果（代码块/Markdown/文本）不再打开查看器',
          ),
          value: _resourceViewEnabled,
          onChanged: (v) {
            setState(() => _resourceViewEnabled = v);
            widget.onResourceViewChanged?.call(v);
          },
        ),
        SwitchListTile(
          title: const Text('资源下载'),
          subtitle: const Text(
            '默认开启；关闭后点击资源型成果（apk/压缩包等）不再触发下载',
          ),
          value: _resourceDownloadEnabled,
          onChanged: (v) {
            setState(() => _resourceDownloadEnabled = v);
            widget.onResourceDownloadChanged?.call(v);
          },
        ),
        if (widget.showUiControls) ...[
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
            valueListenable: widget.zoomNotifier ?? ValueNotifier<double>(1.0),
            builder: (context, value, _) => Text(
              '当前缩放：${(value * 100).round()}%',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('对话区显示缩放控件'),
            subtitle: const Text(
              '默认关闭；开启后在对话区左侧显示放大/缩小/重置浮动按钮',
            ),
            value: _zoomControlsEnabled,
            onChanged: (v) {
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
      ],
    );
  }

  /// 关于分类：已有关于介绍（版本 / 原理 / 开源地址 / README）归入此处。
  Widget _buildAboutTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('版本'),
                subtitle: const Text('DSH-Phone v0.1.5'),
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
                onTap: () =>
                    _openUrl('https://github.com/liangjianzeng/DSH-Phone#readme'),
              ),
            ],
          ),
        ),
      ],
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
            'DSH-Phone v0.1.5\n\n'
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
