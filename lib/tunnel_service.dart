import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'config.dart';

/// 隧道连接状态。
enum TunnelStatus { idle, connecting, connected, failed, disconnected }

/// 负责建立 SSH 隧道：把手机 `127.0.0.1:<localPort>` 转发到远程
/// `127.0.0.1:3080`（DSH Web UI），并做 SSH 保活。
///
/// 同一时刻只激活一路隧道（WebView 同一时刻加载一个实例），
/// 通过 [activeProfileIndex] 记录当前连接的实例索引。
class TunnelService {
  TunnelService._();
  static final TunnelService instance = TunnelService._();

  final StreamController<TunnelStatus> _statusController =
      StreamController<TunnelStatus>.broadcast();

  SSHClient? _client;
  ServerSocket? _server;
  bool _disposed = false;
  bool _connecting = false;

  /// 当前激活（已连接/正在连接）的实例索引，null 表示无。
  int? _activeProfileIndex;
  int? get activeProfileIndex => _activeProfileIndex;

  TunnelStatus _status = TunnelStatus.idle;
  TunnelStatus get status => _status;

  Stream<TunnelStatus> get statusStream => _statusController.stream;

  void _setStatus(TunnelStatus s) {
    _status = s;
    if (!_disposed) _statusController.add(s);
  }

  /// 建立隧道。已连接或正在连接时幂等返回，避免重复/并发连接造成死循环。
  /// [profileIndex] 为当前激活实例索引（用于记录），可空。
  Future<void> connect(SSHConfig config, {int? profileIndex}) async {
    // 已在连接中：忽略并发调用
    if (_connecting) return;
    // 已连接且配置未变：无需重连
    if (_status == TunnelStatus.connected) return;

    _connecting = true;
    try {
      await _disconnectInternal();

      _activeProfileIndex = profileIndex;
      _setStatus(TunnelStatus.connecting);
      print('[DSH] connecting to ${config.host}:${config.sshPort} '
          '(auth=${config.authType}) ...');

      // 1) 建立底层 TCP 到 SSH 服务器
      final socket = await SSHSocket.connect(config.host, config.sshPort,
          timeout: const Duration(seconds: 15));

      // 2) 认证：密钥优先，密码兜底
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;

      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest:
            config.useKey ? null : () async => config.password,
        // SSH 保活：每 10s 发一次 keep-alive，降低移动网络空闲断连概率
        keepAliveInterval: const Duration(seconds: 10),
        // 信任用户自建的主机（手机端无 known_hosts）
        onVerifyHostKey: (hostkeyType, fingerprint) => true,
      );

      _client = client;

      // 传输异常/断开时通知，并清理资源
      client.done.then(
        (_) => _onTransportClosed(client),
        onError: (_) => _onTransportClosed(client, failed: true),
      );

      // 3) 等待认证完成
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        print('[DSH] SSH authentication timed out');
        throw const SocketException('SSH 认证超时');
      });
      print('[DSH] authenticated, opening local tunnel on '
          '127.0.0.1:${config.localPort}');

      // 4) 本地监听端口
      _server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, config.localPort);
      _server!.listen(_handleLocalConnection);

      print('[DSH] tunnel up: 127.0.0.1:${config.localPort} -> '
          '127.0.0.1:3080');
      _setStatus(TunnelStatus.connected);
    } catch (e) {
      print('[DSH] connect failed: $e');
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// 传输关闭时的统一清理：仅当仍是当前 client 才处理，避免旧连接误改状态。
  void _onTransportClosed(SSHClient client, {bool failed = false}) {
    if (_client != client) return;
    print('[DSH] transport closed'
        '${failed ? ' (with error)' : ''}');
    _client = null;
    _activeProfileIndex = null;

    final server = _server;
    _server = null;
    server?.close();

    _setStatus(failed ? TunnelStatus.failed : TunnelStatus.disconnected);
  }

  /// 处理一条本地 TCP 连接：打开远程直连隧道并双向透传。
  void _handleLocalConnection(Socket localSocket) {
    _handleForward(localSocket);
  }

  Future<void> _handleForward(Socket local) async {
    final client = _client;
    if (client == null) {
      local.destroy();
      return;
    }
    try {
      // 远程 DSH 监听 127.0.0.1:3080
      final forward = await client.forwardLocal('127.0.0.1', 3080);
      _pipe(local, forward);
    } catch (_) {
      local.destroy();
    }
  }

  /// 双向透传（不自我节流）。
  ///
  /// 早期版本曾加入"有界背压"（在途超过阈值即暂停源、周期恢复），但
  /// dartssh2 的 sink 与 Dart Socket 都不提供逐块消费回调，导致"在途"
  /// 计数只增不减：一旦超过阈值就永久陷入每 120ms 只转发一块的节流，
  /// 吞吐骤降至 ~267KB/s，大体积加载直接超时。
  ///
  /// 这里改为**不做节流**，让数据以隧道能达到的最快速率流动：
  /// - 下载方向（远端→本地）由 loopback Socket 自然缓冲，WebView 持续读取即自动排空；
  /// - 上传方向（本地→远端）请求体通常很小；
  /// - 真正的吞吐上限来自 SSH 通道窗口与 dartssh2 的解密速率，不应由应用层节流。
  void _pipe(Socket local, SSHForwardChannel forward) {
    final localSub = local.listen(
      (data) {
        try {
          forward.sink.add(data);
        } catch (_) {
          forward.destroy();
        }
      },
      onDone: () => forward.destroy(),
      onError: (_) => forward.destroy(),
      cancelOnError: true,
    );

    final forwardSub = forward.stream.listen(
      (data) {
        try {
          local.add(data);
        } catch (_) {
          local.destroy();
        }
      },
      onDone: () => local.destroy(),
      onError: (_) => local.destroy(),
      cancelOnError: true,
    );

    // 任一端关闭则释放另一端
    forward.done.whenComplete(() {
      localSub.cancel().catchError((_) {});
      local.destroy();
    });
    local.done.whenComplete(() {
      forwardSub.cancel().catchError((_) {});
      forward.destroy();
    });
  }

  /// 主动断开隧道并清理。
  Future<void> disconnect() async {
    await _disconnectInternal();
  }

  Future<void> _disconnectInternal() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close();
    }
    final client = _client;
    _client = null;
    _activeProfileIndex = null;
    if (client != null) {
      client.close();
    }
    if (_status != TunnelStatus.idle) {
      _setStatus(TunnelStatus.idle);
    }
  }

  void dispose() {
    _disposed = true;
    _statusController.close();
  }
}
