import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/moon_astronomy.dart';
import 'package:dsh_phone/sun_times.dart';

void main() {
  // 观测位置：北京（天安门附近）
  const beijing = ObserverLocation(39.9042, 116.4074);

  group('SunTimes.compute 与权威数据源比对', () {
    // Open-Meteo（2026-10-02 查询）：北京日出 06:11、日落 17:55（北京时间，
    // UTC+8 → 日出 22:11 UTC 前一日、日落 09:55 UTC）。NOAA 低精度公式与
    // 精确模型允许 ±6 分钟偏差。
    test('北京 2026-10-02：日出 ≈ 06:11、日落 ≈ 17:55（当地时间）', () {
      final sun = SunTimes.compute(
        DateTime.utc(2026, 10, 2, 4, 0), // 当日任意时刻
        beijing,
      );
      expect(sun.hasEvents, isTrue);
      // 直接断言 UTC 时刻（避免依赖执行环境的本地时区）：
      // 06:11 CST = 22:11 UTC（前一日），17:55 CST = 09:55 UTC。
      final sunrise = sun.sunriseUtc!;
      final sunset = sun.sunsetUtc!;
      expect(sunrise.hour * 60 + sunrise.minute, closeTo(22 * 60 + 11, 6));
      expect(sunset.hour * 60 + sunset.minute, closeTo(9 * 60 + 55, 6));
    });

    test('同一 UTC 日内不同时刻调用结果一致（确定性）', () {
      final a = SunTimes.compute(DateTime.utc(2026, 10, 2, 0, 15), beijing);
      final b = SunTimes.compute(DateTime.utc(2026, 10, 2, 23, 45), beijing);
      expect(a.sunriseUtc, b.sunriseUtc);
      expect(a.sunsetUtc, b.sunsetUtc);
    });
  });

  group('SunTimes.isDaytimeAt 昼夜判别', () {
    test('北京正午为白天、午夜为夜间', () {
      // 12:00 北京时间 = 04:00 UTC。
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 2, 4, 0), beijing),
        isTrue,
      );
      // 00:00 北京时间 = 前一日 16:00 UTC。
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 1, 16, 0), beijing),
        isFalse,
      );
    });

    test('日出后/日落前的邻域切换正确', () {
      // 日出 ≈ 06:11 CST（22:11 UTC 前一日）：06:30 应为白天，05:30 应为夜间。
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 1, 22, 30), beijing),
        isTrue,
      );
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 1, 21, 30), beijing),
        isFalse,
      );
      // 日落 ≈ 17:55 CST（09:55 UTC）：17:30 白天，18:30 夜间。
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 2, 9, 30), beijing),
        isTrue,
      );
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 10, 2, 10, 30), beijing),
        isFalse,
      );
    });
  });

  group('SunTimes 极昼极夜边界', () {
    // Tromsø（特罗姆瑟，69.65°N, 18.96°E）：极圈内。
    const tromso = ObserverLocation(69.6492, 18.9553);

    test('夏季极昼：无日出日落事件，正午为白天', () {
      final sun = SunTimes.compute(DateTime.utc(2026, 7, 15, 12), tromso);
      expect(sun.hasEvents, isFalse);
      expect(sun.polarDay, isTrue);
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 7, 15, 12), tromso),
        isTrue,
      );
    });

    test('冬季极夜：无日出日落事件，正午为夜间', () {
      final sun = SunTimes.compute(DateTime.utc(2026, 1, 5, 12), tromso);
      expect(sun.hasEvents, isFalse);
      expect(sun.polarDay, isFalse);
      expect(
        SunTimes.isDaytimeAt(DateTime.utc(2026, 1, 5, 12), tromso),
        isFalse,
      );
    });
  });
}
