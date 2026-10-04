import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'weather_service.dart';

/// 相机按钮周边的天气动效（云/雨/雪/雾/雷）。
///
/// 设计约束（产品要求）：
/// - 动效区域固定在相机按钮周边、随按钮拖拽移动——宽度约 120dp 的窄条，
///   不太宽（不大面积遮挡对话区）也不太窄（天气观感清晰）；
/// - 整层由父级 [IgnorePointer] 包裹：不拦截任何触摸，纯粹视觉氛围；
/// - 云/雨/雪/雾均以低不透明度绘制，下层内容保持可读；
/// - 雨强分级：毛毛雨 < 中雨 < 大雨/雷暴——雨滴数量、长度、速度随级递增。
///
/// 粒子形状用固定种子随机生成（每种天气一组稳定参数），动画只用
/// 单个 [AnimationController] 的相位值驱动，帧间无随机抖动。
class WeatherOverlay extends StatefulWidget {
  const WeatherOverlay({super.key, required this.kind});

  /// 当前天气种类；[WeatherKind.clear] 时不绘制任何内容。
  final WeatherKind kind;

  @override
  State<WeatherOverlay> createState() => _WeatherOverlayState();
}

class _WeatherOverlayState extends State<WeatherOverlay>
    with SingleTickerProviderStateMixin {
  /// 动画总周期。雨滴/雪花速度差异由各自的 speed 相对值缩放。
  static const Duration _cycle = Duration(seconds: 10);

  /// 性能：动画仍用 vsync 的 AnimationController（后台自动暂停、省电），但把
  /// 相位 t 量化——每约 3 帧（约 20fps）才重绘一次，大幅降低主线程重绘开销、
  /// 减少天气特效导致的界面卡顿，观感几乎不变（600 帧/周期 ÷ 3 ≈ 每 3 帧一次）。
  static const int _quant = 200;

  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: _cycle)..repeat();

  _KindConfig _config = const _KindConfig();

  @override
  void initState() {
    super.initState();
    _config = _buildConfig(widget.kind);
  }

  @override
  void didUpdateWidget(WeatherOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) {
      _config = _buildConfig(widget.kind);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary 隔离天气动效重绘：不影响/不连带整个 Stack 与 WebView 图层
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _WeatherPainter(
            _config,
            // 量化相位：跨过量化步长才触发重绘（shouldRepaint 拦截）
            t: (_ctrl.value * _quant).floor() / _quant,
          ),
        ),
      ),
    );
  }

  /// 按天气种类生成粒子配置（固定种子 → 同种天气形状稳定）。
  static _KindConfig _buildConfig(WeatherKind kind) {
    switch (kind) {
      case WeatherKind.clear:
        return const _KindConfig();
      case WeatherKind.partlyCloudy:
        return _KindConfig(
          clouds: _clouds(1, small: true),
        );
      case WeatherKind.cloudy:
        return _KindConfig(
          clouds: _clouds(3),
        );
      case WeatherKind.fog:
        return _KindConfig(
          fogBands: List.generate(3, (i) => _FogBand(
            y: 0.30 + 0.24 * i,
            height: 16 + 4.0 * i,
            speed: 0.10 + 0.03 * i,
            phase: i * 0.37,
            alpha: 0.13 + 0.02 * i,
          )),
        );
      case WeatherKind.drizzle:
        return _KindConfig(
          clouds: _clouds(1, small: true),
          drops: _drops(10, speed: 0.55, len: 7, width: 1.2, alpha: 0.38),
        );
      case WeatherKind.rain:
        return _KindConfig(
          clouds: _clouds(2),
          drops: _drops(16, speed: 0.85, len: 10, width: 1.4, alpha: 0.48),
        );
      case WeatherKind.heavyRain:
        return _KindConfig(
          clouds: _clouds(2, dark: true),
          drops: _drops(26, speed: 1.2, len: 14, width: 1.8, alpha: 0.58),
        );
      case WeatherKind.snow:
        return _KindConfig(
          clouds: _clouds(1, small: true),
          flakes: _flakes(18),
        );
      case WeatherKind.thunder:
        return _KindConfig(
          clouds: _clouds(2, dark: true),
          drops: _drops(24, speed: 1.15, len: 13, width: 1.7, alpha: 0.55),
          lightning: true,
        );
    }
  }

  static List<_Cloud> _clouds(int count,
      {bool small = false, bool dark = false}) {
    final rng = math.Random(dark ? 7 : (small ? 11 : 23));
    return List.generate(count, (i) {
      final base = small ? 0.55 : 0.8;
      return _Cloud(
        x0: rng.nextDouble(),
        y: 0.12 + 0.10 * rng.nextDouble(),
        scale: base + 0.25 * rng.nextDouble(),
        speed: 0.05 + 0.04 * rng.nextDouble(),
        alpha: dark ? 0.52 : (small ? 0.38 : 0.44),
        dark: dark,
      );
    });
  }

  static List<_Drop> _drops(
    int count, {
    required double speed,
    required double len,
    required double width,
    required double alpha,
  }) {
    final rng = math.Random(42);
    return List.generate(count, (i) {
      return _Drop(
        x0: rng.nextDouble(),
        phase: rng.nextDouble(),
        speed: speed * (0.85 + 0.3 * rng.nextDouble()),
        len: len * (0.8 + 0.4 * rng.nextDouble()),
        width: width,
        alpha: alpha * (0.7 + 0.6 * rng.nextDouble()),
        slant: 0.10 + 0.08 * rng.nextDouble(),
      );
    });
  }

  static List<_Flake> _flakes(int count) {
    final rng = math.Random(99);
    return List.generate(count, (i) {
      return _Flake(
        x0: rng.nextDouble(),
        phase: rng.nextDouble(),
        speed: 0.35 + 0.15 * rng.nextDouble(),
        radius: 1.4 + 1.6 * rng.nextDouble(),
        sway: 4 + 6 * rng.nextDouble(),
        swayFreq: 0.6 + 0.5 * rng.nextDouble(),
        alpha: 0.55 + 0.25 * rng.nextDouble(),
      );
    });
  }
}

