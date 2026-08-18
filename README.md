# DSH-Phone

> 在 Android 上通过 SSH 隧道访问 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web UI 的移动客户端。

DSH-Phone 是一个 Flutter Android 应用：首次启动时配置 SSH 地址 / 用户名 / 认证方式（SSH 密钥或密码），应用自动建立 SSH 隧道（`127.0.0.1:<localPort>` → 远程 `127.0.0.1:3080`），并通过 WebView 加载 DSH Web UI。内置本地缓存加速、SSH 保活、界面缩放与全屏显示、主题自适应，以及手动修改连接配置 / 刷新缓存 / 查看关于的入口。

- **开源地址**：https://github.com/liangjianzeng/DSH-Phone
- **当前版本**：v0.1.2
- **安装包**：[`apk/DSH-Phone-v0.1.2.apk`](apk/DSH-Phone-v0.1.2.apk)（旧版 [`apk/DSH-Phone-v0.1.1.apk`](apk/DSH-Phone-v0.1.1.apk) 见仓库）

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

## 推荐部署方式（公网组网 + SSH 隧道）

云主机上的 DSH 默认只监听 `127.0.0.1:3080`，手机无法直连。推荐用 **Tailscale 组建公网 VPN** 实现公网穿透组网，再经由 VPN IP 走 SSH 隧道穿越：

```
手机 ──Tailscale VPN──▶ 云主机(VPN IP) ──SSH 隧道──▶ 云主机 127.0.0.1:3080 (DSH)
   │                      │
   │                      └── DSH-Phone 配置 SSH 地址为该 VPN IP
   └── WebView 加载 http://127.0.0.1:<localPort> 接入 DSH
```

1. **组网**：手机与云主机均加入同一个 Tailscale 网络（或其它基于 WireGuard 的组网方案），双方获得稳定的 VPN 地址，实现公网穿透、免公网端口映射。
2. **穿越**：DSH-Phone 的 SSH 地址配置为云主机的 **VPN IP**，通过 SSH 隧道把手机本地端口转发到云主机 `127.0.0.1:3080`。
3. **接入**：端侧 WebView 加载 `http://127.0.0.1:<localPort>` 接入云主机 DSH，且以 loopback 身份访问，模型/设置等特权接口可用。

> ⚠️ **跨运营商 UDP QoS 提醒**：Tailscale 走的是 UDP（WireGuard），当手机与云主机**跨运营商**时，运营商往往对 UDP 做 QoS（限速/丢包），会导致 SSH 隧道吞吐骤降，**加载长上下文会话历史时直接超时失败**。同一运营商下通常可达数 MB/s 且不丢包。因此：
> - 建议在**同一运营商网络**下使用（手机与云主机同运营商）；
> - 跨运营商遇到慢/超时，可切换网络、调大页面加载超时，或改用同一运营商线路。

## 功能特性

- 🔐 **首次启动引导**：设置 SSH 地址、端口、用户名，认证方式支持 **SSH 密钥（默认）** 与 **密码**。
- 📦 **多连接实例（最多 3 路）**：配置指向不同服务端的多路 SSH 实例，顶栏状态栏一键自由切换；可为每路实例设置**别名**（最多 7 个中文或 15 个英文字母），顶栏优先显示别名而非地址，避免多路 IP 混淆；敏感信息仍加密存储。
- ⏱️ **可配置页面加载超时**：默认 60s、范围 30–180s，设置页滑块调整；大上下文会话历史加载较慢时可调大。
- 🔄 **自动 SSH 隧道**：基于 `dartssh2` 建立本地端口转发，无需 Root。
- ⚡ **SSH 保活与静默重连**：每 10s 发送 keep-alive，降低移动网络空闲断连；首次异常（如隐藏后台 / 黑屏一段时间后断线）**不闪现错误提示、直接默认重连**，连续异常才提示并自动退避重试（递增退避 + 连续失败上限）。
- 🚀 **隧道吞吐优化**：本地 fork 的 `dartssh2`（认证后 zlib 压缩 + 整包批量解密），双向透传不做应用层节流，显著提升大体积加载速度。
- 🧭 **WebView 加载 DSH Web UI**：`flutter_inappwebview`，loopback 访问，模型/设置等特权接口可用。
- 💾 **本地缓存加速**：优先使用本地缓存，缺才走网络；支持手动清缓存刷新。
- 🔍 **界面缩放**：双指缩放 + 顶栏/设置页 放大、缩小、重置；缩放比例**自动保存**，下次沿用。
- 🖥️ **全屏边缘到边缘**：顶栏延伸到系统状态栏区域，最大化显示面积。
- 🌗 **主题自适应**：跟随系统深色 / 浅色模式，背景与状态栏图标自动切换。
- ⚙️ **设置管理**：修改地址 / 用户名 / 认证、清空缓存、缩放控制、刷新缓存。
- ℹ️ **关于**：显示版本、项目原理、开源地址，可直接跳转 GitHub / README。
- 🔒 **敏感信息加密**：密码 / 私钥存于 Android Keystore（`flutter_secure_storage`）。

