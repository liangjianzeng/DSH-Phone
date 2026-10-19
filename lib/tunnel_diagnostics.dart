/// 连接诊断事件总线：把隧道全生命周期事件记进环形缓冲，供 App 内诊断页查看。
///
/// 为什么需要它：真机 + VPN 场景下没有 adb，历史故障只能靠用户复述"提示连不上"，
/// 无法区分 DNS 失败 / 链路不可达 / 半开假死 / 远端服务没起。有了带时间戳的
/// 事件流，一次截图/复制就能定位。
///
/// 纯 Dart、零依赖：[TunnelEvent] 与 [TunnelDiagnostics] 可被单元测试直接驱动。
library;

enum TunnelEventLevel { info, warn, error }

/// 一条诊断事件。[tag] 是子系统标签（connect/probe/transport/forward/monitor…）。
class TunnelEvent {
  const TunnelEvent({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime at;
  final TunnelEventLevel level;
  final String tag;
  final String message;

  String get levelLabel => switch (level) {
        TunnelEventLevel.info => 'I',
        TunnelEventLevel.warn => 'W',
        TunnelEventLevel.error => 'E',
      };

  @override
  String toString() => '[${_hhmmss(at)}] $levelLabel/$tag $message';
}

String _hhmmss(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// 进程内单例环形缓冲（默认保留最近 400 条 ≈ 覆盖一整晚的重连过程）。
class TunnelDiagnostics {
  TunnelDiagnostics._()
      : capacity = defaultCapacity,
        clock = DateTime.now;

  /// 测试用：注入容量与固定时钟，断言事件顺序与导出文本。
  TunnelDiagnostics.forTest(this.capacity, this.clock);

  static const int defaultCapacity = 400;

  /// 进程内单例：隧道是应用级单资源，事件流也应当全局唯一。
  static final TunnelDiagnostics instance = TunnelDiagnostics._();

  final int capacity;
  final List<TunnelEvent> _events = [];

  /// 时间源；生产为 [DateTime.now]。
  final DateTime Function() clock;

  /// 记一条事件（超出容量丢弃最旧）。
  void record(
    TunnelEventLevel level,
    String tag,
    String message, {
    DateTime? at,
  }) {
    _events.add(TunnelEvent(
      at: at ?? clock(),
      level: level,
      tag: tag,
      message: message,
    ));
    while (_events.length > capacity) {
      _events.removeAt(0);
    }
  }

  void info(String tag, String message) =>
      record(TunnelEventLevel.info, tag, message);

  void warn(String tag, String message) =>
      record(TunnelEventLevel.warn, tag, message);

  void error(String tag, String message) =>
      record(TunnelEventLevel.error, tag, message);

  /// 由旧 [debugPrint] 调用点复用：既进缓冲，也保持 logcat 可见。
  void log(String tag, String message, {TunnelEventLevel level = TunnelEventLevel.info}) =>
      record(level, tag, message);

  /// 时间正序的快照副本。
  List<TunnelEvent> get events => List.unmodifiable(_events);

  int get total => _events.length;

  int countWhere(bool Function(TunnelEvent) test) =>
      _events.where(test).length;

  void clear() => _events.clear();

  /// 导出为可复制/分享的纯文本（诊断页"复制全部"用）。
  String exportText({String header = ''}) {
    final b = StringBuffer();
    if (header.isNotEmpty) {
      b.writeln(header);
      b.writeln('-' * 40);
    }
    for (final e in _events) {
      b.writeln(e.toString());
    }
    return b.toString();
  }
}
