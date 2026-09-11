# DSH-Phone

> 在 Android 上通过 SSH 隧道访问 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web UI 的移动客户端。

DSH-Phone 是一个 Flutter Android 应用：首次启动时配置 SSH 地址 / 用户名 / 认证方式（SSH 密钥或密码），应用自动建立 SSH 隧道（`127.0.0.1:<localPort>` → 远程 `127.0.0.1:3080`），并通过 WebView 加载 DSH Web UI。内置本地缓存加速、SSH 保活、界面缩放与全屏显示、主题自适应，以及手动修改连接配置 / 刷新缓存 / 查看关于的入口。

- **开源地址**：https://github.com/liangjianzeng/DSH-Phone
- **当前版本**：v0.1.9（build 15）
- **安装包**：最新构建产物见 `build/app/outputs/flutter-apk/app-release.apk`；历史版本请在 **GitHub Releases** 下载（仓库不再提交 APK 二进制）。

<!-- 发版检查清单：1) pubspec.yaml 的 version（唯一版本来源，构建 versionName/versionCode）；2) 同步下方「当前版本」；3) lib/config.dart 的 fallbackAppVersion 仅作读取失败兜底，正常 release 自动读取构建版本无需改；4) 打 tag 触发 CI 构建 Releases。 -->

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
- 🔑 **DSH Token 鉴权适配**：新版 DSH 服务端启用 token 鉴权后，在设置中为实例填入「DSH 访问 Token」（显隐切换、随实例切换回填），访问时自动拼接 `?token=` 换取会话 cookie；仅配置了 token 才拼接（旧版服务保持裸地址直连）；token 变更自动重载重新鉴权；401/403 显示专属提示引导填 Token。
- ⏱️ **可配置页面加载超时**：默认 60s、范围 30–180s，设置页滑块调整；大上下文会话历史加载较慢时可调大。
- 🔄 **自动 SSH 隧道**：基于 `dartssh2` 建立本地端口转发，无需 Root。
- ⚡ **SSH 保活与静默重连**：每 10s 发送 keep-alive，降低移动网络空闲断连；首次异常（如隐藏后台 / 黑屏一段时间后断线）**不闪现错误提示、直接默认重连**，连续异常才提示并自动退避重试（递增退避 + 连续失败上限）。
- 🔒 **前台服务后台保活**：隧道连接期间启动 Android 前台服务（低优先级静默通知 + 唤醒锁），App 进入后台或关屏时进程与网络保持运行、SSH 保活持续发送，恢复前台**不再重连**；滑动清除任务后隧道随任务停止。
- 🚀 **隧道吞吐优化**：本地 fork 的 `dartssh2`（认证后 zlib 压缩 + 整包批量解密），双向透传不做应用层节流，显著提升大体积加载速度。
- 🧭 **WebView 加载 DSH Web UI**：`flutter_inappwebview`，loopback 访问，模型/设置等特权接口可用。
- 💾 **本地缓存加速**：优先使用本地缓存，缺才走网络；支持手动清缓存刷新。
- 🔍 **界面缩放**：双指缩放 + 顶栏/设置页 放大、缩小、重置；缩放比例**自动保存**，下次沿用。
- 🎛️ **对话区缩放控件开关**：对话区左侧的放大/缩小/重置浮动按钮默认隐藏，可在设置 → 界面设置中一键开启，避免遮挡内容。
- 📷 **图片直传（视觉工具入口）**：对话区左侧**淡蓝色圆形发光相机按钮**，一眼即可识别视觉能力；点击拍照/相册选图，自动压缩（≤4096px / 90% 质量）后直传 DSH 消息输入窗口附件槽，支持 png/jpeg/webp/gif；默认开启，设置 → 界面设置可关。
- 📤 **文件上传对话处理**：相机入口选择器新增「选择文件上传」——从手机本地选文件（浏览器/网盘等下载到手机的文件），经 SSH 隧道（SFTP）上传至服务器临时目录（自动探测 home 下 `dsh_phone_uploads/`），并把**服务器本地绝对路径**注入消息输入框；补充指令（如 `/home/u/dsh_phone_uploads/xxx.doc 请阅读后总结输出md`）发送后由云端模型处理，产物再经已有下载能力回传手机，形成"端侧上送 → 云端处理 → 结果下载"闭环；上传大小上限**默认 10M、可配置 1–30M**（设置 → 工具）。
- 📄 **成果原生查看器**：点击对话中的成果（Markdown / HTML / 代码 / 文本文件）直接以原生渲染打开——Markdown 渲染、HTML 原生渲染、代码语法高亮，背景跟随深浅色主题；查看页状态栏提供**另存为**按钮，可随时保存到本机。
- 💾 **编码自动检测**：通过 SFTP 读取云端文件，自动识别 UTF-8 / GBK（GB2312）/ ASCII，中文路径与内容不再乱码。
- 📦 **资源下载（断点续传 + 另存为）**：点击 apk / 压缩包等二进制成果进入下载页，显示进度与大小；支持**暂停 / 继续（断点续传）**、取消、失败重试；下载完成弹窗提示，通过系统文件选择器（SAF）**选择保存位置**。
- 🧩 **隐藏产物路径解析**：DSH 产物 chips 被隐藏时，自动用可见产物的目录 + 文件名拼接并经 SSH 验证定位云端路径，确保点击仍能正确分流查看/下载。
- 📊 **主机监控（10 分钟趋势）**：每 10s 采集远程主机 CPU / 内存 / GPU 使用率 / GPU 温度，顶栏背景显示最近 10 分钟趋势曲线（紫色=GPU 使用率 · 黄色=CPU · 蓝色=内存 · 中国红=GPU 温度）；采集命令对 ARM / 精简 / 容器环境健壮（/proc/stat + /proc/meminfo），Windows 走 PowerShell 性能计数器。
- 🎯 **实例级"默认主机资源监控"**：每路实例可单独开启（默认关闭，全局仅允许一个实例开启）；开启后该实例成为全局监控目标，顶栏曲线始终显示它的主机数据（与当前连接实例无关），切换实例曲线不断。
- 🧪 **Unsloth Studio 远程加载**：顶栏设置旁新增 ⚗️ 图标，一键加载远程 Unsloth Studio（复用 WebView 能力）；支持缓存加载与缓存刷新；配置按实例独立——连接端口（默认 8888）、连接方式（HTTP 直连 / SSH 隧道）；登录页**自动登录**（配置登录密码后自动填写并提交，用户名固定 `unsloth`）；默认关闭、全局仅允许一个实例开启（同"默认主机资源监控"模式），顶栏图标始终打开启用实例的 Unsloth Studio。
- ⚡ **设置自动保存**：表单编辑停止即自动落盘（无右上角"保存"按钮），返回设置页自动重连应用最新配置；实例级监控开关切换即生效。
- 🖥️ **全屏边缘到边缘**：顶栏延伸到系统状态栏区域，最大化显示面积。
- 🌗 **主题自适应**：跟随系统深色 / 浅色模式，背景与状态栏图标自动切换。
- ⚙️ **设置管理**：修改地址 / 用户名 / 认证、清空缓存、缩放控制、对话区缩放控件开关、刷新缓存。
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

