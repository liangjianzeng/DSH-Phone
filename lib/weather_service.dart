import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'moon_location.dart';

/// 天气种类（驱动相机按钮周边的动效）。
enum WeatherKind {
  /// 晴：无动效。
  clear,

  /// 少云/局部多云：一朵小云。
  partlyCloudy,

  /// 阴/多云：多朵云。
  cloudy,

  /// 雾：漂移的雾带。
  fog,

  /// 毛毛雨/小雨：细密小雨丝。
  drizzle,

  /// 中雨：常规雨滴。
  rain,

  /// 大雨/暴雨/雷暴级别降水：更密更长更快的雨。
  heavyRain,

  /// 雪：飘落的雪花。
  snow,

  /// 雷阵雨：大雨 + 云层闪电。
  thunder,
}

/// 一次天气查询的结果快照。
class WeatherInfo {
  const WeatherInfo({
    required this.kind,
    required this.wmoCode,
    required this.summary,
    this.temperature,
    this.precipitation,
    required this.fetchedAt,
  });

  /// 动效种类。
  final WeatherKind kind;

  /// WMO 标准天气码（原始值，便于诊断）。
  final int wmoCode;

  /// 中文天气描述（如「中雨」）。
  final String summary;

  /// 气温（°C），接口缺失时为 null。
  final double? temperature;

  /// 当前小时降水量（mm），接口缺失时为 null。
  final double? precipitation;

  /// 查询完成时刻（UTC）。
  final DateTime fetchedAt;
}

/// 天气能力：按月相观测位置（[MoonLocation] 的经纬度）查询真实天气，
/// 驱动相机按钮周边的天气动效。
///
/// 数据源 **Open-Meteo**（https://open-meteo.com）：免费、免 API Key、HTTPS、
/// 无需注册，返回 WMO 标准天气码与降水强度——国内可直连，稳定可靠。
/// 查询节奏：启动时一次 + 之后每小时一次；观测位置变化时去抖重查。
/// 设置页可整体开关（默认开启）：关闭即停止请求并清空当前天气。
class WeatherService {
  WeatherService._();

  static const String _enabledKey = 'weather_effects_enabled';
  static const String _apiHost = 'api.open-meteo.com';
  static const String _apiPath = '/v1/forecast';
  static const Duration _refreshInterval = Duration(hours: 1);
  static const Duration _httpTimeout = Duration(seconds: 12);

  /// 观测位置变化重查的去抖时长（避免手动输入经纬度时逐键触发）。
  static const Duration _locationDebounce = Duration(seconds: 3);

  /// 视为「同一位置」的坐标容差（度，约 1km）。
  static const double _sameLocationTolerance = 0.01;

  /// 当前生效天气（null = 尚未查到 / 已关闭；界面监听即时更新动效）。
  static final ValueNotifier<WeatherInfo?> current =
      ValueNotifier<WeatherInfo?>(null);

  /// 最近一次查询的状态文本（设置页呈现：天气+温度+更新时间 / 失败原因）。
  static final ValueNotifier<String> statusText = ValueNotifier<String>('');

  /// 是否启用（持久化，默认开启）。关闭后停止定时刷新并清空 [current]。
  static bool enabled = true;

  static Timer? _hourlyTimer;
  static Timer? _locationDebounceTimer;
  static bool _inited = false;

  /// 上次成功查询使用的坐标：位置几乎未变时跳过重查。
  static double? _lastFetchedLat;
  static double? _lastFetchedLon;

