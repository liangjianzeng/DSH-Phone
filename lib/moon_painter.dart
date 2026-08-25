import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按真实天文观测绘制"阴晴圆缺"月亮的 [CustomPainter]。
///
/// 月球不发光，我们看到的是它对太阳光的反射：任何时候都只有朝向太阳的
/// 半个球面被照亮。观测形态由三要素决定：
///
/// 1. **相位/照明度**：日-地-月相位角 ψ 的余弦模型，朔望周期 29.53 天，
///    [phase] 为小时级连续相位（0=朔，0.5=望，→1 回朔）。
/// 2. **明暗界线形状**：月盘投影是圆，昼夜分界线投影是椭圆——长半轴 R、
///    短半轴 R·|cos(2π·phase)|。亮面/暗面由「月盘弧 + 界线椭圆弧」围成。
/// 3. **盘面朝向**：亮缘永远指向太阳在天空的方向，其相对「盘面竖直（向天顶）」
///    的倾角 [tiltDeg] 由观测纬度与月球时角（经度/时刻）决定——这就是
///    月出月落时亮面旋转、高纬度/南半球形态不同的原因。
class MoonPhasePainter extends CustomPainter {
  const MoonPhasePainter(this.phase, this.tiltDeg);

  /// 月相：0=朔(新月)，0.5=望(满月)，1=朔(新月)。
  final double phase;

  /// 亮缘相对盘面竖直（向天顶）的倾角（度）。正 = 盘面上逆时针。
  /// 画师内部约定亮缘方向为盘面右侧（+x），再整体旋转该倾角。
  final double tiltDeg;

  /// 暗面（深蓝夜色）与亮面（月白微蓝）颜色。
  static const Color darkColor = Color(0xFF16283F);
  static const Color litColor = Color(0xFFE3F2FD);

  /// 照明度（0=全暗 → 1=全亮）：亮面占月盘面积的比例。
  double get illumination => (1 - math.cos(2 * math.pi * phase)) / 2;

  /// 盘面旋转量（度）：画师内部亮缘朝 +x（盘面右侧），旋转后指向真实亮缘。
  /// 由天文的倾角映射：倾角 270°（亮缘在盘面右缘）→ 旋转 0。
  static double _rotationDeg(double tiltDeg) =>
      -(tiltDeg + 90.0) % 360.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final c = math.cos(2 * math.pi * phase); // 1→-1→1：新 → 满 → 新
    // 明暗界线椭圆短半轴：0（弦月，界线退为直线）→ R（新月/满月，界线退为月盘弧）
    final term = math.max(r * c.abs(), r * 0.001);

    // 1) 先铺亮色整圆，暗面按需覆盖。
    canvas.drawCircle(center, r, Paint()..color = MoonPhasePainter.litColor);

    // 2) 新月/满月的退化点：|c|≈1 时两弧重合，月牙退化（旋转无关）。
    if (term >= r) {
      if (c >= 0) {
        // 朔（新月）：全暗
        canvas.drawCircle(center, r,
            Paint()..color = MoonPhasePainter.darkColor);
      }
      return; // 望（满月）：暗面为空，保持全亮
    }

    // 3) 明暗界线：旋转到真实亮缘方向。画师内部亮缘恒朝盘面右侧（+x），
    //    亮面向 +x、暗面向 −x，由旋转量定位到天空真实朝向。
    final rotRad = _rotationDeg(tiltDeg) * math.pi / 180.0;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotRad);
    canvas.translate(-center.dx, -center.dy);

    final darkPaint = Paint()..color = MoonPhasePainter.darkColor;
    if (c >= 0) {
      // 弦月/娥眉/残月：亮面是「月盘弧 + 界线椭圆弧」围成的月牙；
      // 暗面 = 全盘挖掉这枚月牙（evenOdd）。
      final litCrescent = _crescentPath(center, r, term, onRight: true);
      final darkPath = Path()
        ..addOval(Rect.fromCircle(center: center, radius: r))
        ..addPath(litCrescent, Offset.zero);
      darkPath.fillType = PathFillType.evenOdd;
      canvas.drawPath(darkPath, darkPaint);
    } else {
      // 凸月/满月：暗面是「月盘弧 + 界线椭圆弧」围成的薄月牙（位于亮面对侧）。
      final darkCrescent = _crescentPath(center, r, term, onRight: false);
      canvas.drawPath(darkCrescent, darkPaint);
    }

    canvas.restore();
  }

  /// 「月盘弧 + 明暗界线椭圆弧」围成的弓形区域（月牙 / 半月 / 薄月牙）。
  /// [onRight] 为 true 表示弓形在月盘右侧，false 在左侧。
  Path _crescentPath(Offset center, double r, double term,
      {required bool onRight}) {
    final circleRect = Rect.fromCircle(center: center, radius: r);
    final termRect =
        Rect.fromCenter(center: center, width: 2 * term, height: 2 * r);
    final path = Path();
    if (onRight) {
      path.addArc(circleRect, -math.pi / 2, math.pi); // 月盘右弧：上 → 右 → 下
      path.addArc(termRect, math.pi / 2, -math.pi); // 界线椭圆右弧：下 → 右 → 上
    } else {
      path.addArc(circleRect, math.pi / 2, math.pi); // 月盘左弧：下 → 左 → 上
      path.addArc(termRect, -math.pi / 2, -math.pi); // 界线椭圆左弧：上 → 左 → 下
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(MoonPhasePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.tiltDeg != tiltDeg;
}