产物：`build/app/outputs/flutter-apk/app-release.apk`（发版时上传 GitHub Releases，仓库不提交 APK 二进制）

### 使用

1. 首次打开 → 配置 SSH 地址（如 `100.81.83.59`）、用户名（如 `jianzengliang`）、认证方式与本地端口（默认 `3081`）；最多可配置 3 路实例。
2. 保存并连接，隧道建立后自动加载 `http://127.0.0.1:3081` 的 DSH Web UI。若服务端启用了 token 鉴权（访问提示 `dsh web authentication required`），先在设置对应实例填入 DSH 启动时打印的 `?token=` 值。
3. 顶栏：实例切换器 + 连接状态 + Unsloth Studio 入口 + 设置入口。设置页含 SSH 配置、DSH 访问 Token、Unsloth Studio 配置、加载超时、界面缩放 / 刷新缓存、关于信息。

> 说明：远程 DSH 默认只监听 `127.0.0.1:3080`，且配置类接口（如 `settings.describe`）被设计为仅 loopback 访问。DSH-Phone 通过 SSH 隧道把手机本机端口转发到远程，使 WebView 以 loopback 身份访问，从而获得完整功能。
>
> 提示：隧道吞吐受运营商 QoS 影响——**跨运营商时 UDP 可能被限速/丢包**，导致加载超时；同一运营商下通常可达数 MB/s 且不丢包。遇到慢/超时可尝试切换网络或调大加载超时。

## 依赖