/// 某一天气的完整粒子配置。
class _KindConfig {
  const _KindConfig({
    this.clouds = const [],
    this.drops = const [],
    this.flakes = const [],
    this.fogBands = const [],
    this.lightning = false,
  });

  final List<_Cloud> clouds;
  final List<_Drop> drops;
  final List<_Flake> flakes;
  final List<_FogBand> fogBands;
  final bool lightning;
}

class _Cloud {
  const _Cloud({
    required this.x0,
    required this.y,
    required this.scale,
    required this.speed,
    required this.alpha,
    this.dark = false,
  });

  /// 水平漂移相位 0..1（映射到 −0.3..1.3 宽度实现循环绕行）。
  final double x0;

  /// 云带内相对高度 0..1。
  final double y;
  final double scale;
  final double speed;
  final double alpha;

  /// 乌云（大雨/雷暴伴随）：用更深的云色。
  final bool dark;
}

class _Drop {
  const _Drop({
    required this.x0,
    required this.phase,
    required this.speed,
    required this.len,
    required this.width,
    required this.alpha,
    required this.slant,
  });

  final double x0;
  final double phase;
  final double speed;
  final double len;
  final double width;
  final double alpha;

  /// 风斜率（雨丝水平偏移 / 垂直长度）。
  final double slant;
}

class _Flake {
  const _Flake({
    required this.x0,
    required this.phase,
    required this.speed,
    required this.radius,
    required this.sway,
    required this.swayFreq,
    required this.alpha,
  });

  final double x0;
  final double phase;
  final double speed;
  final double radius;
  final double sway;
  final double swayFreq;
  final double alpha;
}

class _FogBand {
  const _FogBand({
    required this.y,
    required this.height,
    required this.speed,
    required this.phase,
    required this.alpha,
  });

  final double y;
  final double height;
  final double speed;
  final double phase;
  final double alpha;
}

class _WeatherPainter extends CustomPainter {
  const _WeatherPainter(this.config, {required this.t});

  final _KindConfig config;

  /// 动画相位 0..1。
  final double t;

  static const Color _cloudColor = Color(0xFFB0C4D8);
  static const Color _darkCloudColor = Color(0xFF6B7F94);
  static const Color _dropColor = Color(0xFFA6D8FF);
  static const Color _flakeColor = Color(0xFFF4FAFF);
  static const Color _fogColor = Color(0xFFE8F1F8);

  @override
  void paint(Canvas canvas, Size size) {
    if (config.fogBands.isNotEmpty) _paintFog(canvas, size);
    for (final cloud in config.clouds) {
      _paintCloud(canvas, size, cloud);
    }
    for (final drop in config.drops) {
      _paintDrop(canvas, size, drop);
    }
    for (final flake in config.flakes) {
      _paintFlake(canvas, size, flake);
    }
    if (config.lightning) _paintLightning(canvas, size);
  }

