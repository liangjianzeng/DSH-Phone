import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'config.dart';
import 'setup_screen.dart';
import 'tunnel_service.dart';

/// 主界面：SSH 隧道就绪后，用 WebView 加载 DSH Web UI，并带缓存加速与设置入口。
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  SSHConfig _config = const SSHConfig();
  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    _config = await SSHConfig.load();
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _tunnelStatus = TunnelStatus.connecting;
    });
    try {
      await TunnelService.instance.connect(_config);
      if (!mounted) return;
      setState(() => _tunnelStatus = TunnelStatus.connected);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tunnelStatus = TunnelStatus.failed;
        _error = '$e';
      });
    }
  }

  Future<void> _disconnect() async {
    await TunnelService.instance.disconnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // 后台时断开隧道，避免长时间占用；回前台自动重连。
    if (state == AppLifecycleState.paused) {
      await _disconnect();
    } else if (state == AppLifecycleState.resumed) {
      _connect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disconnect();
    super.dispose();
  }

  /// 刷新缓存：清缓存后重新加载。
  Future<void> _refreshCache() async {
    final c = _controller;
    if (c != null) {
      await InAppWebViewController.clearAllCache();
      await c.reload();
    }
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetupScreen(initial: _config),
      ),
    );
    if (changed == true) {
      _config = await SSHConfig.load();
      await _disconnect();
      _connect();
    }
  }

  String get _targetUrl => 'http://127.0.0.1:${_config.localPort}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DSH-Phone'),
        actions: [
          _StatusChip(status: _tunnelStatus),
          IconButton(
            tooltip: '刷新缓存',
            icon: const Icon(Icons.refresh),
            onPressed: _tunnelStatus == TunnelStatus.connected
                ? _refreshCache
                : null,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_tunnelStatus) {
      case TunnelStatus.idle:
      case TunnelStatus.connecting:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在建立 SSH 隧道…'),
            ],
          ),
        );
      case TunnelStatus.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('连接失败：\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _openSettings,
                  child: const Text('修改设置'),
                ),
              ],
            ),
          ),
        );
      case TunnelStatus.connected:
        return InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_targetUrl)),
          initialSettings: InAppWebViewSettings(
            // 本地缓存加速：优先用缓存，缺时才走网络
            cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
            // DSH 是含 WebSocket 的 SPA
            javaScriptEnabled: true,
            transparentBackground: false,
          ),
          onWebViewCreated: (controller) => _controller = controller,
        );
      case TunnelStatus.disconnected:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 48),
              const SizedBox(height: 16),
              const Text('隧道已断开'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新连接'),
              ),
            ],
          ),
        );
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      TunnelStatus.idle => ('空闲', Colors.grey),
      TunnelStatus.connecting => ('连接中', Colors.orange),
      TunnelStatus.connected => ('已连接', Colors.green),
      TunnelStatus.failed => ('失败', Colors.red),
      TunnelStatus.disconnected => ('已断开', Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        backgroundColor: color.withValues(alpha: 0.2),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
