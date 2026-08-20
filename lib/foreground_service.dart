import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务保活封装。
///
/// 隧道 connected 期间启动 Android 前台服务，使 App 在后台/关屏时仍保持
/// 进程与网络访问（并持有 PARTIAL_WAKE_LOCK），SSH 保活定时器得以持续发送，
/// 远端不再因空闲超时断开连接；恢复前台时无需重连。
///
/// 仅在 Android 生效；其它平台（未启用前台服务的桌面/Web 调试）为空操作。
class ForegroundTunnelService {
  ForegroundTunnelService._();
  static final ForegroundTunnelService instance = ForegroundTunnelService._();

  static const String _channelId = 'dsh_phone_tunnel';
  static const String _channelName = 'DSH-Phone 隧道保活';

  bool _started = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 初始化通知/服务选项（应在 runApp 前调用一次；非 Android 平台为空操作）。
  static void init() {
    if (!_isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: '保持 SSH 隧道在后台持续运行',
        // 低优先级静默通知：不响铃、不震动，减少打扰。
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        // 被系统意外终止时自动重启服务，尽量保住隧道。
        isSticky: true,
        visibility: NotificationVisibility.VISIBILITY_PRIVATE,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: true,
        autoRunOnBoot: false,
        // 持有 PARTIAL_WAKE_LOCK：关屏时 CPU 保持运行以继续发送保活。
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// 隧道 connected 时启动前台服务。Android 13+ 首次会请求通知权限，
  /// 被拒绝时服务无法启动（后台保活失效），仅记录日志。
  Future<void> start() async {
    if (!_isAndroid || _started) return;
    try {
      final ok = await FlutterForegroundTask.startService(
        notificationTitle: 'DSH-Phone',
        notificationText: 'SSH 隧道运行中',
      );
      if (ok) {
        _started = true;
        print('[DSH] foreground service started');
      } else {
        print('[DSH] foreground service NOT started '
            '(通知权限未授予，后台保活不可用)');
      }
    } catch (e) {
      print('[DSH] foreground service start error: $e');
    }
  }

  /// 隧道断开/退出时停止前台服务并释放唤醒锁。
  Future<void> stop() async {
    if (!_isAndroid || !_started) return;
    _started = false;
    try {
      await FlutterForegroundTask.stopService();
      print('[DSH] foreground service stopped');
    } catch (e) {
      print('[DSH] foreground service stop error: $e');
    }
  }
}
