import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tunnel_diagnostics.dart';
import 'tunnel_service.dart';

/// 「连接诊断」页：隧道事件流 + 当前状态快照。
///
/// 为什么必须存在于产品里：真机 + VPN 组网下没有 adb，历史上"APK 老提示连不上"
/// 这类问题只能靠用户转述。有了带时间戳的事件流（连接尝试、探活结果、传输层
/// 关闭、转发建链超时、网络接口变化），一次截图/复制就能区分到底是
/// DNS 失败 / 链路不可达 / 半开假死 / 云端服务没起 —— 这四种处置方式完全不同。
class TunnelDiagnosticsScreen extends StatefulWidget {
  const TunnelDiagnosticsScreen({super.key});

  @override
  State<TunnelDiagnosticsScreen> createState() =>
      _TunnelDiagnosticsScreenState();
}

class _TunnelDiagnosticsScreenState extends State<TunnelDiagnosticsScreen> {
  Timer? _tick;
  bool _onlyProblems = false;

  @override
  void initState() {
    super.initState();
    // 2 秒刷新：够跟上监督器的节奏，又不至于高频重建整页。
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _copyAll() async {
    final state = TunnelService.instance.state;
    final header = TunnelDiagnosticsScreenHelper.summaryLine(state);
    await Clipboard.setData(ClipboardData(
      text: TunnelDiagnostics.instance.exportText(header: header),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已复制诊断日志，可直接粘贴反馈')));
  }

  @override
  Widget build(BuildContext context) {
    final state = TunnelService.instance.state;
    final events = TunnelDiagnostics.instance.events.reversed
        .where((e) =>
            !_onlyProblems ||
            e.level != TunnelEventLevel.info)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('连接诊断'),
        actions: [
          IconButton(
            tooltip: _onlyProblems ? '显示全部事件' : '只看告警/错误',
            icon: Icon(_onlyProblems
                ? Icons.filter_alt_outlined
                : Icons.filter_alt),
            onPressed: () => setState(() => _onlyProblems = !_onlyProblems),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(TunnelDiagnostics.instance.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          _SummaryCard(state: state),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text('事件流（${events.length}）',
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                Text('自动刷新 2s',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey)),
              ],
            ),
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(
                    child: Text('暂无事件',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (context, i) {
                      final e = events[i];
                      final color = switch (e.level) {
                        TunnelEventLevel.info => Colors.grey,
                        TunnelEventLevel.warn => Colors.orange,
                        TunnelEventLevel.error => Colors.red,
                      };
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Text(e.levelLabel,
                            style: TextStyle(
                                color: color, fontWeight: FontWeight.bold)),
                        title: Text('${e.tag}  ${e.message}',
                            style: const TextStyle(
                                fontSize: 12, fontFamily: 'monospace')),
                        subtitle: Text(
                            '${e.at.hour.toString().padLeft(2, '0')}:'
                            '${e.at.minute.toString().padLeft(2, '0')}:'
                            '${e.at.second.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 诊断页顶部状态快照卡。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.state});

  final TunnelState state;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('状态', state.userMessage),
      ('故障类别', state.kind.name),
      ('提示级别', state.alertLevel.name),
      ('已尝试', '${state.attempt} 次'),
      ('下次重试', state.nextRetryAt == null
          ? '—'
          : '${state.nextRetryAt!.difference(DateTime.now()).inSeconds} 秒后'),
      ('最近探活', state.lastProbeAt == null
          ? '尚未探测'
          : '${state.lastProbeAt!.toLocal().toString().substring(11, 19)}'
              '  ${state.probeOk ? 'OK' : '失败'}'),
      ('本次会话', state.connectedSince == null
          ? '未连接'
          : '已连接 ${DateTime.now().difference(state.connectedSince!).inSeconds} 秒'),
      ('最近错误', state.lastError ?? '—'),
    ];
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                        width: 72,
                        child: Text(k,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey))),
                    Expanded(
                      child: Text(v,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 复制导出时的抬头（含状态摘要），便于远程排查时一眼看清现场。
class TunnelDiagnosticsScreenHelper {
  static String summaryLine(TunnelState s) {
    final parts = <String>[
      'DSH-Phone 连接诊断  ${DateTime.now()}',
      '状态=${s.status.name} 类别=${s.kind.name} 尝试=${s.attempt}',
      '探活=${s.probeOk ? 'OK' : 'FAIL'}',
    ];
    if (s.lastError != null) parts.add('最近错误=${s.lastError}');
    return parts.join('\n');
  }
}
