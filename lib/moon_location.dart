import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'moon_astronomy.dart';

/// 月相观测位置模式。
enum MoonLocationMode {
  /// 定位获取：读取设备 GPS；失败/拒绝时回退默认北京。
  auto,

  /// 手动输入：使用用户填写的经纬度。
  manual,

  /// 默认北京：天安门坐标，无需任何权限。
  beijing,
}

/// 月相按钮的观测者位置设置：默认北京，允许手动输入经纬度，也允许定位获取。
///
/// 盘面朝向依赖观测纬度与月球时角（经度/时刻），必须知道观测者在哪里。
/// 设置持久化到 SharedPreferences；[observer] 是响应式当前生效位置，
/// 界面监听它即时刷新月相盘面。
class MoonLocation {
  MoonLocation._();

  static const String _modeKey = 'moon_location_mode';
  static const String _latKey = 'moon_location_latitude';
  static const String _lonKey = 'moon_location_longitude';

  /// 默认观测位置：北京（天安门）。
  static const ObserverLocation beijing =
      ObserverLocation(39.9042, 116.4074);

  /// 当前生效的观测位置（GPS 成功后自动更新；界面监听此值重绘月相）。
  static final ValueNotifier<ObserverLocation> observer =
      ValueNotifier<ObserverLocation>(beijing);

  /// 当前模式（持久化，默认北京）。
  static MoonLocationMode mode = MoonLocationMode.beijing;

  /// 手动模式下的经纬度（持久化；初始为北京坐标）。
  static double manualLatitude = beijing.latitude;
  static double manualLongitude = beijing.longitude;

  /// 初始化：读取持久化设置并解析当前观测位置。
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeName = prefs.getString(_modeKey);
      mode = MoonLocationMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => MoonLocationMode.beijing,
      );
      manualLatitude = prefs.getDouble(_latKey) ?? beijing.latitude;
      manualLongitude = prefs.getDouble(_lonKey) ?? beijing.longitude;
    } catch (_) {
      // 读取失败保持默认。
    }
    await resolve();
  }

  /// 按当前模式解析观测位置并刷新 [observer]。
  static Future<void> resolve() async {
    ObserverLocation loc = beijing;
    switch (mode) {
      case MoonLocationMode.auto:
        final gps = await _tryGps();
        loc = gps ?? beijing;
      case MoonLocationMode.manual:
        loc = ObserverLocation(manualLatitude, manualLongitude);
      case MoonLocationMode.beijing:
        loc = beijing;
    }
    observer.value = loc;
  }

  /// 更新模式与手动经纬度，持久化后重新解析。
  static Future<void> update(
    MoonLocationMode nextMode, {
    double? latitude,
    double? longitude,
  }) async {
    mode = nextMode;
    if (latitude != null) {
      manualLatitude = latitude.clamp(-90.0, 90.0);
    }
    if (longitude != null) {
      manualLongitude = longitude.clamp(-180.0, 180.0);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, mode.name);
      await prefs.setDouble(_latKey, manualLatitude);
      await prefs.setDouble(_lonKey, manualLongitude);
    } catch (_) {
      // 写入失败不影响本次生效。
    }
    await resolve();
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
}
