# DSH-Phone

> 在 Android 上通过 SSH 隧道访问 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web UI 的移动客户端。

DSH-Phone 是一个 Flutter Android 应用：首次启动时配置 SSH 地址 / 用户名 / 认证方式（SSH 密钥或密码），应用自动建立 SSH 隧道（`127.0.0.1:<localPort>` → 远程 `127.0.0.1:3080`），并通过 WebView 加载 DSH Web UI。内置本地缓存加速、SSH 保活，以及手动修改连接配置 / 刷新缓存的入口。

## 功能特性

- 🔐 **首次启动引导**：设置 SSH 地址、端口、用户名，认证方式支持 **SSH 密钥（默认）** 与 **密码**。
- 🔄 **自动 SSH 隧道**：基于 `dartssh2` 建立本地端口转发，无需 Root。
- ⚡ **SSH 保活**：周期性发送 keep-alive，避免空闲断连。
- 🧭 **WebView 加载 DSH Web UI**：`flutter_inappwebview`，loopback 访问（`127.0.0.1` 为安全上下文），模型/设置等特权接口可用。
- 💾 **本地缓存加速**：优先使用本地缓存，缺才走网络。
- ⚙️ **设置管理**：随时修改地址 / 用户名 / 认证、清空缓存并刷新。
- 🔒 **敏感信息加密**：密码 / 私钥存于 Android Keystore（`flutter_secure_storage`）。

## 快速开始

### 构建 APK

```bash
flutter pub get
flutter pub run flutter_launcher_icons   # 从 icon/logo.png 生成启动图标
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

### 使用

1. 首次打开 → 配置 SSH 地址（如 `100.81.83.59`）、用户名（如 `jianzengliang`）、认证方式与本地端口（默认 `3081`）。
2. 保存并连接，隧道建立后自动加载 `http://127.0.0.1:3081` 的 DSH Web UI。
3. 顶部工具栏：连接状态、刷新缓存、设置入口。

> 说明：远程 DSH 默认只监听 `127.0.0.1:3080`，且配置类接口（如 `settings.describe`）被设计为仅 loopback 访问。DSH-Phone 通过 SSH 隧道把手机本机端口转发到远程，使 WebView 以 loopback 身份访问，从而获得完整功能。

## 依赖

| 包 | 用途 |
|----|------|
| `dartssh2` | 纯 Dart SSH 客户端：认证 + 本地端口转发 + 保活 |
| `flutter_inappwebview` | WebView 与本地缓存控制 |
| `flutter_secure_storage` | 密码 / 私钥加密存储 |
| `shared_preferences` | 非敏感配置持久化 |

## 目录结构

```
lib/
├── main.dart           # 应用入口：首次启动判断
├── config.dart         # SSH 配置模型 + 持久化
├── tunnel_service.dart # SSH 隧道服务（认证 / 转发 / 保活）
├── setup_screen.dart   # 设置 / 首次引导页
└── webview_screen.dart # WebView 主界面（缓存 / 设置入口）
```

## License

[MIT](LICENSE)
