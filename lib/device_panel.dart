import 'dart:convert';

import 'package:flutter/material.dart';

/// 设备面板数据通道：在 WebView 页面上下文里请求 DSH 侧 `/adb-devices/*`。
/// 返回 `{ok, status, body, error}`（body 是原始 JSON 文本，由本文件解析）。
typedef AdbRequest = Future<Map<String, dynamic>> Function(
    String method, String path, [Map<String, dynamic>? body]);

/// 把文本塞进 DSH 消息输入框。返回 null 表示成功，否则是失败原因。
typedef ComposerInject = Future<String?> Function(String text);

/// 原生顶栏「测试机」入口点开的面板。
///
/// 只做三件事：扫（本机 adb + mDNS + Tailscale + 白名单网段，由 DSH 插件在那台
/// 机器上执行）、看（状态 / 连接方式 / 常亮 / 锁屏）、注入（选设备 + 选模板 → 把
/// 调试消息塞进当前会话的输入框，发送留给用户，避免误触发回合）。
///
/// 不直连任何新服务：数据走 [AdbRequest]（页内 fetch），注入走 [ComposerInject]
/// （页面自带的 composer 桥），与相机 / 语音 / 文件同一套机制。
class DevicePanelPage extends StatefulWidget {
  const DevicePanelPage({
    super.key,
    required this.request,
    required this.inject,
  });

  final AdbRequest request;
  final ComposerInject inject;

  @override
  State<DevicePanelPage> createState() => _DevicePanelPageState();
}

class _DevicePanelPageState extends State<DevicePanelPage> {
  List<Map<String, dynamic>> _devices = const [];
  Map<String, dynamic> _counts = const {};
  String _hostName = '';
  String _adbPath = '';
  String? _adbVersion;
  int _lastScanAt = 0;
  bool _everScanned = false;
  bool _busy = false;
  String? _error;
  String? _hint;
  final Set<String> _selected = <String>{};
  String _template = 'default';
  final TextEditingController _target = TextEditingController();

