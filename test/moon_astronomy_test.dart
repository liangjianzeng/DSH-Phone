import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/moon_astronomy.dart';

void main() {
  // 观测位置：北京（天安门附近）
  const beijing = ObserverLocation(39.9, 116.4);

  group('MoonAstronomy.compute 已知月相日期', () {
    test('2024-01-25 满月：照明度接近 1，相位接近 0.5', () {
      // 2024-01-25 17:54 UTC 为满月
      final obs =
          MoonAstronomy.compute(DateTime.utc(2024, 1, 25, 17, 54), beijing);
      expect(obs.illumination, closeTo(1.0, 0.02));
      expect(obs.phase01, closeTo(0.5, 0.03));
    });

    test('2024-02-09 新月：照明度接近 0，相位接近 0', () {
      // 2024-02-09 22:59 UTC 为新月
      final obs =
          MoonAstronomy.compute(DateTime.utc(2024, 2, 9, 22, 59), beijing);
      expect(obs.illumination, closeTo(0.0, 0.02));
      expect(obs.phase01 % 1.0, closeTo(0.0, 0.03));
    });

    test('2024-04-08 满月：照明度接近 1', () {
      // 2024-04-08 18:21 UTC 为满月
      final obs =
          MoonAstronomy.compute(DateTime.utc(2024, 4, 8, 18, 21), beijing);
      expect(obs.illumination, closeTo(1.0, 0.02));
    });
  });

  group('月相名称映射', () {
    test('朔望周期内名称覆盖八个相', () {
      // 以 2024-02-09 新月为起点，每 ~3.7 天采样一次
      final names = <String>{};
      final start = DateTime.utc(2024, 2, 9, 22, 59);
      for (var i = 0; i < 8; i++) {
        final obs =
            MoonAstronomy.compute(start.add(Duration(hours: i * 88)), beijing);
        names.add(obs.name);
      }
      // 8 相中至少出现 7 种不同名称（避免边界采样恰好重合）
      expect(names.length, greaterThanOrEqualTo(7));
    });
  });

  group('数值边界', () {
    test('照明度始终在 0..1 内', () {
      final start = DateTime.utc(2024, 2, 9);
      for (var i = 0; i < 30; i++) {
        final obs =
            MoonAstronomy.compute(start.add(Duration(days: i)), beijing);
        expect(obs.illumination, inInclusiveRange(0.0, 1.0));
        expect(obs.phase01, inInclusiveRange(0.0, 1.0));
      }
    });

    test('倾角归一化到 -180..180 度', () {
      final obs =
          MoonAstronomy.compute(DateTime.utc(2024, 3, 15, 12, 0), beijing);
      expect(obs.tiltDeg, inInclusiveRange(-180.0, 180.0));
    });

    test('南半球观测不崩溃（悉尼）', () {
      const sydney = ObserverLocation(-33.9, 151.2);
      final obs =
          MoonAstronomy.compute(DateTime.utc(2024, 6, 15, 12, 0), sydney);
      expect(obs.illumination, inInclusiveRange(0.0, 1.0));
    });
  });
}
