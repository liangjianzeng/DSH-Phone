import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// AI 智能体任务熄屏通知。
///
/// 由 WebView 注入的任务状态桥触发：任务开始 → 常驻通知「DSH 任务进行中」；
/// 任务结束 → 取消进行中通知并推送「DSH 任务已完成」（响铃 + 震动）。
/// 通知通道声明为 HIGH 重要度 + PUBLIC 可见性，熄屏/锁屏下也能看到。
///
/// 熄屏可用性依赖前台服务保活（隧道 connected 期间进程与 WebView 存活），
/// 因此关屏时状态桥依然能触发通知。
class TaskNotifier {
  TaskNotifier._();
  static final TaskNotifier instance = TaskNotifier._();

  static const String _channelId = 'dsh_phone_tasks';
  static const String _channelName = 'DSH 任务通知';
  static const int _runningId = 1001;
  static const int _doneId = 1002;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  DateTime? _runningSince;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 初始化通知通道与权限（应在 runApp 前调用一次；非 Android 为空操作）。
  Future<void> init() async {
    if (!_isAndroid) return;
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      // 点击通知：App 前台即 DSH 界面，无需额外跳转。
      onDidReceiveNotificationResponse: (response) {
        debugPrint('[DSH] task notification tapped: ${response.id}');
      },
    );
    // Android 13+ 通知运行时权限；拒绝也不阻塞，通知静默不显示。
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[DSH] task notifier permission error: $e');
    }
    _ready = true;
    debugPrint('[DSH] task notifier ready');
  }

  /// 任务开始：显示常驻「任务进行中」（无音、低打扰，可被完成通知替换）。
  Future<void> showRunning() async {
    if (!_ready) return;
    _runningSince = DateTime.now();
    await _plugin.show(
      _runningId,
      'DSH 任务进行中',
      '智能体正在执行任务…',
      _details(ongoing: true, playSound: false, enableVibration: false),
    );
  }

  /// 任务结束：取消进行中通知，推送「任务已完成」（响铃 + 震动，锁屏可见）。
  Future<void> showCompleted() async {
    if (!_ready) return;
    await _plugin.cancel(_runningId);
    final elapsed = _runningSince == null
        ? null
        : DateTime.now().difference(_runningSince!);
    final body = elapsed == null || elapsed.inSeconds < 1
        ? '智能体任务执行完成'
        : '执行耗时 ${_durationText(elapsed)}';
    await _plugin.show(
      _doneId,
      'DSH 任务已完成',
      body,
      _details(ongoing: false, playSound: true, enableVibration: true),
    );
  }

  /// 页面导航/重载时调用：取消可能残留的「进行中」通知并复位计时基准。
  /// （导航后桥会重新对齐状态，若任务仍在运行会再次上报进行中。）
  Future<void> reset() async {
    _runningSince = null;
    if (!_ready) return;
    await _plugin.cancel(_runningId);
  }

  NotificationDetails _details({
    required bool ongoing,
    required bool playSound,
    required bool enableVibration,
  }) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'AI 智能体任务进行中/完成提醒（熄屏可见）',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.public, // 锁屏展示内容
          ongoing: ongoing, // 进行中：常驻；完成：可滑动清除
          autoCancel: !ongoing,
          playSound: playSound,
          enableVibration: enableVibration,
        ),
      );

  String _durationText(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '$s秒';
    final m = s ~/ 60;
    if (m < 60) return '$m分${s % 60}秒';
    return '${m ~/ 60}时${m % 60}分';
  }
}
