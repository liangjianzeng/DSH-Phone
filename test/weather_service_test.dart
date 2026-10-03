import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/weather_service.dart';

void main() {
  group('WeatherService.kindFromWmo WMO 天气码映射', () {
    test('晴 / 少云 / 阴 / 雾', () {
      expect(WeatherService.kindFromWmo(0, null), WeatherKind.clear);
      expect(WeatherService.kindFromWmo(1, null), WeatherKind.partlyCloudy);
      expect(WeatherService.kindFromWmo(2, null), WeatherKind.partlyCloudy);
      expect(WeatherService.kindFromWmo(3, null), WeatherKind.cloudy);
      expect(WeatherService.kindFromWmo(45, null), WeatherKind.fog);
      expect(WeatherService.kindFromWmo(48, null), WeatherKind.fog);
    });

    test('毛毛雨级别', () {
      for (final code in [51, 53, 55, 56, 57]) {
        expect(WeatherService.kindFromWmo(code, null), WeatherKind.drizzle,
            reason: 'WMO $code 应映射为毛毛雨动效');
      }
    });

    test('雨强分级：小雨/中雨 → 中雨动效，大雨/暴雨 → 大雨动效', () {
      expect(WeatherService.kindFromWmo(61, null), WeatherKind.rain);
      expect(WeatherService.kindFromWmo(63, 1.0), WeatherKind.rain);
      expect(WeatherService.kindFromWmo(80, null), WeatherKind.rain);
      // 大雨（65）、强冻雨（67）、暴雨（82）直接大雨动效。
      expect(WeatherService.kindFromWmo(65, null), WeatherKind.heavyRain);
      expect(WeatherService.kindFromWmo(67, null), WeatherKind.heavyRain);
      expect(WeatherService.kindFromWmo(82, 12.0), WeatherKind.heavyRain);
    });

    test('常规雨码 + 很大降水量 → 升级大雨动效（雨大动效更大）', () {
      expect(WeatherService.kindFromWmo(61, 8.0), WeatherKind.heavyRain);
      expect(WeatherService.kindFromWmo(63, 10.0), WeatherKind.heavyRain);
      expect(WeatherService.kindFromWmo(80, 7.5), WeatherKind.heavyRain);
      // 低于阈值保持常规雨。
      expect(WeatherService.kindFromWmo(63, 5.9), WeatherKind.rain);
    });

    test('雪系天气码', () {
      for (final code in [71, 73, 75, 77, 85, 86]) {
        expect(WeatherService.kindFromWmo(code, null), WeatherKind.snow,
            reason: 'WMO $code 应映射为雪动效');
      }
    });

    test('雷暴天气码', () {
      expect(WeatherService.kindFromWmo(95, null), WeatherKind.thunder);
      expect(WeatherService.kindFromWmo(96, 3.0), WeatherKind.thunder);
      expect(WeatherService.kindFromWmo(99, null), WeatherKind.thunder);
    });

    test('未知码不臆造动效（回退晴，无动效）', () {
      expect(WeatherService.kindFromWmo(42, null), WeatherKind.clear);
      expect(WeatherService.kindFromWmo(-1, null), WeatherKind.clear);
    });

    test('实际无降水时，雨/雷/雪码降级为云系动效（预报码≠实况）', () {
      // 无降水（< 阈值）时不再渲染任何雨雪雷动效。
      expect(WeatherService.kindFromWmo(61, 0.0), WeatherKind.cloudy);
      expect(WeatherService.kindFromWmo(95, 0.0), WeatherKind.cloudy);
      expect(WeatherService.kindFromWmo(71, 0.0), WeatherKind.cloudy);
      expect(WeatherService.kindFromWmo(65, 0.0), WeatherKind.cloudy);
      // 缺省云量回退「阴」；按云量选档位。
      expect(WeatherService.kindFromWmo(95, 0.0, cloudCover: 90),
          WeatherKind.cloudy);
      expect(WeatherService.kindFromWmo(95, 0.0, cloudCover: 50),
          WeatherKind.partlyCloudy);
      expect(WeatherService.kindFromWmo(95, 0.0, cloudCover: 10),
          WeatherKind.clear);
    });

    test('大雨/雷暴码但实测量级很低：按量级降级为雨/毛毛雨', () {
      expect(WeatherService.kindFromWmo(95, 0.2), WeatherKind.drizzle);
      expect(WeatherService.kindFromWmo(95, 0.5), WeatherKind.rain);
      expect(WeatherService.kindFromWmo(65, 0.2), WeatherKind.drizzle);
      // 达到下限时保持大雨/雷暴。
      expect(WeatherService.kindFromWmo(95, 2.0), WeatherKind.thunder);
      expect(WeatherService.kindFromWmo(82, 5.0), WeatherKind.heavyRain);
    });
  });

  group('WeatherService.summaryFromWmo 中文描述', () {
    test('常用码描述正确', () {
      expect(WeatherService.summaryFromWmo(0), '晴');
      expect(WeatherService.summaryFromWmo(3), '阴');
      expect(WeatherService.summaryFromWmo(61), '小雨');
      expect(WeatherService.summaryFromWmo(65), '大雨');
      expect(WeatherService.summaryFromWmo(95), '雷阵雨');
    });

    test('全码表描述非空；未知码给出可读占位', () {
      for (var code = 0; code <= 99; code++) {
        expect(WeatherService.summaryFromWmo(code), isNotEmpty,
            reason: 'WMO $code 描述不应为空');
      }
    });

    test('实际无降水时，降水码描述降级为云系/按量级', () {
      expect(WeatherService.summaryFromWmo(95, precipitation: 0.0), '阴');
      expect(WeatherService.summaryFromWmo(61, precipitation: 0.0), '阴');
      expect(WeatherService.summaryFromWmo(95, precipitation: 0.2), '毛毛雨');
      expect(WeatherService.summaryFromWmo(95, precipitation: 0.5), '小雨');
      expect(WeatherService.summaryFromWmo(95, precipitation: 2.0), '雷阵雨');
      // 按云量选描述档位。
      expect(WeatherService.summaryFromWmo(95, precipitation: 0.0,
          cloudCover: 50), '多云');
      expect(WeatherService.summaryFromWmo(95, precipitation: 0.0,
          cloudCover: 10), '晴');
    });
  });
}
