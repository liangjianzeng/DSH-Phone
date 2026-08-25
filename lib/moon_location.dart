import 'package:geolocator/geolocator.dart';

import 'moon_astronomy.dart';

/// 观测者位置解析：优先设备定位，失败时回退到「时区推导经度 + 默认纬度」。
///
/// 月相按钮的盘面朝向依赖观测纬度与月球时角（经度/时刻），必须知道
/// 观测者在哪里；结果缓存在内存，后续直接用。
class MoonLocation {
  MoonLocation._();

  static ObserverLocation? _cached;

  static const double _fallbackLatitude = 35.0; // 北半球中纬默认值（如华北）

  /// 同步回退位置：经度由设备时区偏移推导（每时区 15°），纬度用默认值。
  static ObserverLocation fallback() {
    final offsetMinutes = DateTime.now().timeZoneOffset.inMinutes;
    return ObserverLocation(_fallbackLatitude, offsetMinutes / 60.0 * 15.0);
  }

  /// 解析观测者位置（异步，首次调用可能请求定位权限）。
  static Future<ObserverLocation> resolve() async {
    final cached = _cached;
    if (cached != null) return cached;

    // 1) 设备定位：GPS/网络。
    final gps = await _tryGps();
    if (gps != null) {
      _cached = gps;
      return gps;
    }

    // 2) 回退：时区推导经度 + 默认纬度。
    _cached = fallback();
    return _cached!;
  }

  /// 尝试设备定位；失败（权限拒绝/定位关闭/无信号）返回 null。
  static Future<ObserverLocation?> _tryGps() async {
    try {
      final service = await Geolocator.isLocationServiceEnabled();
      if (!service) return null;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        final requested = await Geolocator.requestPermission();
        if (requested == LocationPermission.denied ||
            requested == LocationPermission.deniedForever ||
            requested == LocationPermission.unableToDetermine) {
          return null;
        }
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      return ObserverLocation(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// 强制重新解析（如用户设置变更后）。
  static Future<ObserverLocation> reResolve() async {
    _cached = null;
    return resolve();
  }
}
