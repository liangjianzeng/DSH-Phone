import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按真实天文形状绘制"阴晴圆缺"月亮的 [CustomPainter]。
///
/// 月球不发光，我们看到的是它对太阳光的反射：任何时候都只有朝向太阳的
/// 半个球面被照亮。随着月球绕地球公转，日-地-月相对位置周期变化（朔望月
/// ≈29.53 天），从地球看到的被照亮半球投影随之变化。
///
/// 画法：月盘投影是圆；昼夜分界线（明暗界线）投影是椭圆——长半轴 = R、
/// 短半轴 = R·|cos(2π·phase)|。亮面/暗面由「月盘弧 + 界线椭圆弧」围成：
/// 弦月/娥眉/残月时亮面是两弧之间的月牙，凸月时暗面是两弧之间的薄月牙。
/// 北半球面南观测：月盈亮面在右（西），月亏亮面在左（东）。
class MoonPhasePainter extends CustomPainter {
  const MoonPhasePainter(this.phase);

  /// 月相：0=朔(新月)，0.5=望(满月)，1=朔(新月)。
  final double phase;

  /// 暗面（深蓝夜色）与亮面（月白微蓝）颜色。
  static const Color darkColor = Color(0xFF16283F);
  static const Color litColor = Color(0xFFE3F2FD);

  /// 照明度（0=全暗 → 1=全亮）：亮面占月盘面积的比例。
  double get illumination => (1 - math.cos(2 * math.pi * phase)) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final c = math.cos(2 * math.pi * phase); // 1→-1→1：新 → 满 → 新
    // 明暗界线椭圆短半轴：0（弦月，界线退为直线）→ R（新月/满月，界线退为月盘弧）
    final term = math.max(r * c.abs(), r * 0.001);

    // 1) 先铺亮色整圆，暗面按需覆盖。
    canvas.drawCircle(center, r, Paint()..color = MoonPhasePainter.litColor);

    // 2) 新月/满月的退化点：|c|≈1 时两弧重合，月牙退化。
    if (term >= r) {
      if (c >= 0) {
        // 朔（新月）：全暗
        canvas.drawCircle(center, r,
            Paint()..color = MoonPhasePainter.darkColor);
      }
      return; // 望（满月）：暗面为空，保持全亮
    }

    // 月盈（phase<0.5）亮面在右，月亏（phase>0.5）亮面在左。
    final litOnRight = phase < 0.5;
    final darkPaint = Paint()..color = MoonPhasePainter.darkColor;
    if (c >= 0) {
      // 弦月/娥眉/残月：亮面是「月盘弧 + 界线椭圆弧」围成的月牙；
      // 暗面 = 全盘挖掉这枚月牙（evenOdd）。
      final litCrescent = _crescentPath(center, r, term, onRight: litOnRight);
      final darkPath = Path()
        ..addOval(Rect.fromCircle(center: center, radius: r))
        ..addPath(litCrescent, Offset.zero);
      darkPath.fillType = PathFillType.evenOdd;
      canvas.drawPath(darkPath, darkPaint);
    } else {
      // 凸月/满月：暗面是「月盘弧 + 界线椭圆弧」围成的薄月牙（位于亮面对侧）。
      final darkCrescent =
          _crescentPath(center, r, term, onRight: !litOnRight);
      canvas.drawPath(darkCrescent, darkPaint);
    }
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
      oldDelegate.phase != phase;
}