  /// 初始化：读取持久化开关；启用时立即查询并启动每小时定时器，
  /// 同时监听观测位置变化（去抖后坐标真正变化才重查）。
  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_enabledKey) ?? true;
    } catch (_) {
      // 读取失败保持默认开启。
    }
    MoonLocation.observer.addListener(_onObserverMoved);
    if (enabled) _startFetchLoop();
  }

  /// 设置开关（设置页调用）：持久化并启停查询。
  static Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {
      // 写入失败不影响本次生效。
    }
    if (value) {
      _startFetchLoop();
    } else {
      _hourlyTimer?.cancel();
      _hourlyTimer = null;
      _locationDebounceTimer?.cancel();
      _locationDebounceTimer = null;
      current.value = null;
      statusText.value = '天气动效已关闭';
    }
  }

  /// 启动查询循环：立即查一次 + 每小时定时刷新。
  static void _startFetchLoop() {
    _hourlyTimer?.cancel();
    refresh();
    _hourlyTimer = Timer.periodic(_refreshInterval, (_) => refresh());
  }

  /// 观测位置变化回调：坐标真正变化才去抖重查。
  static void _onObserverMoved() {
    if (!enabled) return;
    final loc = MoonLocation.observer.value;
    if (_lastFetchedLat != null &&
        (loc.latitude - _lastFetchedLat!).abs() < _sameLocationTolerance &&
        (loc.longitude - _lastFetchedLon!).abs() < _sameLocationTolerance) {
      return;
    }
    _locationDebounceTimer?.cancel();
    _locationDebounceTimer = Timer(_locationDebounce, () {
      if (enabled) refresh();
    });
  }

  /// 立即按当前观测位置查询一次。失败时保留上次结果（动效不闪断），
  /// 状态行呈现原因，等下一小时定时（或用户手动刷新）重试。
  static Future<void> refresh() async {
    if (!enabled) return;
    final loc = MoonLocation.observer.value;
    statusText.value = '正在查询天气…';
    try {
      final info = await _fetch(loc.latitude, loc.longitude);
      current.value = info;
      _lastFetchedLat = loc.latitude;
      _lastFetchedLon = loc.longitude;
      final local = info.fetchedAt.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');
      final temp =
          info.temperature == null ? '' : ' ${info.temperature!.round()}°C';
      statusText.value = '${info.summary}$temp·$hh:$mm 更新';
    } catch (e) {
      debugPrint('[DSH] weather fetch error: $e');
      statusText.value =
          '天气查询失败（${_briefError(e)}），已保留上次效果，稍后自动重试';
    }
  }

  /// 请求 Open-Meteo 当前天气（WMO 码 + 温度 + 降水量）。
  static Future<WeatherInfo> _fetch(double lat, double lon) async {
    final uri = Uri.https(_apiHost, _apiPath, {
      'latitude': lat.toStringAsFixed(4),
      'longitude': lon.toStringAsFixed(4),
      'current': 'weather_code,temperature_2m,precipitation,cloud_cover',
      'timezone': 'auto',
    });
    final client = HttpClient()..connectionTimeout = _httpTimeout;
    try {
      final request = await client
          .openUrl('GET', uri)
          .timeout(_httpTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_httpTimeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}',
            uri: uri);
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_httpTimeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final currentBlock = json['current'] as Map<String, dynamic>?;
      if (currentBlock == null) {
        throw const FormatException('响应缺少 current 字段');
      }
      final code = (currentBlock['weather_code'] as num?)?.toInt();
      if (code == null) {
        throw const FormatException('响应缺少 weather_code');
      }
      final precip = (currentBlock['precipitation'] as num?)?.toDouble();
      return WeatherInfo(
        kind: kindFromWmo(code, precip),
        wmoCode: code,
        summary: summaryFromWmo(code),
        temperature: (currentBlock['temperature_2m'] as num?)?.toDouble(),
        precipitation: precip,
        fetchedAt: DateTime.now().toUtc(),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// WMO 标准天气码 → 动效种类。[precipitation]（mm/h）用于在常规雨码上
  /// 识别实际更强的降水（阵性降水码 61/63 但雨强很大时升级为大雨动效）。
  static WeatherKind kindFromWmo(int code, double? precipitation) {
    switch (code) {
      case 0:
        return WeatherKind.clear;
      case 1:
      case 2:
        return WeatherKind.partlyCloudy;
      case 3:
        return WeatherKind.cloudy;
      case 45:
      case 48:
        return WeatherKind.fog;
      case 51: // 毛毛雨
      case 53:
      case 55:
      case 56: // 冻毛毛雨
      case 57:
        return WeatherKind.drizzle;
      case 61: // 小雨
      case 63: // 中雨
      case 66: // 冻雨
      case 80: // 阵雨
        if (precipitation != null && precipitation >= 6.0) {
          return WeatherKind.heavyRain;
        }
        return WeatherKind.rain;
      case 65: // 大雨
      case 67: // 强冻雨
      case 82: // 暴雨
        return WeatherKind.heavyRain;
      case 71: // 小雪
      case 73: // 中雪
      case 75: // 大雪
      case 77: // 雪粒
      case 85: // 阵雪
      case 86: // 强阵雪
        return WeatherKind.snow;
      case 95: // 雷阵雨
      case 96: // 雷阵雨伴冰雹
      case 99:
        return WeatherKind.thunder;
      default:
        return WeatherKind.clear; // 未知码不臆造动效
    }
  }

  /// WMO 标准天气码 → 中文描述（设置页状态行展示）。
  static String summaryFromWmo(int code) {
    const table = {
      0: '晴',
      1: '大部晴朗',
      2: '局部多云',
      3: '阴',
      45: '雾',
      48: '冻雾',
      51: '轻毛毛雨',
      53: '毛毛雨',
      55: '浓毛毛雨',
      56: '冻毛毛雨',
      57: '浓冻毛毛雨',
      61: '小雨',
      63: '中雨',
      65: '大雨',
      66: '冻雨',
      67: '强冻雨',
      71: '小雪',
      73: '中雪',
      75: '大雪',
      77: '雪粒',
      80: '阵雨',
      81: '强阵雨',
      82: '暴雨',
      85: '阵雪',
      86: '强阵雪',
      95: '雷阵雨',
      96: '雷阵雨伴冰雹',
      99: '强雷阵雨伴冰雹',
    };
    return table[code] ?? '天气码 $code';
  }

  /// 异常摘要（去掉堆栈类冗长信息，状态行可读）。
  static String _briefError(Object e) {
    final text = e.toString();
    if (text.length <= 60) return text;
    return '${text.substring(0, 60)}…';
  }
}