## 主机端（服务端）SSH 支持

DSH-Phone 通过 SSH 隧道接入主机端，因此主机端需要能接受 SSH 连接：

- **Linux 主机**：原生支持 SSH（OpenSSH 服务端通常已内置或 `apt install openssh-server` 即可），开箱即用，无需额外安装。
- **Windows 主机**：建议下载安装 **OpenSSH 作为服务端**（Windows 设置 → 可选功能 → 添加"OpenSSH 服务器"，或 `winget install Microsoft.OpenSSH.Beta`），并确认 SSH 服务已启动、防火墙放行 22 端口，即可配合端侧 DSH-Phone 的 SSH 隧道建立与使用。

> 主机端 DSH 默认监听 `127.0.0.1:3080`，仅 loopback 访问；DSH-Phone 通过 SSH 隧道把手机本机端口转发到主机端，使 WebView 以 loopback 身份访问，从而获得完整功能。

## 快速开始

### 构建 APK

```bash
flutter pub get
flutter pub run flutter_launcher_icons   # 从 icon/logo.png 生成启动图标
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

### 使用

1. 首次打开 → 配置 SSH 地址（如 `100.81.83.59`）、用户名（如 `jianzengliang`）、认证方式与本地端口（默认 `3081`）；最多可配置 3 路实例。
2. 保存并连接，隧道建立后自动加载 `http://127.0.0.1:3081` 的 DSH Web UI。
3. 顶栏：实例切换器 + 连接状态 + 设置入口。设置页含 SSH 配置、加载超时、界面缩放 / 刷新缓存、关于信息。

> 说明：远程 DSH 默认只监听 `127.0.0.1:3080`，且配置类接口（如 `settings.describe`）被设计为仅 loopback 访问。DSH-Phone 通过 SSH 隧道把手机本机端口转发到远程，使 WebView 以 loopback 身份访问，从而获得完整功能。
>
> 提示：隧道吞吐受运营商 QoS 影响——**跨运营商时 UDP 可能被限速/丢包**，导致加载超时；同一运营商下通常可达数 MB/s 且不丢包。遇到慢/超时可尝试切换网络或调大加载超时。

## 依赖

| 包 | 用途 |
|----|------|
| `dartssh2`（本地 fork，`third_party/`） | 纯 Dart SSH 客户端：认证 + 本地端口转发 + 保活 + zlib 压缩 / 批量解密优化 |
| `flutter_inappwebview` | WebView、本地缓存控制、缩放 |
| `flutter_secure_storage` | 密码 / 私钥加密存储 |
| `shared_preferences` | 非敏感配置持久化（含缩放比例 / 多实例） |
| `url_launcher` | 打开 GitHub / README 链接 |

## 目录结构

```
lib/
├── main.dart           # 应用入口：主题/全屏、首次启动判断
├── config.dart         # SSH 配置模型 + 持久化（最多 3 路实例 / 加载超时 / 旧配置迁移）
├── tunnel_service.dart # SSH 隧道服务（认证 / 转发 / 保活 / 断线重连 / 双向透传）
├── setup_screen.dart   # 设置 / 首次引导页（实例编辑 / 超时 / 界面控制 / 关于）
└── webview_screen.dart # WebView 主界面（实例切换 / 缓存 / 缩放 / 加载状态）
third_party/dartssh2/   # 本地 fork 的 dartssh2（吞吐优化）
```

## 版本记录

- **v0.1.2**：实例别名（最多 7 个中文 / 15 个英文字母，顶栏优先显示别名而非地址）；首次连接异常静默直接重连、连续异常才提示；修复 Windows 构建（AGP 8.2.1 / minSdk 23 / 禁用 jetifier）。
- **v0.1.1**：多连接实例（最多 3 路）与顶栏切换、可配置页面加载超时、本地 `dartssh2` fork 吞吐优化（zlib 压缩 + 批量解密）、去掉隧道节流、断线重连递增退避 + 上限、release 签名。
- **v0.1.0**：首个发布版。SSH 隧道访问 DSH Web UI，含缩放、全屏、主题自适应、关于页。

## License

[MIT](LICENSE)
