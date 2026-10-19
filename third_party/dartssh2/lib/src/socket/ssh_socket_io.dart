import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/src/socket/ssh_socket.dart';

Future<SSHSocket> connectNativeSocket(
  String host,
  int port, {
  Duration? timeout,
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  // [fork] 打开 TCP_NODELAY：上游这里什么都没设。SSH 隧道承载的是交互式
  // 请求（点击→XHR→渲染），Nagle 与对端延迟确认叠加会带来几十毫秒级的
  // 额外往返延迟，在 VPN/移动网络这种本来就抖的链路上尤其明显。
  // 失败不影响连接本身，忽略即可（部分平台/权限下可能抛错）。
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
  return _SSHNativeSocket._(socket);
}

class _SSHNativeSocket implements SSHSocket {
  final Socket _socket;

  _SSHNativeSocket._(this._socket);

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() {
    _socket.destroy();
  }

  @override
  String toString() {
    final address = '${_socket.remoteAddress.host}:${_socket.remotePort}';
    return '_SSHNativeSocket($address)';
  }
}