| 包 | 用途 |
|----|------|
| `dartssh2`（本地 fork，`third_party/`） | 纯 Dart SSH 客户端：认证 + 本地端口转发 + 保活 + zlib 压缩 / 批量解密优化 |
| `flutter_inappwebview` | WebView、本地缓存控制、缩放、JS 成果识别桥 |
| `flutter_secure_storage` | 密码 / 私钥加密存储 |
| `shared_preferences` | 非敏感配置持久化（含缩放比例 / 多实例 / 缩放控件开关） |
| `url_launcher` | 打开 GitHub / README 链接 |
| `flutter_markdown` | 成果查看器：Markdown 原生渲染（跟随主题） |
| `flutter_highlight` + `highlight` | 成果查看器：代码语法高亮（深浅色主题） |
| `flutter_widget_from_html_core` | 成果查看器：HTML 原生渲染 |
| `charset` | 文件编码自动检测（UTF-8 / GBK / ASCII） |
| `file_picker` | 下载 / 另存为：系统文件选择器（SAF）保存位置 |
| `path_provider` | 下载临时目录 |
| `flutter_foreground_task`（本地 fork，`third_party/`） | 前台服务后台保活（隧道连接期间保持进程/网络，避免后台断线重连；补 namespace 兼容 AGP 8.x） |

## 目录结构

```
lib/
├── main.dart                 # 应用入口：主题/全屏、首次启动判断
├── config.dart               # SSH 配置模型 + 持久化（最多 3 路实例 / 加载超时 / 上传大小上限 / DSH 访问 Token / 旧配置迁移）
├── tunnel_service.dart       # SSH 隧道服务（认证 / 转发 / 保活 / 断线重连 / SFTP 读取与上传 / 路径解析 / 主机密钥 TOFU）
├── setup_screen.dart         # 设置 / 首次引导页（实例编辑 / 超时 / 上传大小上限 / 界面控制 / 关于）
├── webview_screen.dart       # WebView 主界面（实例切换 / 缓存 / 缩放 / 成果识别桥 / 文件上传注入 / 路由）
├── webview_bridges.dart      # WebView 注入的 JS 桥脚本常量（成果点击 / 任务状态 / 图片直传 / 文本注入）
├── host_monitor.dart         # 主机监控（10 分钟趋势采样 / 环形缓冲 / 趋势绘制）
├── artifact_recognizer.dart  # 成果类型识别（markdown/html/代码/文件/资源）
├── artifact_viewer_screen.dart # 成果原生查看器（md/html/代码渲染 + 另存为）
├── download_manager.dart     # 会话级下载管理（断点续传 / 暂停 / 取消）
├── download_screen.dart      # 资源下载页（进度 / 暂停继续 / 另存为）
├── unsloth_screen.dart       # Unsloth Studio 页面（独立 WebView / 缓存刷新 / 自动登录）
├── moon_astronomy.dart       # 真实月球观测计算（Meeus 算法：相位/照明度/盘面朝向）
├── moon_location.dart        # 观测位置解析（默认北京 / 手动经纬度 / GPS）
├── moon_painter.dart         # 月相盘面 CustomPainter（明暗界线椭圆画法）
├── task_notifier.dart        # AI 任务进行中/完成系统通知（锁屏可见）
└── foreground_service.dart   # 前台服务保活封装（隧道连接期间后台保持进程/网络）
third_party/dartssh2/                 # 本地 fork 的 dartssh2（吞吐优化 + SFTP 会话释放）
third_party/flutter_foreground_task/  # 本地 fork 的 flutter_foreground_task（AGP 8.x namespace 兼容）
```

## 版本记录