  /// 云：直接绘制多个同色椭圆（nonZero 并集视觉与路径一致），
  /// 避免每帧构建 Path 对象，降低重绘开销。
  void _paintCloud(Canvas canvas, Size size, _Cloud c) {
    // 绕行：x 从 −0.3w 漂到 1.3w 后回到起点。
    final x = ((c.x0 + t * c.speed) % 1.6) - 0.3;
    final cx = x * size.width;
    final cy = c.y * size.height;
    final r = c.scale * size.width * 0.14;
    final paint = Paint()
      ..color = (c.dark ? _darkCloudColor : _cloudColor)
          .withValues(alpha: c.alpha);
    // 云形：中央大 puff + 两侧小 puff + 底部压平的宽 puff。
    void puff(double dx, double dy, double rr) {
      canvas.drawOval(
        Rect.fromCircle(
          center: Offset(cx + dx * r, cy + dy * r),
          radius: rr * r,
        ),
        paint,
      );
    }

    puff(-0.85, 0.15, 0.62);
    puff(-0.35, -0.15, 0.85);
    puff(0.30, -0.05, 0.75);
    puff(0.85, 0.18, 0.58);
    puff(0.0, 0.22, 0.80);
  }

  /// 雨滴：从云带下方落到区域底部的斜线段，两端渐隐。
  void _paintDrop(Canvas canvas, Size size, _Drop d) {
    final phase = (d.phase + t * d.speed) % 1.0;
    // 垂直范围：0.30h（云带下沿）→ 0.97h。
    final yTop = size.height * (0.30 + 0.67 * phase);
    final x = d.x0 * size.width + phase * d.slant * size.width * 0.1;
    final alpha =
        d.alpha * math.min(1.0, math.min(phase * 5.0, (1.0 - phase) * 3.0));
    final paint = Paint()
      ..color = _dropColor.withValues(alpha: alpha.clamp(0.0, 1.0))
      ..strokeWidth = d.width
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(x, yTop),
      Offset(x + d.len * d.slant, yTop + d.len),
      paint,
    );
  }

  /// 雪花：慢速下落 + 横向正弦摆动的小圆点。
  void _paintFlake(Canvas canvas, Size size, _Flake f) {
    final phase = (f.phase + t * f.speed) % 1.0;
    final y = size.height * (0.28 + 0.69 * phase);
    final x = f.x0 * size.width +
        f.sway * math.sin(2 * math.pi * (t * f.swayFreq + f.phase));
    final alpha =
        f.alpha * math.min(1.0, math.min(phase * 5.0, (1.0 - phase) * 3.0));
    canvas.drawCircle(
      Offset(x, y),
      f.radius,
      Paint()..color = _flakeColor.withValues(alpha: alpha.clamp(0.0, 1.0)),
    );
  }

  /// 雾带：横向漂移的半透明圆角长条。
  void _paintFog(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final band in config.fogBands) {
      // 绕行：从 −0.35w 漂到 1.35w。
      final x = (((band.phase + t * band.speed) % 1.7) - 0.35) * size.width;
      final rect = Rect.fromLTWH(
        x,
        band.y * size.height,
        size.width * 1.05,
        band.height,
      );
      paint.color = _fogColor.withValues(alpha: band.alpha);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(band.height / 2)),
        paint,
      );
    }
  }

  /// 闪电：每周期两次的短暂云区闪白 + 一道折线闪电。
  void _paintLightning(Canvas canvas, Size size) {
    const flashesPerCycle = 2.0;
    final flashPhase = (t * flashesPerCycle) % 1.0;
    if (flashPhase >= 0.08) return;
    final strength = 1.0 - flashPhase / 0.08; // 1 → 0 衰减
    // 云区闪白。
    final glow = Rect.fromLTWH(0, size.height * 0.04, size.width,
        size.height * 0.26);
    canvas.drawRect(
      glow,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.20 * strength),
    );
    // 闪电折线（从云底劈到区域中部）：直接画线段，不建 Path。
    final boltPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pts = <Offset>[
      Offset(size.width * 0.46, size.height * 0.28),
      Offset(size.width * 0.56, size.height * 0.42),
      Offset(size.width * 0.48, size.height * 0.45),
      Offset(size.width * 0.58, size.height * 0.62),
    ];
    for (var i = 0; i + 1 < pts.length; i++) {
      canvas.drawLine(pts[i], pts[i + 1], boltPaint);
    }
  }

  @override
  bool shouldRepaint(_WeatherPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.config != config;
}
