import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tunnel_service.dart';

/// 主机监控：每 10s 采样一次"默认主机资源监控"实例的
/// GPU / CPU / 内存使用率，维护最近 10 分钟（60 点）的环形缓冲。
///
/// 采集目标由实例级开关决定（TunnelService 维护独立采集隧道），
/// 与当前连接实例无关；设置中关闭监控或不设置监控实例时不请求不呈现。
class HostMonitor extends ChangeNotifier {
  HostMonitor._();
  static final HostMonitor instance = HostMonitor._();

  static const Duration _interval = Duration(seconds: 10);
  static const int _capacity = 60; // 10 分钟 / 10 秒

  final List<HostSample> _samples = [];
  Timer? _timer;
  bool _enabled = true;

  /// 是否开启监控（设置项，默认 true）。
  bool get enabled => _enabled;

  set enabled(bool v) {
    _enabled = v;
    if (!v) {
      // 关闭：停止采样并清空缓冲（曲线随之消失）
      _timer?.cancel();
      _timer = null;
      _samples.clear();
    }
    notifyListeners();
  }

  /// 当前采样点数量（不足十分钟时为实际数量）。
  int get count => _samples.length;

  /// 按时间从旧到新返回采样序列（复制，避免外部修改）。
  List<HostSample> get samples => List.unmodifiable(_samples);

  void _add(HostSample s) {
    _samples.add(s);
    if (_samples.length > _capacity) {
      _samples.removeAt(0);
    }
    notifyListeners();
  }

  /// 启动定时采样（幂等；仅隧道 connected 时真正执行采集）。
  void start() {
    _timer ??= Timer.periodic(_interval, (_) => _sample());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _sample() async {
    if (!_enabled) return;
    // 无"默认主机资源监控"实例时不采集
    if (TunnelService.instance.monitorProfileIndex == null) return;
    // 采集目标是监控实例（独立采集隧道），与当前连接实例无关
    final s = await TunnelService.instance.collectMonitorSample();
    if (s != null) _add(s);
  }
}

/// 在按钮背景绘制最近十分钟 GPU 使用率 / GPU 温度 / CPU / 内存趋势曲线。
///
/// 左侧为最老、右侧为最新；纵轴高度直接映射百分比（0% 底部 → 100% 顶部），
/// GPU 温度同样映射到 0~100℃ 高度；最新采样点以实心圆点强调。
/// 无刻度、无网格，仅呈现趋势。
class HostTrendPainter extends CustomPainter {
  HostTrendPainter({required this.samples});

  final List<HostSample> samples;

  /// 满容量点数（与 HostMonitor 环形缓冲一致：10 分钟 / 10s = 60 点）。
  static const int _capacity = 60;

  /// 四条序列与颜色：GPU 使用率(紫) / CPU(黄) / 内存(蓝) / GPU 温度(中国红)。
  static final _series = <(double Function(HostSample), Color)>[
    ((s) => s.gpu, Color(0xFFB388FF)), // 紫色：GPU 使用率
    ((s) => s.cpu, Color(0xFFFFD740)), // 亮黄：CPU
    ((s) => s.mem, Color(0xFF40C4FF)), // 亮蓝：内存
    ((s) => s.gpuTemp, Color(0xFFE60012)), // 中国红：GPU 温度
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final n = samples.length;
    if (n == 0) return;
    // 固定步长（基于满容量 60 点，而非当前点数）：最新点恒在右边缘，
    // 不足满容量时从右侧往左排布（右侧保持最新对齐），满容量时铺满全宽。
    // 旧实现用 width/(n-1) 会把不足的曲线拉伸铺满，与"右侧对齐"注释不符。
    final dx = size.width / math.max(1, _capacity - 1);

    for (final (selector, color) in _series) {
      final stroke = Paint()
        ..color = color
        ..strokeWidth = 1.3
        ..style = PaintingStyle.stroke;

      final path = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        final v = selector(samples[i]);
        if (v < 0) continue; // 无 GPU 数据等：跳过该点（连线断开）
        // 最新点（i=n-1）→ x = width；更老的 i 向左排布
        final x = (i - (n - 1)) * dx + size.width;
        final y = size.height - (v / 100) * size.height; // 高度映射百分比
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }

      // 最新点：实心圆点强调（注意力标记），恒在右边缘
      final last = selector(samples[n - 1]);
      if (last >= 0) {
        final lastY =
            size.height - (last / 100) * size.height;
        canvas.drawCircle(
            Offset(size.width, lastY), 2.0, Paint()..color = color);
      }

      if (started) canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant HostTrendPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
