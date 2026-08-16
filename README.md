# DSH-Phone

> 在 Android 上通过 SSH 隧道访问 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web UI 的移动客户端。

DSH-Phone 是一个 Flutter Android 应用：首次启动时配置 SSH 地址 / 用户名 / 认证方式（SSH 密钥或密码），应用自动建立 SSH 隧道（`127.0.0.1:<localPort>` → 远程 `127.0.0.1:3080`），并通过 WebView 加载 DSH Web UI。内置本地缓存加速、SSH 保活、界面缩放与全屏显示、主题自适应，以及手动修改连接配置 / 刷新缓存 / 查看关于的入口。

- **开源地址**：https://github.com/liangjianzeng/DSH-Phone
- **当前版本**：v0.1.0
- **安装包**：见仓库 [`apk/DSH-Phone-v0.1.0.apk`](apk/DSH-Phone-v0.1.0.apk)

## 工作原理

```
手机 127.0.0.1:<localPort> ──SSH 隧道──▶ 远程 127.0.0.1:3080 (DSH Web UI)
        ▲                        │
        │  WebView 以 loopback 身份访问
        │  （loopback 为浏览器安全上下文）
```

1. 应用内通过 `dartssh2` 建立 SSH 连接；
2. 把手机本地端口转发到远程 DSH 的 `127.0.0.1:3080`；
3. WebView 加载 `http://127.0.0.1:<localPort>`；
4. 因访问为 loopback，DSH 的模型/设置等特权接口（如 `settings.describe`）也可用。

## 功能特性

- 🔐 **首次启动引导**：设置 SSH 地址、端口、用户名，认证方式支持 **SSH 密钥（默认）** 与 **密码**。
- 🔄 **自动 SSH 隧道**：基于 `dartssh2` 建立本地端口转发，无需 Root。
- ⚡ **SSH 保活**：每 10s 发送 keep-alive，降低移动网络空闲断连；断线自动重连。
- 🧭 **WebView 加载 DSH Web UI**：`flutter_inappwebview`，loopback 访问，模型/设置等特权接口可用。
- 💾 **本地缓存加速**：优先使用本地缓存，缺才走网络；支持手动清缓存刷新。
- 🔍 **界面缩放**：双指缩放 + 顶栏/设置页 放大、缩小、重置；缩放比例**自动保存**，下次沿用。
- 🖥️ **全屏边缘到边缘**：顶栏延伸到系统状态栏区域，最大化显示面积。
- 🌗 **主题自适应**：跟随系统深色 / 浅色模式，背景与状态栏图标自动切换。
- ⚙️ **设置管理**：修改地址 / 用户名 / 认证、清空缓存、缩放控制、刷新缓存。
- ℹ️ **关于**：显示版本、项目原理、开源地址，可直接跳转 GitHub / README。
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
3. 顶栏：连接状态、设置入口。设置页含 SSH 配置、界面缩放 / 刷新缓存、关于信息。

> 说明：远程 DSH 默认只监听 `127.0.0.1:3080`，且配置类接口（如 `settings.describe`）被设计为仅 loopback 访问。DSH-Phone 通过 SSH 隧道把手机本机端口转发到远程，使 WebView 以 loopback 身份访问，从而获得完整功能。

## 依赖

| 包 | 用途 |
|----|------|
| `dartssh2` | 纯 Dart SSH 客户端：认证 + 本地端口转发 + 保活 |
| `flutter_inappwebview` | WebView、本地缓存控制、缩放 |
| `flutter_secure_storage` | 密码 / 私钥加密存储 |
| `shared_preferences` | 非敏感配置持久化（含缩放比例） |
| `url_launcher` | 打开 GitHub / README 链接 |

## 目录结构

```
lib/
├── main.dart           # 应用入口：主题/全屏、首次启动判断
├── config.dart         # SSH 配置模型 + 持久化
├── tunnel_service.dart # SSH 隧道服务（认证 / 转发 / 保活 / 断线重连）
├── setup_screen.dart   # 设置 / 首次引导页（含界面控制与关于）
└── webview_screen.dart # WebView 主界面（缓存 / 缩放 / 加载状态）
```

## 版本记录

- **v0.1.0**：首个发布版。SSH 隧道访问 DSH Web UI，含缩放、全屏、主题自适应、关于页。

## License

[MIT](LICENSE)
