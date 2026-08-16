import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'setup_screen.dart';
import 'tunnel_service.dart';
import 'webview_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 边缘到边缘全屏：应用内容延伸到系统状态栏/导航栏区域
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const DshPhoneApp());
}

class DshPhoneApp extends StatelessWidget {
  const DshPhoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH-Phone',
      debugShowCheckedModeBanner: false,
      // 浅色 / 深色主题都提供，并跟随系统切换
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      // 状态栏/导航栏图标随主题亮度自适应
      builder: (context, child) {
        final isDark =
            Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarDividerColor: Colors.transparent,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _Home(),
    );
  }
}

/// 首次启动判断：已有配置 → 直接进 WebView；否则进设置引导。
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _loading = true;
  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final config = await SSHConfig.load();
    if (!mounted) return;
    setState(() {
      _configured = config.isConfigured;
      _loading = false;
    });
  }

  @override
  void dispose() {
    TunnelService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _configured ? const WebViewScreen() : const SetupScreen();
  }
}