  static const List<(String, String)> _templates = <(String, String)>[
    ('default', '默认（清单 + 通道 + 排查建议）'),
    ('perDevice', '每台一条（分别注入）'),
    ('minimal', '极简（只要 serial 与命令）'),
  ];

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // 打开先读缓存（DSH 侧存 registry.json，秒回）；从没扫过才摆「扫描可用设备」。
    _load(listAction: 'list');
  }

  Map<String, dynamic>? _decode(Map<String, dynamic> result) {
    if (result['ok'] != true) {
      final status = result['status'];
      final error = result['error'] ?? '';
      _error = '请求失败：$error${status is int && status != 0 ? '（HTTP $status）' : ''}';
      return null;
    }
    final raw = result['body'];
    if (raw is! String || raw.isEmpty) {
      _error = '返回为空';
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        _error = '返回不是 JSON 对象';
        return null;
      }
      // DSH 侧的应答是 {ok, text, data}；ok=false 时把 text 当失败原因摊出来，
      // 不能当成功渲染（否则"没有可注入的设备"会被显示成正常列表）。
      if (decoded['ok'] == false) {
        _error = (decoded['text'] ?? decoded['error'] ?? '执行失败').toString();
        return null;
      }
      return decoded;
    } catch (e) {
      _error = '解析返回失败：$e';
      return null;
    }
  }

  void _apply(Map<String, dynamic>? envelope) {
    if (envelope == null) return;
    final data = envelope['data'];
    if (data is! Map<String, dynamic>) return;
    setState(() {
      _devices = (data['devices'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      _counts = data['counts'] is Map<String, dynamic>
          ? (data['counts'] as Map<String, dynamic>)
          : const {};
      _hostName = (data['hostName'] ?? '').toString();
      _adbPath = (data['adbPath'] ?? '').toString();
      _adbVersion = data['adbVersion']?.toString();
      _lastScanAt = (data['lastScanAt'] as num?)?.toInt() ?? _lastScanAt;
      _everScanned = _everScanned || _lastScanAt > 0 || _devices.isNotEmpty;
      // 选中项必须仍然存在，否则注入时会带上已消失的设备。
      final alive = _devices.map((d) => '${d['serial']}').toSet();
      _selected.retainWhere(alive.contains);
    });
  }

  Future<void> _load({required String listAction}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.request('GET', '/adb-devices/$listAction?action=$listAction');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hint = null;
    });
    _apply(_decode(result));
    if (_error != null && mounted) setState(() {});
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _hint = '正在扫描本机 USB / mDNS / Tailscale（局域网默认关闭，需显式白名单）…';
    });
    final scan = await widget.request('POST', '/adb-devices/scan', <String, dynamic>{});
    if (!mounted) return;
    final envelope = _decode(scan);
    final text = envelope?['text']?.toString();
    setState(() => _hint = text);
    if (envelope != null) _apply(envelope);
    if (_error != null) {
      setState(() => _busy = false);
      return;
    }
    await _load(listAction: 'list');
  }

  Future<void> _composeAndInject() async {
    if (_busy) return;
    if (_selected.isEmpty) {
      setState(() => _error = '先勾选至少一台设备');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    final compose = await widget.request('POST', '/adb-devices/compose', <String, dynamic>{
      'serials': _selected.toList(),
      'template': _template,
      'target': _target.text.trim(),
    });
    if (!mounted) return;
    final envelope = _decode(compose);
    if (envelope == null) {
      setState(() => _busy = false);
      return;
    }
    final data = envelope['data'];
    final messages = (data is Map<String, dynamic> ? data['messages'] : null) is List
        ? (data['messages'] as List).cast<dynamic>()
        : <dynamic>[envelope['text'] ?? ''];
    final parts = messages
        .map((m) => m is Map<String, dynamic> ? (m['text'] ?? '').toString() : m.toString())
        .where((t) => t.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      setState(() {
        _busy = false;
        _error = '没有生成出内容';
      });
      return;
    }
    final failure = await widget.inject(parts.join('\n\n'));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
      _hint = failure == null ? '已把 ${parts.length} 段调试消息放进输入框（没替你发送）' : null;
    });
  }

  Widget _chip(String text, Color color) => Container(
        margin: const EdgeInsets.only(right: 4, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );

  Color _stateColor(String state) {
    switch (state) {
      case 'device':
        return Colors.green;
      case 'offline':
        return Colors.red;
      case 'unauthorized':
        return Colors.orange;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _row(Map<String, dynamic> device) {
    final serial = '${device['serial']}';
    final transports = (device['transports'] as List?)?.cast<dynamic>() ?? const [];
    final health = '${device['health'] ?? ''}';
    final checked = _selected.contains(serial);
    return CheckboxListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      controlAffinity: ListTileControlAffinity.leading,
      value: checked,
      onChanged: (bool? on) => setState(() {
        if (on == true) {
          _selected.add(serial);
        } else {
          _selected.remove(serial);
        }
      }),
      title: Text(
        '${device['model']?.toString().isNotEmpty == true ? device['model'] : '未知型号'}'
        ' · Android ${device['android'] ?? '?'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(serial,
              style: const TextStyle(fontSize: 11, fontFeatures: [FontFeature.tabularFigures()]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Wrap(
            children: [
              for (final t in transports)
                _chip(
                  '${t is Map<String, dynamic> ? (t['label'] ?? t['kind']) : t} '
                  '${t is Map<String, dynamic> ? (t['endpoint'] ?? '') : ''}',
                  _stateColor('${t is Map<String, dynamic> ? (t['state'] ?? '') : ''}'),
                ),
              if (health.isNotEmpty) _chip(health, health == 'ok' ? Colors.green : Colors.orange),
              if (device['screenOn'] == false) const _ChipText('息屏'),
              if (device['locked'] == true) const _ChipText('锁屏'),
            ],
          ),
          if (device['summary']?.toString().isNotEmpty == true)
            Text('${device['summary']}',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('测试机设备${_hostName.isEmpty ? '' : ' · $_hostName'}',
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (_busy)
                      const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    IconButton(
                      tooltip: '只读刷新（探已知通道）',
                      icon: const Icon(Icons.refresh),
                      onPressed: _busy ? null : () => _load(listAction: 'status'),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '${_counts['total'] ?? 0} 台设备 / ${_counts['transports'] ?? 0} 条通道'
                  '　·　'
                  '${_adbVersion == null ? 'adb：$_adbPath（未取到版本）' : 'adb：$_adbPath · $_adbVersion'}'
                  '　·　上次扫描 ${_lastScanAt == 0 ? '从未' : DateTime.fromMillisecondsSinceEpoch(_lastScanAt).toString().substring(0, 19)}',
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_error != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(_error!,
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.onErrorContainer)),
                ),
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Text(_hint!, style: const TextStyle(fontSize: 11), maxLines: 4,
                      overflow: TextOverflow.ellipsis),
                ),
              if (!_everScanned && !_busy)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.devices_other_outlined, size: 44),
                      const SizedBox(height: 8),
                      Text('还没扫过设备。点下面这个按钮，让那台机器上的 adb 找一遍：',
                          style: TextStyle(fontSize: 12, color: theme.hintColor),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _scan,
                        icon: const Icon(Icons.radar),
                        label: const Text('扫描可用设备'),
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: _devices.isEmpty
                      ? Center(
                          child: Text(_busy ? '正在读取…' : '没有已知设备',
                              style: TextStyle(fontSize: 12, color: theme.hintColor)))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _devices.length,
                          itemBuilder: (context, i) => _row(_devices[i]),
                        ),
                ),
              if (_devices.isNotEmpty)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: theme.dividerColor))),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              isDense: true,
                              value: _template,
                              items: _templates
                                  .map((t) => DropdownMenuItem<String>(
                                      value: t.$1, child: Text(t.$2, style: const TextStyle(fontSize: 12))))
                                  .toList(),
                              onChanged: (v) => setState(() => _template = v ?? 'default'),
                              decoration: const InputDecoration(
                                  isDense: true, labelText: '模板', labelStyle: TextStyle(fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _target,
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: '调试目标（写进消息里）',
                                  labelStyle: TextStyle(fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      if (_selected.length == _devices.length) {
                                        _selected.clear();
                                      } else {
                                        _selected.addAll(_devices.map((d) => '${d['serial']}'));
                                      }
                                    }),
                            child: Text(_selected.length == _devices.length && _devices.isNotEmpty
                                ? '取消全选'
                                : '全选（${_devices.length}）'),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _busy ? null : _composeAndInject,
                            icon: const Icon(Icons.send_to_mobile),
                            label: Text(_selected.isEmpty ? '注入到消息框' : '注入 ${_selected.length} 台'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 只读状态小标（息屏 / 锁屏这类不可点的标签）。
class _ChipText extends StatelessWidget {
  const _ChipText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 4, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: theme.hintColor)),
    );
  }
}
