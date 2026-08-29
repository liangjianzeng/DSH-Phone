import 'dart:async';

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

/// GPS 定位失败原因（用于向用户呈现"为什么没定位到"）。
enum GpsFailure {
  /// 未尝试过 / 成功。
  none,

  /// 权限尚未授予（后台自动尝试时不去弹权限框）。
  permissionNotGranted,

  /// 权限被拒绝。
  permissionDenied,

  /// 权限被永久拒绝（"不再询问"），只能去系统设置开启。
  permissionDeniedForever,

  /// 系统定位服务未开启。
  serviceDisabled,

  /// 获取定位超时 / 无信号（室内、无网络定位时）。
  timeout,

  /// 其他错误（detail 附带原因）。
  error,
}

/// 月相按钮的观测者位置设置：默认北京，允许手动输入经纬度，也允许定位获取。
///
/// 盘面朝向依赖观测纬度与月球时角（经度/时刻），必须知道观测者在哪里。
/// 设置持久化到 SharedPreferences；[observer] 是响应式当前生效位置，
/// 界面监听它即时刷新月相盘面；[statusText] 呈现定位结果/失败原因。
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

  /// 当前模式的实时状态文本（定位结果 / 失败原因回退 / 手动坐标 / 默认北京）。
  /// 界面监听此值呈现定位信息。
  static final ValueNotifier<String> statusText = ValueNotifier<String>('');

  /// 当前模式（持久化，默认北京）。
  static MoonLocationMode mode = MoonLocationMode.beijing;

  /// 手动模式下的经纬度（持久化；初始为北京坐标）。
  static double manualLatitude = beijing.latitude;
  static double manualLongitude = beijing.longitude;

  static bool _gpsOk = false; // 最近一次 GPS 尝试是否成功
  static bool _resolving = false; // 是否正在获取定位
  static GpsFailure _gpsFailure = GpsFailure.none; // 最近失败原因
  static String _gpsFailureDetail = ''; // 其他错误的具体原因

  /// 初始化：读取持久化设置并解析当前观测位置。启动期不弹权限框，
  /// 若保存了 GPS 模式但权限未授，状态会提示用户去设置页重新获取。
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

  /// 按当前模式解析观测位置并刷新 [observer] 与 [statusText]。
  /// [requestPermission] 为 true 时才弹定位权限框（须由用户操作触发）；
  /// 否则只检查权限，未授予时按失败处理并给出提示。
  static Future<void> resolve({bool requestPermission = false}) async {
    _resolving = true;
    statusText.value = _statusLine();
    ObserverLocation loc = beijing;
    try {
      switch (mode) {
        case MoonLocationMode.auto:
          final gps =
              await _tryGps(requestPermission: requestPermission);
          _gpsOk = gps != null;
          loc = gps ?? beijing;
        case MoonLocationMode.manual:
          loc = ObserverLocation(manualLatitude, manualLongitude);
        case MoonLocationMode.beijing:
          loc = beijing;
      }
    } catch (e) {
      // 定位库抛出的 PlatformException 等异常：兜底回退默认北京，
      // 并记录失败原因，避免 _resolving 卡死导致界面永远"正在获取定位…"。
      debugPrint('[DSH] moon location resolve error: $e');
      _gpsOk = false;
      _gpsFailure = GpsFailure.error;
      _gpsFailureDetail = e.toString();
      loc = beijing;
    } finally {
      _resolving = false;
    }
    observer.value = loc;
    statusText.value = _statusLine();
  }

  /// 当前模式的可读状态行：定位结果 / 失败原因回退 / 手动坐标 / 默认北京。
  static String _statusLine() {
    final loc = observer.value;
    switch (mode) {
      case MoonLocationMode.auto:
        if (_resolving) return '正在获取定位…';
        if (_gpsOk) {
          return '已定位：${_coord(loc.latitude, '北纬', '南纬')}，'
              '${_coord(loc.longitude, '东经', '西经')}';
        }
        return '无法获取定位结果（${_failureText()}），'
            '已回退默认北京'
            '（${_coord(beijing.latitude, '北纬', '南纬')}，'
            '${_coord(beijing.longitude, '东经', '西经')}）';
      case MoonLocationMode.manual:
        return '手动位置：${_coord(loc.latitude, '北纬', '南纬')}，'
            '${_coord(loc.longitude, '东经', '西经')}';
      case MoonLocationMode.beijing:
        return '默认北京：${_coord(loc.latitude, '北纬', '南纬')}，'
            '${_coord(loc.longitude, '东经', '西经')}';
    }
  }

  /// 定位失败原因的可读文本。
  static String _failureText() {
    switch (_gpsFailure) {
      case GpsFailure.none:
        return '未知原因';
      case GpsFailure.permissionNotGranted:
        return '未获得定位权限，请在下方重新获取';
      case GpsFailure.permissionDenied:
        return '定位权限被拒绝';
      case GpsFailure.permissionDeniedForever:
        return '定位权限被永久拒绝，请到系统设置→应用→DSH-Phone 开启定位';
      case GpsFailure.serviceDisabled:
        return '系统定位服务未开启';
      case GpsFailure.timeout:
        return '获取超时或无信号（室内可开网络定位）';
      case GpsFailure.error:
        return _gpsFailureDetail.isEmpty ? '定位异常' : _gpsFailureDetail;
    }
  }

  /// 坐标格式化：北/南纬、东/西经，保留两位。
  static String _coord(double v, String positive, String negative) {
    final deg = v.abs().toStringAsFixed(2);
    return v >= 0 ? '$positive$deg°' : '$negative$deg°';
  }

  /// 当前生效位置的紧凑文本（如：北纬31.23°，东经121.47°），用于月相按钮提示。
  static String get observerLabel {
    final loc = observer.value;
    return '${_coord(loc.latitude, '北纬', '南纬')}，'
        '${_coord(loc.longitude, '东经', '西经')}';
  }

  /// 更新模式与手动经纬度，持久化后重新解析（用户操作触发，可弹权限框）。
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
    await resolve(requestPermission: true);
  }

  /// 尝试设备定位；失败时记录 [_gpsFailure] 并返回 null。
  static Future<ObserverLocation?> _tryGps(
      {required bool requestPermission}) async {
    // 1) 权限：先检查，必要时弹框（仅用户操作触发）。
    // checkPermission 在部分设备/系统上可能抛 PlatformException，
    // 这里兜底按"权限未授予"处理，避免整个解析流程中断。
    LocationPermission perm;
    try {
      perm = await Geolocator.checkPermission();
    } catch (e) {
      debugPrint('[DSH] moon location checkPermission error: $e');
      _gpsFailure = GpsFailure.permissionNotGranted;
      _gpsFailureDetail = '';
      return null;
    }
    if (perm == LocationPermission.denied) {
      if (!requestPermission) {
        _gpsFailure = GpsFailure.permissionNotGranted;
        _gpsFailureDetail = '';
        return null;
      }
      try {
        perm = await Geolocator.requestPermission();
      } on PermissionRequestInProgressException {
        _gpsFailure = GpsFailure.permissionNotGranted;
        _gpsFailureDetail = '';
        return null;
      }
      if (perm == LocationPermission.denied) {
        _gpsFailure = GpsFailure.permissionDenied;
        _gpsFailureDetail = '';
        return null;
      }
      if (perm == LocationPermission.deniedForever) {
        _gpsFailure = GpsFailure.permissionDeniedForever;
        _gpsFailureDetail = '';
        return null;
      }
      if (perm == LocationPermission.unableToDetermine) {
        _gpsFailure = GpsFailure.permissionDenied;
        _gpsFailureDetail = '';
        return null;
      }
    }

    // 2) 系统定位服务。
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _gpsFailure = GpsFailure.serviceDisabled;
        _gpsFailureDetail = '';
        return null;
      }
    } on LocationServiceDisabledException {
      _gpsFailure = GpsFailure.serviceDisabled;
      _gpsFailureDetail = '';
      return null;
    }

    // 3) 先取缓存定位（秒级返回）；再取实时定位（30 秒超时）。
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          DateTime.now().difference(last.timestamp) <
              const Duration(minutes: 2)) {
        _gpsFailure = GpsFailure.none;
        _gpsFailureDetail = '';
        return ObserverLocation(last.latitude, last.longitude);
      }
    } catch (_) {
      // 缓存不可用，继续取实时。
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 30),
      );
      _gpsFailure = GpsFailure.none;
      _gpsFailureDetail = '';
      return ObserverLocation(pos.latitude, pos.longitude);
    // 注意 catch 顺序：geolocator 的 LocationServiceDisabledException /
    // PermissionDeniedException 均继承自 TimeoutException，
    // 必须先于 TimeoutException 匹配，否则服务关闭/权限拒绝会被误报为"超时"。
    } on LocationServiceDisabledException {
      _gpsFailure = GpsFailure.serviceDisabled;
      _gpsFailureDetail = '';
      return null;
    } on PermissionDeniedException {
      _gpsFailure = GpsFailure.permissionDenied;
      _gpsFailureDetail = '';
      return null;
    } on TimeoutException {
      _gpsFailure = GpsFailure.timeout;
      _gpsFailureDetail = '';
      return null;
    } catch (e) {
      _gpsFailure = GpsFailure.error;
      _gpsFailureDetail = e.toString();
      return null;
    }
  }
}
