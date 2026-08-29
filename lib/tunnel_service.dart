import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart' show Charset, gbk;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:dartssh2/dartssh2.dart';

import 'config.dart';
import 'foreground_service.dart';

/// 隧道连接状态。
enum TunnelStatus { idle, connecting, connected, failed, disconnected }

/// 远程主机类型（用于选择采集命令）。
enum HostType { linux, windows }

/// 单次主机采样：GPU 使用率 / GPU 温度 / CPU / 内存使用率。
class HostSample {
  const HostSample({
    required this.cpu,
    required this.mem,
    required this.gpu,
    this.gpuTemp = -1,
  });

  /// CPU 使用率（0-100）。
  final double cpu;

  /// 内存使用率（0-100）。
  final double mem;

  /// GPU 使用率（0-100），-1 表示无 GPU / 无数据。
  final double gpu;

  /// GPU 温度（℃），-1 表示无 GPU / 无数据。
  final double gpuTemp;
}

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
  bool _connecting = false;

  /// 当前激活（已连接/正在连接）的实例索引，null 表示无。
  int? _activeProfileIndex;
  int? get activeProfileIndex => _activeProfileIndex;

  TunnelStatus _status = TunnelStatus.idle;
  TunnelStatus get status => _status;

  Stream<TunnelStatus> get statusStream => _statusController.stream;

  void _setStatus(TunnelStatus s) {
    _status = s;
    // 广播流无监听者时 add 会被安全丢弃，无需 _disposed 守卫。
    _statusController.add(s);
    _syncForegroundService(s);
  }

  /// 前台服务与隧道状态联动：connected 启动保活服务，其余状态停止。
  /// 后台/关屏时进程保持运行，SSH 保活持续发送，避免远端空闲断开。
  void _syncForegroundService(TunnelStatus s) {
    if (s == TunnelStatus.connected) {
      ForegroundTunnelService.instance.start();
    } else {
      ForegroundTunnelService.instance.stop();
    }
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
      debugPrint('[DSH] connecting to ${config.host}:${config.sshPort} '
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
        onError: (Object e) {
          debugPrint('[DSH] transport error: $e');
          _onTransportClosed(client, failed: true);
        },
      );

      // 3) 等待认证完成
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] SSH authentication timed out');
        throw const SocketException('SSH 认证超时');
      });
      // 3.5) 认证完成后确认未被并发断开/替换（竞态守卫）：
      // 若期间 disconnect() 已执行（_client 被置空/替换），放弃本次连接，
      // 避免绑定一个已失效 client 的"假隧道"并误报 connected。
      if (_client != client) {
        client.close();
        throw const SocketException('隧道已断开，放弃连接');
      }
      debugPrint('[DSH] authenticated, opening local tunnel on '
          '127.0.0.1:${config.localPort}');

      // 4) 本地监听端口
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, config.localPort);
      // 绑定后再确认一次：期间被断开则释放端口，防止残留占用
      if (_client != client) {
        await server.close();
        client.close();
        throw const SocketException('隧道已断开，放弃连接');
      }
      _server = server;
      server.listen(_handleLocalConnection);

      debugPrint('[DSH] tunnel up: 127.0.0.1:${config.localPort} -> '
          '127.0.0.1:3080');
      _setStatus(TunnelStatus.connected);
    } catch (e) {
      debugPrint('[DSH] connect failed: $e');
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// 仅验证 SSH 认证是否成功（设置页"测试连接"专用）。
  ///
  /// 与 [connect] 的区别：不建立本地转发、不改变隧道状态、不联动前台服务，
  /// 认证完成后立即关闭会话释放资源，避免测试时通知栏/前台服务启停闪烁，
  /// 也避免污染当前活动隧道。
  ///
  /// 认证成功正常返回；连接/认证失败抛出异常（由调用方呈现错误）。
  Future<void> testConnection(SSHConfig config) async {
    final socket = await SSHSocket.connect(config.host, config.sshPort,
        timeout: const Duration(seconds: 15));
    SSHClient? client;
    try {
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) => true,
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] test connection auth timed out');
        throw const SocketException('SSH 认证超时');
      });
      debugPrint('[DSH] test connection ok '
          '(${config.host}:${config.sshPort})');
    } finally {
      client?.close();
      // fromPem 解析失败等 client 未建立时，直接关闭底层 socket 防泄漏
      if (client == null) {
        // 忽略异步关闭结果（finally 中无法 await）
        socket.close();
      }
    }
  }

  /// 传输关闭时的统一清理：仅当仍是当前 client 才处理，避免旧连接误改状态。
  void _onTransportClosed(SSHClient client, {bool failed = false}) {
    if (_client != client) return;
    debugPrint('[DSH] transport closed'
        '${failed ? ' (with error)' : ''} '
        '(activeProfile=$_activeProfileIndex)');
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

  /// 通过现有 SSH 会话读取云端主机上的文件内容（用于成果查看）。
  ///
  /// [remotePath] 为云端文件路径（如 `E:\Work\CaTv\xxx.md` 或 `/home/user/xxx.md`）。
  /// 采用 **SFTP** 读取：绕开 shell 命令对中文路径的编码问题（Windows cmd 用
  /// GBK 而 exec 命令按 UTF-8 发送，中文路径会被误解码）。
  /// 隧道未连接时返回空字符串（由查看器提示）。
  Future<String> readRemoteFile(String remotePath) async {
    final client = _client;
    if (client == null) return '';
    // 尝试多种 SFTP 路径形态（Windows 盘符路径的表示差异）
    for (final path in _sftpPathCandidates(remotePath)) {
      SftpFile? file;
      SftpClient? sftp;
      try {
        sftp = await client.sftp();
        file = await sftp.open(path);
        final bytes = await file.readBytes();
        return _decodeBytes(bytes);
      } catch (e) {
        debugPrint('[DSH] readRemoteFile failed for "$path": $e');
      } finally {
        if (file != null) await file.close(); // 顺带关闭所属 SFTP 会话/通道
        sftp?.close(); // 打开失败等分支：释放会话通道，避免泄漏
      }
    }
    return '';
  }

  /// 解析远程路径并打开 SFTP 文件句柄（用于资源下载/断点续传）。
  ///
  /// 尝试多种路径形态（与 [readRemoteFile] 一致的候选规则），
  /// 打开成功即返回，调用方负责 `close()`。隧道未连接或全部形态
  /// 打开失败时返回 null。
  Future<SftpFile?> openRemoteFile(String remotePath) async {
    final client = _client;
    if (client == null) return null;
    for (final path in _sftpPathCandidates(remotePath)) {
      SftpClient? sftp;
      try {
        sftp = await client.sftp();
        return await sftp.open(path); // 返回后会话由 SftpFile.close() 一并关闭
      } catch (e) {
        debugPrint('[DSH] openRemoteFile failed for "$path": $e');
        sftp?.close(); // 打开失败：释放会话通道，避免泄漏
      }
    }
    return null;
  }

  /// 用候选目录 + 文件名拼接云端路径，逐个尝试 SFTP 打开，
  /// 返回第一个可打开的完整路径；全部失败返回 null。
  ///
  /// 用于 DSH 产物 chips 被隐藏（只有文件名、无完整路径）的场景。
  Future<String?> resolveRemotePath(String filename, List<String> dirs) async {
    for (final dir in dirs) {
      for (final sep in [r'\', '/']) {
        final cand = (dir.endsWith(r'\') || dir.endsWith('/'))
            ? '$dir$filename'
            : '$dir$sep$filename';
        final file = await openRemoteFile(cand);
        if (file != null) {
          await file.close();
          debugPrint('[DSH] resolved "$filename" -> "$cand"');
          return cand;
        }
      }
    }
    return null;
  }

  /// 生成待尝试的 SFTP 路径：原样 → 反斜杠转正斜杠 → 前缀 `/`。
  List<String> _sftpPathCandidates(String p) {
    final normalized = p.replaceAll(r'\', '/');
    return <String>[
      p,
      normalized,
      normalized.startsWith('/') ? normalized : '/$normalized',
    ];
  }

  /// 读取云端文件原始字节（用于"另存为"时保留原始编码，如 GBK）。
  ///
  /// 打开失败返回 null。仅读内存（小文本文件），大文件请走下载流。
  Future<Uint8List?> readRemoteFileBytes(String remotePath) async {
    final file = await openRemoteFile(remotePath);
    if (file == null) return null;
    try {
      return await file.readBytes();
    } catch (e) {
      debugPrint('[DSH] readRemoteFileBytes failed: $e');
      return null;
    } finally {
      await file.close();
    }
  }

  /// 健壮解码：先自动检测编码（UTF-8 → GBK/GB2312 → ASCII），
  /// 检测/解码异常时兜底 UTF-8 宽松解码，避免返回空导致白屏。
  String _decodeBytes(Uint8List bytes) {
    try {
      final detected = Charset.detect(bytes, orders: [utf8, gbk, ascii]);
      if (detected != null) return detected.decode(bytes);
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ================= 主机监控：远程命令采集 =================

  /// 按 SSH 会话缓存主机类型探测结果（活动隧道与监控隧道可能指向不同主机）。
  final Map<SSHClient, HostType> _hostTypes = {};

  /// 在指定 SSH 会话上执行命令，返回合并后的 stdout+stderr 文本。
  ///
  /// 执行失败 / 超时返回 null。输出用 [_decodeBytes] 健壮解码
  /// （UTF-8 → GBK → ASCII），兼容 Windows cmd 的 GBK 错误信息。
  Future<String?> _execOn(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final bytes = await client.run(command).timeout(timeout);
      return _decodeBytes(bytes);
    } catch (e) {
      debugPrint('[DSH] executeRemote failed: $e');
      return null;
    }
  }

  /// 在当前活动隧道上执行命令（对外保留的便捷方法）。
  Future<String?> executeRemote(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = _client;
    if (client == null) return null;
    return _execOn(client, command, timeout: timeout);
  }

  /// 探测指定 SSH 会话的主机类型（按会话缓存）。
  ///
  /// Windows（默认 cmd）执行 `uname -s` 会返回"命令不存在"的 GBK 错误文本，
  /// 因此不能仅凭"输出非空"判定 Unix：须识别命令不存在 / Windows bash 环境
  /// 标识（MINGW / MSYS / CYGWIN / *_NT），否则视为 Unix 系。
  Future<HostType> _detectHostType(SSHClient client) async {
    final cached = _hostTypes[client];
    if (cached != null) return cached;
    final out = await _execOn(client, 'uname -s');
    final t = (out ?? '').trim();
    final isWindows = t.isEmpty ||
        t.contains('MINGW') ||
        t.contains('MSYS') ||
        t.contains('CYGWIN') ||
        t.contains('_NT') ||
        // 命令不存在类错误 → Windows cmd
        t.contains('不是内部或外部命令') ||
        t.contains('不是内部命令') ||
        t.contains('not recognized') ||
        t.contains('command not found') ||
        t.contains('not found') ||
        t.contains('找不到');
    final type = isWindows ? HostType.windows : HostType.linux;
    _hostTypes[client] = type;
    debugPrint('[DSH] detected host type: $type (uname="$t")');
    return type;
  }

  /// 在指定 SSH 会话上采集一次主机使用率（CPU / 内存 / GPU）。
  /// 会话断开或采集失败返回 null。
  Future<HostSample?> _sampleFrom(SSHClient client) async {
    final type = await _detectHostType(client);
    final command = _buildSampleCommand(type);
    final out = await _execOn(client, command);
    if (out == null || out.trim().isEmpty) return null;
    return _parseSample(out);
  }

  /// 采集一次当前活动隧道的主机使用率（CPU / 内存 / GPU）。
  Future<HostSample?> collectHostSample() async {
    final client = _client;
    if (client == null) return null;
    return _sampleFrom(client);
  }

  /// 按主机类型构造采集命令：输出 `CPU=xx` / `MEM=xx` / `GPU=xx` / `GPUTEMP=xx`。
  ///
  /// 用原始字符串避免 Dart 对 `$`（awk 列 / PowerShell 变量）的插值转义。
  /// 注意：dartssh2 的 `client.run()` 本身就是经远程 bash 执行命令，
  /// 不能再包一层 `sh -c '...'`，否则 bash 单引号嵌套冲突（unexpected EOF）
  /// 导致整条命令解析失败（曾实测：Linux 主机采集全失败）。
  ///
  /// Linux 分支对 ARM/精简/容器环境做了健壮化：
  /// - CPU 用 /proc/stat（busybox awk 兼容），无匹配时输出 0；
  /// - MEM 改用 /proc/meminfo（MemTotal - MemAvailable），不依赖 free 命令；
  /// - GPU 使用率 / 温度各一行，无 nvidia-smi 时留空（解析为 -1）。
  ///
  /// Windows 分支：bash 会展开 `$`，PowerShell 变量的 `$` 必须转义为 `\$`，
  /// 否则变量被 bash 展开为空导致采集失败。
  String _buildSampleCommand(HostType type) {
    if (type == HostType.linux) {
      return r'''c=$(awk "/^cpu /{i=\$5+\$6+\$7; t=\$2+\$3+\$4+\$5+\$6+\$7+\$8; if(t>0){printf \"%.0f\",(t-i)*100/t}else{printf \"0\"}}" /proc/stat 2>/dev/null); m=$(awk "/^MemTotal:/{t=\$2} /^MemAvailable:/{a=\$2} END{if(t>0){printf \"%.0f\",(t-a)*100/t}else{printf \"0\"}}" /proc/meminfo 2>/dev/null); g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); gt=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1); [ -z "$c" ] && c=0; [ -z "$m" ] && m=0; echo "CPU=$c"; echo "MEM=$m"; echo "GPU=$g"; echo "GPUTEMP=$gt"''';
    }
    // Windows：性能计数器 + nvidia-smi（无 GPU 时 GPU 行留空，解析为 -1）。
    // Get-Counter 首次读取可能返回 null，回退 0 避免解析异常。
    return r'''powershell -NoProfile -Command "\$c=Get-Counter '\Processor(_Total)% Processor Time' -ErrorAction SilentlyContinue; \$cpu=if(\$c.CounterSamples[0].CookedValue -eq \$null){0}else{[int]\$c.CounterSamples[0].CookedValue}; \$m=Get-Counter '\Memory% Committed Bytes In Use' -ErrorAction SilentlyContinue; \$mem=if(\$m.CounterSamples[0].CookedValue -eq \$null){0}else{[int]\$m.CounterSamples[0].CookedValue}; \$gpu=(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>\$null); \$gt=(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>\$null); Write-Output ('CPU='+\$cpu); Write-Output ('MEM='+\$mem); Write-Output ('GPU='+\$gpu); Write-Output ('GPUTEMP='+\$gt)"''';
  }

  /// 解析采集输出（`CPU=xx` / `MEM=xx` / `GPU=xx` / `GPUTEMP=xx`）。
  /// 数值取首个数字；GPU 多卡逗号分隔时取首个；缺行/空值视为 0 / -1。
  HostSample? _parseSample(String out) {
    var cpu = 0.0, mem = 0.0, gpu = -1.0, gpuTemp = -1.0;
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.startsWith('CPU=')) {
        cpu = _firstNumber(t.substring(4));
      } else if (t.startsWith('MEM=')) {
        mem = _firstNumber(t.substring(4));
      } else if (t.startsWith('GPU=')) {
        final s = t.substring(4);
        gpu = s.trim().isEmpty ? -1 : _firstNumber(s);
      } else if (t.startsWith('GPUTEMP=')) {
        final s = t.substring(7);
        gpuTemp = s.trim().isEmpty ? -1 : _firstNumber(s);
      }
    }
    return HostSample(
      cpu: cpu.clamp(0, 100),
      mem: mem.clamp(0, 100),
      gpu: gpu >= 0 ? gpu.clamp(0, 100) : -1,
      // GPU 温度常见 40~90℃，极端值按 0~150 夹取（>100 画在顶栏顶部被裁剪）
      gpuTemp: gpuTemp >= 0 ? gpuTemp.clamp(0, 150) : -1,
    );
  }

  /// 提取字符串中的首个数值（含小数）；无数值返回 0。
  static double _firstNumber(String s) {
    final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
    if (m == null) return 0;
    return double.tryParse(m.group(0) ?? '') ?? 0;
  }

  // ================= Unsloth Studio：SSH 模式独立转发 =================

  /// Unsloth Studio 专用 SSH 客户端（与活动隧道/监控隧道相互独立），
  /// 保证顶栏图标可打开任意实例的 Unsloth Studio，即使它不是当前连接实例。
  SSHClient? _unslothClient;
  bool _unslothConnecting = false;

  /// Unsloth Studio 本地监听（SSH 模式时存在），转发到远程 127.0.0.1 上的 unsloth 端口。
  ServerSocket? _unslothServer;

  /// Unsloth Studio 远程端口（取实例配置，默认 8888）。
  int _unslothRemotePort = SSHConfig.defaultUnslothPort;

  /// Unsloth Studio 本地端口（SSH 模式时 OS 动态分配；直连模式为 null）。
  int? get unslothLocalPort => _unslothServer?.port;

  /// 建立 Unsloth Studio 转发：建立到配置实例的独立 SSH 会话，
  /// 本地监听端口由 OS 动态分配（bind 0），转发到远程 127.0.0.1:[unslothPort]。
  ///
  /// 配置未就绪 / 认证失败 / 绑定失败时返回 null，调用方提示错误。
  /// [unslothPort] 可空：为空时使用配置端口（默认 8888）。
  Future<int?> startUnslothForward(SSHConfig config,
      {int? unslothPort}) async {
    await stopUnslothForward();
    if (!config.isConfigured) return null;
    _unslothRemotePort = unslothPort ?? config.unslothPort;
    // 建立独立的 unsloth SSH 会话（不依赖当前活动隧道）
    if (!await _connectUnslothClient(config)) return null;
    try {
      final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, 0);
      _unslothServer = server;
      server.listen(_handleUnslothForward);
      debugPrint('[DSH] unsloth forward up: '
          '127.0.0.1:${server.port} -> 127.0.0.1:$_unslothRemotePort');
      return server.port;
    } catch (e) {
      debugPrint('[DSH] unsloth forward failed: $e');
      _unslothServer = null;
      await _closeUnslothClient();
      return null;
    }
  }

  /// 建立 Unsloth Studio 独立 SSH 会话（认证流程与监控隧道一致）。
  Future<bool> _connectUnslothClient(SSHConfig config) async {
    if (_unslothConnecting) return _unslothClient != null;
    _unslothConnecting = true;
    try {
      final socket = await SSHSocket.connect(config.host, config.sshPort,
          timeout: const Duration(seconds: 15));
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) => true,
      );
      _unslothClient = client;
      client.done.then(
        (_) => _onUnslothClientClosed(client),
        onError: (Object e) {
          debugPrint('[DSH] unsloth transport error: $e');
          _onUnslothClientClosed(client, failed: true);
        },
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] unsloth auth timed out');
        throw const SocketException('Unsloth 连接认证超时');
      });
      debugPrint('[DSH] unsloth ssh ready '
          '(${config.host}:${config.sshPort})');
      return true;
    } catch (e) {
      debugPrint('[DSH] unsloth connect failed: $e');
      final c = _unslothClient;
      _unslothClient = null;
      c?.close();
      return false;
    } finally {
      _unslothConnecting = false;
    }
  }

  /// Unsloth 专用 SSH 会话关闭：连带关闭本地转发监听。
  void _onUnslothClientClosed(SSHClient client, {bool failed = false}) {
    if (_unslothClient != client) return;
    _unslothClient = null;
    debugPrint('[DSH] unsloth transport closed'
        '${failed ? ' (with error)' : ''}');
    final server = _unslothServer;
    _unslothServer = null;
    server?.close();
  }

  /// 处理一条 Unsloth Studio 本地连接：经独立 SSH 会话转发到远程端口。
  Future<void> _handleUnslothForward(Socket local) async {
    final client = _unslothClient;
    if (client == null) {
      local.destroy();
      return;
    }
    try {
      // 远程 Unsloth Studio 监听 127.0.0.1:<unslothRemotePort>
      final forward =
          await client.forwardLocal('127.0.0.1', _unslothRemotePort);
      _pipe(local, forward);
    } catch (_) {
      local.destroy();
    }
  }

  /// 关闭 Unsloth Studio 转发（页面关闭时调用），连带关闭独立 SSH 会话。
  Future<void> stopUnslothForward() async {
    final server = _unslothServer;
    _unslothServer = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
    await _closeUnslothClient();
  }

  Future<void> _closeUnslothClient() async {
    final c = _unslothClient;
    _unslothClient = null;
    if (c != null) c.close();
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

  // ================= 实例级主机资源监控（独立采集隧道）=================

  /// 开启"默认主机资源监控"的实例索引，null 表示无。
  int? _monitorProfileIndex;
  SSHConfig? _monitorConfig;

  /// 独立的监控采集 SSH 客户端（与活动隧道分开，用于采集指定实例的主机数据）。
  SSHClient? _monitorClient;
  bool _monitorConnecting = false;

  /// 当前监控实例索引（null 表示无）。
  int? get monitorProfileIndex => _monitorProfileIndex;

  /// 设置监控实例：建立/关闭独立的监控采集隧道。
  ///
  /// [config] 为 null 或未配置时关闭现有监控隧道；
  /// 否则建立到该实例的采集连接（与活动隧道相互独立，切换实例不受影响）。
  Future<void> setupMonitorProfile(
      SSHConfig? config, {int? profileIndex}) async {
    _monitorProfileIndex = profileIndex;
    _monitorConfig = (config != null && config.isConfigured) ? config : null;
    // 监控实例可能变化：清空按会话的主机类型缓存
    _hostTypes.clear();
    await _closeMonitorClient();
    final c = _monitorConfig;
    if (c == null) return;
    await _connectMonitor(c);
  }

  Future<void> _connectMonitor(SSHConfig config) async {
    if (_monitorConnecting) return;
    _monitorConnecting = true;
    try {
      final socket = await SSHSocket.connect(config.host, config.sshPort,
          timeout: const Duration(seconds: 15));
      final List<SSHKeyPair>? identities = config.useKey
          ? SSHKeyPair.fromPem(config.privateKeyPem,
              config.keyPassphrase.isEmpty ? null : config.keyPassphrase)
          : null;
      final client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.useKey ? null : () async => config.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) => true,
      );
      _monitorClient = client;
      client.done.then(
        (_) => _onMonitorClosed(client),
        onError: (Object e) {
          debugPrint('[DSH] monitor transport error: $e');
          _onMonitorClosed(client, failed: true);
        },
      );
      await client.authenticated
          .timeout(const Duration(seconds: 20), onTimeout: () {
        debugPrint('[DSH] monitor auth timed out');
        throw const SocketException('监控连接认证超时');
      });
      debugPrint('[DSH] monitor tunnel ready '
          '(profile=$_monitorProfileIndex ${config.host}:${config.sshPort})');
    } catch (e) {
      debugPrint('[DSH] monitor connect failed: $e');
      final mc = _monitorClient;
      _monitorClient = null;
      mc?.close();
    } finally {
      _monitorConnecting = false;
    }
  }

  void _onMonitorClosed(SSHClient client, {bool failed = false}) {
    if (_monitorClient != client) return;
    _monitorClient = null;
    debugPrint('[DSH] monitor transport closed'
        '${failed ? ' (with error)' : ''}');
  }

  Future<void> _closeMonitorClient() async {
    final mc = _monitorClient;
    _monitorClient = null;
    if (mc != null) mc.close();
  }

  /// 确保监控隧道存在（懒连接）；无法建立返回 null。
  Future<SSHClient?> _ensureMonitorClient() async {
    if (_monitorClient != null) return _monitorClient;
    final c = _monitorConfig;
    if (c == null || _monitorConnecting) return null;
    await _connectMonitor(c);
    return _monitorClient;
  }

  /// 采集监控实例的主机使用率。
  ///
  /// 当前活动隧道恰好是监控实例时直接复用（避免双连接）；
  /// 否则使用独立的监控采集隧道。
  Future<HostSample?> collectMonitorSample() async {
    if (_monitorProfileIndex == null) return null;
    if (_activeProfileIndex == _monitorProfileIndex && _client != null) {
      return _sampleFrom(_client!);
    }
    final mc = await _ensureMonitorClient();
    if (mc == null) return null;
    return _sampleFrom(mc);
  }

  void dispose() {
    // 释放隧道与后台资源。注意：不关闭状态流、不置永久失效标志——
    // TunnelService 是应用级单例，根 State 可能在运行期重建
    // （例如 Flutter 框架重建根路由），关闭后单例将永久不可用，
    // 隧道无法再次建立。进程退出时资源由系统回收即可。
    // 停止前台服务并释放唤醒锁
    ForegroundTunnelService.instance.stop();
    // 关闭 Unsloth Studio 转发
    stopUnslothForward();
    // 关闭独立的监控采集隧道
    final mc = _monitorClient;
    _monitorClient = null;
    mc?.close();
    // 断开活动隧道（含本地端口监听与 SSH 会话）
    _disconnectInternal();
  }
}