- **v0.1.9（build 15）**：**文件上传对话处理**——相机入口选择器新增「选择文件上传」：从手机本地选文件（浏览器/网盘等下载到手机的文件），经 SSH 隧道（SFTP）上传至服务器临时目录（自动探测 home 下 `dsh_phone_uploads/`，Linux/Windows 兼容），并把**服务器本地绝对路径**注入消息输入框；补充指令（如 `/home/u/dsh_phone_uploads/xxx.doc 请阅读后总结输出md`）发送后由云端模型处理，产物再经已有下载能力回传手机，形成"端侧上送 → 云端处理 → 结果下载"闭环；上传大小上限**默认 10M、可配置 1–30M**（设置 → 工具）；新增 `composerBridgeJs` 文本注入桥（textarea/contenteditable 多策略）。**版本号单一来源化**：`pubspec.yaml` 作为唯一版本来源（构建 versionName/versionCode），「关于」经 `package_info_plus` 运行时读取构建产物（`v0.1.9 (build 15)`），消除多处手工同步遗漏。
- **v0.1.8（build 14）**：**Unsloth Studio 远程加载**——顶栏设置旁新增 ⚗️ 图标，独立 WebView 页面加载远程 Unsloth Studio；缓存加载 + 缓存刷新（清缓存重载）；配置按实例独立：连接端口（默认 8888）、连接方式（HTTP 直连默认 / SSH 隧道）；登录页自动登录（配置登录密码后自动填写提交，用户名固定 `unsloth`，失败提示检查密码）；默认关闭、全局仅允许一个实例开启（同"默认主机资源监控"模式），顶栏图标始终打开启用实例的 Unsloth Studio；SSH 隧道模式使用独立会话，不依赖当前连接实例；修复自动登录后首页子资源错误误报"无法加载"（仅主框架错误视为致命）。**DSH Token 鉴权适配**——设置页新增「DSH 访问 Token」（可选，显隐切换、随实例切换回填，存 secure storage）；访问仅在有 token 时拼接 `?token=`（旧版服务保持裸地址），token 变化触发重载换取会话 cookie；401/403 显示专属提示引导填 Token（修复 onReceivedHttpError 回调参数类型错误）。
- **v0.1.7（build 13）**：**真实月相天文模型 + 锁屏任务通知**——相机入口按钮呈现真实观测月相（太阳/月球实际位置计算照明度与盘面朝向，含农历日）；观测位置设置（默认北京 / 手动经纬度 / GPS 定位，失败自动回退）；AI 智能体任务进行中/完成时发系统通知（锁屏可见）。
- **v0.1.6（build 12）**：**图片直传（视觉工具入口）**——对话区左侧淡蓝色圆形发光相机按钮（浅蓝圆底 + 蓝色描边 + 双层柔光，突出视觉模型能力）；拍照/相册选图后自动压缩直传 DSH 消息输入窗口附件槽（png/jpeg/webp/gif，非支持格式友好提示）；相机入口可在设置 → 界面设置中开关（默认开启）。
- **v0.1.5（build 11）**：**主机监控完善**——实例级"默认主机资源监控"（每路实例可单独开启、全局仅一个，独立采集隧道，切换实例曲线不断）；**GPU 温度**（中国红曲线）；采集命令健壮化（Linux 用 /proc/stat + /proc/meminfo，ARM/精简/容器兼容；修复 dartssh2 经 bash 执行时 `sh -c` 包装导致的引号嵌套 EOF；Windows PowerShell 变量 `$` 转义）；监控曲线步长修复（10 分钟固定步长、最新点右对齐）；**设置自动保存**（去掉右上角"保存"按钮，表单编辑停止即落盘，返回自动重连生效）。
- **v0.1.4（build 9/10）**：代码质量与隐患修复——设置保存后强制重连（配置立即生效）、下载取消"死任务"修复与断点续传并发守卫、下载任务内存释放、connect/disconnect 竞态守卫、secure storage 读取兜底与敏感项删除同步、重连 off-by-one、print→debugPrint、JS 桥 fetch 大小/超时限制与敏感数据清理、端口范围校验、资源下载链接型 APK 路径反查与失败自动重试、主机监控窗口 1 小时 → 10 分钟。
- **v0.1.3**：成果原生查看器（Markdown / HTML / 代码高亮 / 文本，编码自动检测，另存为）；资源下载（进度、暂停/断点续传、取消、失败重试、SAF 另存为）；对话区缩放控件开关（默认隐藏）；隐藏产物路径自动解析；SFTP 读取解决中文路径/内容乱码。后续补丁（build 6）：**前台服务后台保活**（隧道连接期间启动低优先级静默通知前台服务 + 唤醒锁，App 后台/关屏时 SSH 保活持续发送，恢复前台不再重连；滑动清除任务随任务停止）；**SFTP 会话释放**（每次文件操作关闭底层 SSH 通道，避免 OpenSSH 会话泄漏）；前后台生命周期诊断日志。
- **v0.1.2**：实例别名（最多 7 个中文 / 15 个英文字母，顶栏优先显示别名而非地址）；首次连接异常静默直接重连、连续异常才提示；修复 Windows 构建（AGP 8.2.1 / minSdk 23 / 禁用 jetifier）。
- **v0.1.1**：多连接实例（最多 3 路）与顶栏切换、可配置页面加载超时、本地 `dartssh2` fork 吞吐优化（zlib 压缩 + 批量解密）、去掉隧道节流、断线重连递增退避 + 上限、release 签名。
- **v0.1.0**：首个发布版。SSH 隧道访问 DSH Web UI，含缩放、全屏、主题自适应、关于页。

## License

[MIT](LICENSE)
