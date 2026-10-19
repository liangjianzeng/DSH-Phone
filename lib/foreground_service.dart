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

  // 「期望态」与「实际态」分开维护，并把平台调用串成一条链串行下发。
  //
  // 原来只有 `_started`，而且是 **await 之后**才置位，`stop()` 又用 `if (!_started)
  // return` 早退，于是 `disconnect()`→`connect()` 紧邻时会出现两种事故：
  //  · `stop()` 看到 `_started == false`（start 还在 await 中）直接 return = 根本没停，
  //    随后在途的 start 把 `_started` 置真 → 通知和 PARTIAL_WAKE_LOCK 永久残留；
  //  · 反序则服务已停但 `_started == true`，之后每次 `start()` 都被 `if (_started)
  //    return` 吞掉 → **整个会话没有前台服务**，而后台重连恰恰是最怕被 Doze 打断的
  //    环节（正是这次隧道整改要保的东西）。
  bool _started = false;
  bool _want = false;
  Future<void> _chain = Future<void>.value();

  /// 需要保持后台保活时调用（隧道"想连且非主动断开"期间）。
  ///
  /// Android 13+ 首次会请求通知权限，被拒绝时服务无法启动（后台保活失效），仅记日志。
  Future<void> start() {
    if (!_isAndroid) return Future<void>.value();
    _want = true;
    return _enqueue();
  }

  /// 不再需要保活时调用（主动断开 / 退出）。幂等，可安全地紧接在 [start] 之后。
  Future<void> stop() {
    if (!_isAndroid) return Future<void>.value();
    _want = false;
    return _enqueue();
  }

  /// 把所有平台调用排进同一条链：并发的 start/stop 只按"最后一次表达的期望"落地。
  Future<void> _enqueue() {
    _chain = _chain.then((_) => _apply()).catchError((Object e) {
      debugPrint('[DSH] foreground service error: $e');
    });
    return _chain;
  }

  Future<void> _apply() async {
    if (_want == _started) return; // 已符合期望（含"本来就没起、也不需要起"）
    if (_want) {
      try {
        final ok = await FlutterForegroundTask.startService(
          notificationTitle: 'DSH-Phone',
          notificationText: 'SSH 隧道运行中',
        );
        _started = ok;
        if (ok) {
          debugPrint('[DSH] foreground service started');
        } else {
          debugPrint('[DSH] foreground service NOT started '
              '(通知权限未授予，后台保活不可用)');
        }
      } catch (e) {
        _started = false;
        debugPrint('[DSH] foreground service start error: $e');
      }
      return;
    }
    try {
      await FlutterForegroundTask.stopService();
      debugPrint('[DSH] foreground service stopped');
    } catch (e) {
      debugPrint('[DSH] foreground service stop error: $e');
    }
    // 无论平台调用是否抛错，期望都是"不运行"：置假以免 wakelock 悄悄留着。
    _started = false;
  }
}
