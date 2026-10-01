import 'dart:math' as math;

import 'moon_astronomy.dart';

/// 某地某日的日出日落时刻（UTC）。极昼/极夜时 [sunriseUtc]/[sunsetUtc] 为 null。
class SunTimes {
  const SunTimes({
    required this.sunriseUtc,
    required this.sunsetUtc,
    required this.polarDay,
  });

  /// 日出时刻（UTC）；极昼/极夜（当日太阳不升不落）时为 null。
  final DateTime? sunriseUtc;

  /// 日落时刻（UTC）；极昼/极夜时为 null。
  final DateTime? sunsetUtc;

  /// 是否极昼（当日太阳整日在地平线上）。false 且无事件 = 极夜或该纬度当日全天黑夜。
  final bool polarDay;

  bool get hasEvents => sunriseUtc != null && sunsetUtc != null;

  /// [nowUtc] 是否处于白天。
  ///
  /// 直接用太阳地平高度判定（高度 > −0.833°，即日出~日落之间，含晨昏蒙影
  /// 的标准定义），比按时段比较更稳健——不受「UTC 日边界」「极昼极夜」
  /// 等特殊日期影响。
  static bool isDaytimeAt(DateTime nowUtc, ObserverLocation observer) {
    final alt = MoonAstronomy.sunAltitudeDeg(nowUtc, observer);
    return alt > -0.833;
  }

  /// 计算 [baseUtc] 所在 UTC 日的日出日落（NOAA 通用太阳计算，低精度公式，
  /// 与天文年历偏差约 ±2 分钟，满足昼夜判别与提示展示）。
  static SunTimes compute(DateTime baseUtc, ObserverLocation observer) {
    final dayStart = DateTime.utc(baseUtc.year, baseUtc.month, baseUtc.day);

    // 太阳赤纬（弧度）与均时差（分钟）：NOAA 级数近似，按正午取值。
    final (declRad, eqTimeMin) = _declinationAndEqTime(dayStart);

    // 时角 ha（度）：太阳高度恰为 −0.833°（几何日出，含大气折射与太阳视半径）。
    final latRad = observer.latitude * math.pi / 180.0;
    final cosHa = (math.cos(90.833 * math.pi / 180.0) -
            math.sin(latRad) * math.sin(declRad)) /
        (math.cos(latRad) * math.cos(declRad));
    if (cosHa > 1.0) {
      // 时角无解：太阳整日低于地平线（极夜/极地黑夜）。
      return const SunTimes(sunriseUtc: null, sunsetUtc: null, polarDay: false);
    }
    if (cosHa < -1.0) {
      // 时角无解：太阳整日高于地平线（极昼）。
      return const SunTimes(sunriseUtc: null, sunsetUtc: null, polarDay: true);
    }
    final haDeg =
        math.acos(cosHa) * 180.0 / math.pi; // 0~180，半昼长的 15°/小时表达

    // 太阳中天（正午）UTC 分钟数：正午 720 − 4·东经（经度每度 4 分钟）− 均时差。
    final noonMin = 720.0 - 4.0 * observer.longitude - eqTimeMin;
    final sunriseMin = noonMin - haDeg * 4.0; // 1° 时角 = 4 分钟
    final sunsetMin = noonMin + haDeg * 4.0;
    return SunTimes(
      sunriseUtc: dayStart.add(Duration(milliseconds: (sunriseMin * 60000).round())),
      sunsetUtc: dayStart.add(Duration(milliseconds: (sunsetMin * 60000).round())),
      polarDay: false,
    );
  }

  /// 太阳赤纬（弧度）与均时差（分钟）：NOAA 通用计算（Spencer 级数）。
  /// [dayStart] 只取 UTC 年积日。
  static (double, double) _declinationAndEqTime(DateTime dayStart) {
    final startOfYear = DateTime.utc(dayStart.year, 1, 1);
    final dayOfYear =
        dayStart.difference(startOfYear).inDays.toDouble(); // 0-based
    // NOAA 公式 γ = 2π/365 × (day_of_year − 1 + (hour − 12)/24)；
    // hour 取正午 12 时整归零，即 γ = 2π/365 × day_of_year（0-based）。
    final g = 2 * math.pi / 365.0 * dayOfYear;
    final eqTime = 229.18 *
        (0.000075 +
            0.001868 * math.cos(g) -
            0.032077 * math.sin(g) -
            0.014615 * math.cos(2 * g) -
            0.040849 * math.sin(2 * g));
    final decl = 0.006918 -
        0.399912 * math.cos(g) +
        0.070257 * math.sin(g) -
        0.006758 * math.cos(2 * g) +
        0.000907 * math.sin(2 * g) -
        0.002697 * math.cos(3 * g) +
        0.00148 * math.sin(3 * g);
    return (decl, eqTime);
  }
}
