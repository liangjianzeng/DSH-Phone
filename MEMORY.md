# 项目记忆 (Project Memory)

本文件供后续会话在开头快速读取，避免重复踩已知坑、重复排查。

---

## 🔴 红线禁令：禁止卸载 (2026-10-03 记录)

- **未经用户明确允许，禁止 `uninstall` / 卸载任何应用，禁止删除用户数据。**
- 推送一律使用**覆盖安装**：`adb install -r <apk>`。
- 若签名不一致导致覆盖失败：先排查并**统一签名**（如让 debug 也使用 release 证书），**而不是卸载重装**。
- 违反此规则后果极其严重，绝不可再犯。
- 相关背景：release 签名 `android/key.properties` → `../key.jks`（证书 CN=TongYiLite）；已改 `android/app/build.gradle` 让 debug 在有 key.properties 时也用 release 证书签名，保证可覆盖安装。

---

## Git 拉取代码 (pull) — 已知坑与最优流程

### 问题现象
在 DSH Harness 沙箱环境中执行 `git fetch` / `git pull` 时，Git Bash 的 `sh.exe` / `ssh.exe` 会崩溃：

```
sh.exe: *** fatal error - CreateFileMapping S-1-5-21-...-1001.1, Win32 error 5.  Terminating.
fatal: Could not read from remote repository.
```

关键点：`sh.exe -c 'echo hi'` 直接运行也会崩 —— **所有 MSYS2 二进制**（依赖 `msys-2.0.dll`）都在初始化阶段崩溃，但 `git.exe` 本体正常。所以这不是网络或权限问题，而是 MSYS2 跑不起来。

### 根因
DSH **文件沙箱**阻止了 MSYS2 创建**会话文件映射**（session file mapping，Win32 error 5 = access denied）。沙箱模式为 `workspace-write` 时会拦截该映射，导致 sh/ssh 必崩。

### 最优解（推荐，一次配置永久生效）
- 让 DSH 文件策略使用 **`danger-full-access`**（而非 `workspace-write`）。
- 在此策略下 `sh.exe` / `ssh.exe` 可正常创建会话映射，git 网络操作直接可用，**无需任何 hack**。
- 直接执行即可：
  ```
  git pull --ff-only origin main
  ```
- 验证：策略为 danger-full-access 时，`sh.exe -c 'echo ok'` 能正常输出。

### 降级方案（若只能在 `workspace-write` 下工作）
MSYS2 进程会崩，git 无法走 SSH。此时：
- 本仓库 origin 本是 HTTPS，但有全局 git 规则 `url.git@github.com:.insteadof=https://github.com/` 强制把 https 改写成 SSH，从而触发 sh 崩溃。
- HTTPS transport 在 git 进程**内**运行（`git-remote-https` 是 built-in，不经过 `sh.exe`），所以可绕过：
  ```
  git -c url.git@github.com:.insteadof= fetch \
      https://<user>:<token>@github.com/<owner>/<repo>.git
  ```
  需要有效的 GitHub **token**（SSH 密钥不能用于 HTTPS）；内嵌 token 可跳过 credential helper（后者也会走 sh）。

### 其他注意事项
- 远程：`git@github.com:liangjianzeng/DSH-Phone.git`（经 insteadof 实际走 SSH）。
- 本地有未提交 `pubspec.lock` 改动时，只要新提交不触碰该文件，`--ff-only` 可干净合并（快进）。
- 拉取前可先 `git log --stat <old>..<new>` 确认受影響文件，预判是否可能与未提交冲突。

## 天气能力（2026-10 新增）

- **数据源：Open-Meteo**（`https://api.open-meteo.com/v1/forecast`）：免费、免 API Key、HTTPS、国内可直连（2026-10 实测 2s 返回）。返回 WMO 标准天气码 + 温度 + 降水量。若日后失效/被墙，替代品评估过 ghproxy 类镜像不可用于 API、和风天气需注册 Key。
- 查询节奏：APP 启动一次 + 每小时定时（`WeatherService`）；观测位置变化去抖 3s 重查（坐标容差 0.01°）。HTTP 用 `dart:io` HttpClient（项目未引入 http/dio 依赖，保持零新增依赖）。
- 相关文件：`lib/weather_service.dart`（数据）、`lib/weather_effects.dart`（动效）、`lib/sun_times.dart`（日出日落，NOAA 公式，纯本地计算）。开关键：`weather_effects_enabled`（默认开）、`moon_sun_switch_enabled`（日出日落联动，默认开）。

---

## 代码约定 (Coding Conventions)

> 后续补充：语言（中/英）、命名规范、目录结构、提交信息规范（conventional commits）等。

---

## 开发环境 (Dev Environment)

- **Flutter 路径**：`C:/src/flutter/bin/flutter`（Git Bash）/ `C:\src\flutter\bin\flutter.bat`（PowerShell / CMD）。不在系统 PATH，未安装到常见位置。
- **静态分析**：`flutter analyze`（项目根目录）。分析单文件：`flutter analyze lib/webview_screen.dart`。
- **构建 APK**：`flutter build apk --release`，产物 `build/app/outputs/flutter-apk/app-release.apk`。
- **打包默认 release（用户要求，2026-10-02）**：给手机装包/上传 Releases 一律 release 构建；仅在明确的 bug 排查需要时才构建 debug 版。
- 改完代码后先 `flutter analyze` 确认无报错再提交。
- **沙箱限制（重要）**：DSH 文件策略为 `workspace-write` 时，**dart/flutter 工具启动即挂起**（连 `dart --version` 都无输出，与 git/MSYS2 同源）。必须 `danger-full-access` 策略下才能运行 `flutter analyze` / `flutter build` / `dart format` 等。

---

## APK 打包与完整性核验（2026-10-18）

- **构建命令**：`flutter build apk --release`，产物 `build/app/outputs/flutter-apk/app-release.apk`。APK 已入 `.gitignore`（不进 Git，历史版上 Releases）；本地构建产物同路径。
- **22MB 是正常的、包是完整的**，不要误以为截断或漏打。实测拆解：
  - 解压后 `lib/` = **47.4MB** → 压缩进 APK 约 20MB（`.so` 已编译，压缩率 ~2:1）；加 dex/资源/清单 ≈ **22.3MB** 成品。解压体积 ≈ 压缩后 2.4 倍，对得上即完整。
  - **arm64-v8a 单一架构**（现代手机几乎都是 arm64，无需四架构重复，否则体积翻倍）。
  - `lib/` 内含真货：`libonnxruntime.so`(21.7M) + `libapp.so`(11.4M, Dart+sherpa C++) + `libflutter.so`(10.6M) + sherpa 双 `so`(4.8M)。
  - **ASR 模型(~160MB)不打包**：运行时下载（代码设计"不新增下载、体积不变"）；**WebView 用系统 WebView**，不内置 Chromium（否则 +40~50M）。github.com / DSH / Unsloth 加载都依赖系统 WebView（安卓预装）。
- **沙箱内无 adb 时，如何核验一个 APK 是否完整**：
  - 列清单：`jar tf <apk>`（`jar` 在 JDK bin；`unzip`/`7z` 本机未必有）。
  - 看 `lib/<arch>/*.so` 是否齐全（flutter/app/onnxruntime/sherpa 等关键库），`assets/` 是否误打/漏打模型。
  - 拆包算大小：`Expand-Archive` 只认 `.zip` 后缀，需先 `Copy-Item .apk .zip` 再拆；`Get-ChildItem -Recurse` 算 `lib/` 总大小，与 APK 压缩后大小对得上即完整。
  - **受限语言模式挡 `[System.IO.Compression.ZipArchive]` 等 .NET 静态调用**，用 cmdlet/CLI（`Expand-Archive` / `jar`）而非 .NET 类型。
- 改完代码先 `flutter analyze` 确认无报错再构建（dart 分析器走 `C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe`）。
- **打完包，回复里必须交付这四项（2026-10-20 用户定的固定要求，默认执行、不再等提醒）**：
  1. **绝对路径**（不写 `build/...` 这种相对缩写）：`/home/jianzengliang/MyWork/DSH-Phone/build/app/outputs/flutter-apk/app-release.apk`
  2. **字节数**（`ls -l` 真实值，顺手换算 MiB）；
  3. **`sha256sum` 全量哈希**（装机方比对用，别只给前几位）；
  4. **签名主体 + 构建时间**（`tool/build_apk.sh` 末尾那行 `CN=TongYiLite` 验收）。
- 另附两条自证（避免"我以为编译进去了"）：构建前 `git status --porcelain lib tool pubspec.yaml .github test` 必须为空，即**包 = 已提交树**；构建后抽 `libapp.so` 抽查本轮新增的字符串/文案确在包内：
  `unzip -oq <apk> lib/arm64-v8a/libapp.so -d /tmp/x && python3 -c "d=open('/tmp/x/lib/arm64-v8a/libapp.so','rb').read(); print('某新文案' in d.decode('utf-16-le', 'ignore') or '某新文案' in d.decode('utf-8','ignore'))"`
  （Dart 快照里的中文串按 UTF-16 存，直接 `grep` UTF-8 会误报"缺失"。）

---

## CI 门禁红两周的三条根因（2026-10-20 修复）

- **现象**：CI 矩阵两条 leg 连续两周每次 push 全红，没人看得见原因（匿名取
  Actions 日志是 **403**，`gh` 也没装）。门禁形同虚设比没有门禁更坏。
- **根因 1｜setup 阶段就挂**：矩阵把通道名 `'stable'` 当版本号传进
  `subosito/flutter-action@v2` 的 `flutter-version`，上游元数据一变就取不到发布物。
  传空串 `flutter-version: ''` **也不行**（仍按版本号校验）。最终拆成两个 job：
  基线 job 传 `flutter-version: '3.27.0'`，预警 job 只给 `channel: stable`。
- **根因 2｜info 级也能致命**：`flutter analyze` 默认 `--fatal-infos`（实测一个
  info 就 exit 1）。Flutter 升级后 `Radio.groupValue/onChanged` 变 deprecation info，
  代码没动 CI 就红。门禁改为 `--no-fatal-infos` 只卡 error/warning，info 另起一步
  贴进 Job 摘要（不拦合并，也不静默丢弃）。
- **根因 3｜vendored fork 拖死主门禁**：根 `flutter analyze` 会分析 `third_party/**`，
  上游 deprecation 直接把仓库拖红。`analysis_options.yaml` 排除 `third_party/**`，
  但**必须在 test 之前**对两个 fork 各跑一道 `dart analyze`（只卡 error/warning）——
  否则 fork 的**编译错误**只表现为"某几个 test 文件 loading [E]"，根因看不见。
  现在失败仍是 error 级，只是不再被上游的 deprecation 噪声淹没。
- **稳定版 leg 目前仍红（未修完）**：`tunnel_policy_test` / `download_manager_test` /
  `artifact_viewer_screen_test` 三个文件加载失败——恰好是**仅有的三个**（传递）引入
  `tunnel_service.dart → dartssh2` 的测试，指向 fork 或其上游依赖（pointycastle /
  asn1lib / pinenacl）在新 SDK 下的编译问题。本仓库不提交 `pubspec.lock`，CI 每次
  重新解析，上游发新版就会编出本地从未见过的错误。已在门禁摘要里输出
  `flutter pub deps --style=compact`，取到原因后二选一：提交 `pubspec.lock`
  （应用项目本就该提交）或给肇事依赖加上界。**在此之前稳定版 leg 设为
  `continue-on-error: true`，只预警不拦合并。**
- **落地形式**：门禁逻辑收敛进 `tool/ci_gate.sh`（JS 桥 → fork → analyze → info 汇总
  → test → 依赖清单），CI 与本地提交前跑**同一份**；失败原因写成 `::error::` 注解，
  不登录也能用 `GET /repos/{o}/{r}/check-runs/{id}/annotations` 读到。
  本地自查：`bash tool/ci_gate.sh`（`--skip-test` 快速版）。
- **GitHub API 匿名配额只有 60/小时**：轮询 CI 每次至少 2 个请求，十几次就
  `403 rate limit exceeded`。轮询要稀疏（30s+ 且只查一次 check-runs），
  或先查 `/rate_limit` 再决定。

---

## Linux(aarch64) 打包机：本机编 APK（2026-10-19）

> 本机的 Linux 侧构建记录（Ubuntu 24.04 / aarch64，`Linux 7.0.0-1019-nvidia`）。结论：**能本机出 release APK**，
> 但要过四道与项目代码无关的坑；全部固化在 `tool/build_apk.sh`（自检 + 修产物 + 构建）。

- **一次性环境准备**（root，本机已装好）：
  - `sudo dpkg --add-architecture amd64`；另建 `/etc/apt/sources.list.d/amd64-foreign.sources`，`URIs` 必须指 `http://archive.ubuntu.com/ubuntu/`（ports 源没有 amd64），`Architectures: amd64`，再 `sudo apt-get update`。
  - `sudo apt-get install -y libc6:amd64 libstdc++6:amd64 zlib1g:amd64`。**zlib1g 漏装极难查**：NDK clang 起不来，CMake 只留一句 `The C compiler identification is unknown`。
  - `sudo add-apt-repository -y ppa:fex-emu/fex && sudo apt-get install -y fex-emu-armv8.2`（原因见第 4 条）。
- **`android/local.properties` 必须是 `sdk.dir=/home/jianzengliang/android-sdk`**。写成发行版自带的 `/usr/lib/android-sdk`（只有 platform-tools，没有 platforms/build-tools/ndk）会让 Gradle 找不到 compileSdk，`flutter doctor` 也跟着报 "cmdline-tools component is missing"。
- **Google 不发 linux_arm64 的 Android 原生工具**：`repository2-3.xml` 里 `linux_arm64` 出现 **0 次**——aapt2、build-tools、NDK clang 全是 x86-64，只能靠 qemu-user binfmt 透明执行。缺 amd64 运行库时报 `x86_64-binfmt-P: Could not open '/lib64/ld-linux-x86-64.so.2'`（debug 构建表现为 `AAPT2 ... Daemon startup failed`）。
- **Flutter 官方不发 arm64 Linux 主机的 Android AOT 快照生成器**：`flutter_tools` 的 `_linuxBinaryDirs` 只列 `android-<abi>-<mode>/linux-x64.zip`（**master 分支至今如此，升级 Flutter 也没用**），运行时却按 hostArch 去 `android-<abi>-<mode>/linux-arm64/gen_snapshot` 找。`tool/build_apk.sh --fix-artifacts` 下载官方 linux-x64 里的 `gen_snapshot` 放进 `linux-arm64/`（md5 必须与官方一致；**别拿别处的二进制顶替**——桌面版 `linux-arm64/gen_snapshot` 不认 `--target-os`，编不出安卓快照）。
- **qemu-user 跑 gen_snapshot 必崩——别再在 qemu 上耗时间**：表现 `Dart snapshot generator failed with exit code -11`、`qemu-x86_64: QEMU internal SIGSEGV {code=MAPERR, addr=0x20}`（是 **qemu 自己**段错误，不是 guest 崩）。已实测 **qemu 8.2.2（Ubuntu）与 10.0.0（Alpine/musl）表现完全一致**；`-cpu max`、`-cpu qemu64,+avx`、`-singlestep`、`-R <reserved_va>`、屏蔽 `/proc/self/maps`、去掉 `--strip/--deterministic` 全部无效。根因：guest 里 Dart 发出尺寸下溢的 `mmap(NULL, -4096, …)`，真内核返回 ENOMEM 而 qemu 误报成功，VM 随后进入坏状态。**出路是换模拟器**：FEX（FEXCore，x86-64 on AArch64）跑同一个官方 x64 `gen_snapshot`，21s 正常产出 `app.so`。
  - 落地：`gen_snapshot` 位置换成薄包装（真身改名 `gen_snapshot.bin`），有 FEX 走 FEX、没有则退回 binfmt。只动这一个文件，**不改系统 binfmt**（amd64 容器仍依赖 qemu）。
  - aapt2 / NDK clang 用 qemu 就够，不需要 FEX。
- **验证过的成功路径**：`git worktree` 干净检出 HEAD 后 `tool/build_apk.sh --fix-artifacts` → `✓ Built build/app/outputs/flutter-apk/app-release.apk (23.4MB)`，约 6 分钟；抽出的 `libapp.so` 是真 arm64 AOT（`file` 报 ARM aarch64，`_kDartIsolateSnapshotInstructions` 在位）。
- **本机仍不等于能发正式包**：`android/key.properties` 与 `key.jks` 不在这台机器上，release 会**静默回退 debug 签名**（能装能跑，但不能覆盖安装已装正式版、不能上 Releases）。正式包继续走 CI（打 tag → GitHub Actions x86-64 runner）或 Windows 打包机，直到证书拷来。
- **DSH 沙箱注意**：策略 `workspace-write` 时 flutter 启动即挂在 `bin/internal/update_engine_version.sh: .../engine.version: 权限不够`（它要写 `~/flutter/bin/cache`），跑 flutter/dart 需 `danger-full-access`。

---

## zcode-phone-server 位置（2026-10-04 迁移）

- **桥接服务已迁入本项目**：`E:\DTXY\DSH-Phone\zcode-phone-server\`（原来是 `E:\DTXY\zcode-phone-server`，旧路径已不存在）。
- 它是**独立 git 仓库**（嵌套在 DSH-Phone 下），已加入 DSH-Phone `.gitignore`（`/zcode-phone-server/`），不要在 DSH-Phone 仓库里提交它。
- 启动：`cd E:\DTXY\DSH-Phone\zcode-phone-server && node server.mjs`（监听 `127.0.0.1:8787`，token 见启动日志/配置）。也可用 `start.bat`。
- 其提交记录在 zcode-phone-server 自己的仓库里（如 PAGE_BUILD '2026-10-04.10' 等前端改动），不要去 DSH-Phone 仓库找。
- 手机的 WebView 页面缓存是**刻意保留的**（用户明确要求），主文档带 `Cache-Control: no-cache` 请求头保证鉴权链路不缓存。

---

## 语音自动发送踩坑：发送按钮匹配纪律（2026-10-04，commit 13b65a0）

- **现象**：语音松手后消息留在 ZCode 输入框不发送，App 却提示「已发送」。
- **根因**：`webview_bridges.dart` composerBridgeJs 的 `send()` 曾对页面**所有** button/[role=button] 按 `textContent` 子串匹配「发送/send」并点击第一个命中。zcode 页面 `#todoBar`（role=button 任务计划条，DOM 顺序先于 `#btnSend`）正文是动态 todo 文本——todo 出现 "send-now 端点" 即被误点（展开/收起 todos），且桥返回 `{ok:true, via:'button'}`。
- **修复纪律**：匹配只认 `id`/`aria-label`（btnSend/aria=发送）；短文本(≤16字)命中仅限真实 `<button>` 标签，role=button 容器绝不按正文匹配；排除「停止/打断/取消发送」；隐藏元素（offsetWidth/Height/ClientRects 全 0）跳过。
- **验证手段**：puppeteer-core + 本机 zcode-phone-server(8787) 加载真实页面，注入 Dart 源里提取的桥 JS，监听 capture 阶段 click 落点 + 拦截 /api 请求——比静态读代码可靠，前端桥逻辑改动建议沿用此法（测试脚本在 /tmp/bridgetest）。

---

## zcode 页面相机/上传注入失效：原生桥必须钉死防覆盖（2026-10-06）

- **现象**：zcode 模式下相机控件拍照/传图毫无反应（App 侧桥还返回 `{ok:true}` 不报错），上传路径注入同受影响。
- **根因**：zcode 页面（`zcode-phone-server/public/index.html`）本来就内置 `__dshComposerBridge`/`__dshPhotoBridge` 原生实现（拍照直进待发附件槽 `pendingImage`）；但 App 在每次 onLoadStop 无条件注入 DSH 通用版同名桥（photoBridgeJs 裸赋值覆盖），通用版拍照走「document 合成 drop」——DSH 页面有 drop 监听而 zcode 页面没有，事件落空且静默成功。
- **修复（后台统一适配安卓前端，App 零改动）**：① 页面用 `Object.defineProperty(writable:false, configurable:false)` 把两个 DSH 命名桥钉死在 window，App 注入的裸赋值静默失败，原生实现恒胜出；② 页面补 document 级 `dragover`/`drop` 监听（含 Files 才 preventDefault，纯文本拖拽保留 textarea 原生行为），路由到 `handleFilePicked`——桌面拖文件与旧版 App 合成 drop 统一入口；③ `insertText` 语义对齐 DSH 版：光标处插入保留草稿（原实现整体替换会清掉用户已输入内容）。
- **纪律**：zcode 页面今后新增 App 桥一律走 defineProperty 钉死，不能裸赋值 `window.__dshXxxBridge`。
- **验证**：/tmp/bridgetest/test8.js（puppeteer-core 复刻 App 时序：页面加载→注入 Dart 源提取的通用桥→验证钉死未覆盖→pickImage/insertText/合成 drop/send 桩全链路 6 项 PASS）。注意 async 断言要在事件后 sleep 一拍再读 DOM（handleFilePicked 内有 await arrayBuffer）。
- **🔴 重启红线**：**桌面端当前会话可能就跑在 zcode-phone-server 上**（`/api/sessions` 里 BUSY 的标题即当前对话）——会话进行中绝不能重启服务（restart_server.sh 只 watch 两个旧会话 id，不含当前会话，会把自己杀掉）。页面改动部署到手机**无需重启**：服务端每请求都从磁盘读 index.html 且主文档 no-cache，手机端重进页面即得新 JS；PAGE_BUILD 指纹仅影响自动 reload 提示，下次自然重启后自会更新。

---

## 隧道监督器与自愈不变量（2026-10-06 建立，2026-11 全量重构为 TunnelService 监督器）

**演进**：原来"重连几次、什么时候报错、要不要重建"散落在 `webview_screen.dart`
（`_scheduleReconnect` 5 次上限 / `_handleConnectFailure` 首次静默 / `_recoverAfterResume`
自己 HTTP 探测后 disconnect+connect）。三套逻辑并发打架：UI 侧计数被并发 `connect()`
清零、5 次烧完后**再没有任何定时器**（表现为"一直提示连接不上，重试也不成功"）、
回前台的探测走带 token 的完整地址（每次回前台重跑鉴权链）。现在**唯一事实来源**是
`TunnelService` 的 `TunnelState` 快照 + `stateStream`，UI 只渲染不决策。

- **决策层（纯 Dart，零依赖，可单测）**：`lib/tunnel_policy.dart`
  - `classifyTunnelFailure()`：DNS / 不可达 / 被拒 / 超时 / 认证 / 主机密钥 / 私钥 / 远端无应答 / 本地端口 → 决定"该重试"还是"该提示改设置"；
  - `TunnelBackoff`：0.8s 起、×2、封顶 60s、±25% 抖动、**永不放弃**（老实现的头号杀手是"放弃"）；
  - `TunnelAlertPolicy`：`silent/busy/attention/hard` 四级。链路抖动最多 `busy`（非阻塞横幅），配置类错误（认证/主机密钥/私钥/本地端口）直接 `hard`。
- **观测层**：`lib/tunnel_diagnostics.dart` 环形缓冲（400 条）+ `lib/tunnel_diagnostics_screen.dart` 事件流页。真机 + VPN 没有 adb，这是唯一能事后定位"到底哪儿断"的入口 —— **不要再把它从设置页摘掉**（入口：设置→主机→连接诊断；主界面横幅「详情」也进这里）。
- **监督器不变量（改 `tunnel_service.dart` 前先读懂）**：
  1. `connect()` **幂等且不抛异常**：并发调用共享 `_inflight`，永不 reject。UI 侧任何"await connect 成功就当已连接"的写法都是错的，结论只能来自 `stateStream`。
  2. 假死必须能被发现：`SSHClient.ping()`（`keepalive@openssh.com`）**无超时**、`forwardLocal()` 的 `_waitChannelOpenReply` **无超时**，半开连接上二者**永久挂起**。所以：转发建链 `.timeout(8s)`、`ping` 包 `.timeout(4s)`、看门狗每 15s 对 `http://127.0.0.1:localPort/` 做**端到端**探活（不带 token、`followRedirects=false`；只做 TCP connect 没用，我们的 `ServerSocket` 在传输层已死时照样 accept）。
  3. 区分「SSH 死了」和「云端服务没起」：探活失败先 `ping` 传输层，活着 → `kind=remoteDown`（**不重建**，重建也白建），死了 → 连续 3 次 `_forceRebuild`。
  4. `_wantConnected` 是唯一的"用户意图"开关：只有 `connect()` 置真、`disconnect()/dispose()` 置假。探活、转发回调、网络变化监听**都不许**绕过它自行建链。
  5. 网络变化不用 `connectivity_plus`（未引入，别加）：`NetworkInterface.list()` 签名轮询（15s）变化即立刻重试。
  6. 前台服务：`_wantConnected && status != idle` 期间保持（旧实现只在 `connected` 保活 → 后台重连过程中 wakelock 被摘掉，越断越连不上）。
  7. `_hostTypes` 以 `host:port:username` 为 key（曾是 `Map<SSHClient,HostType>`：每次重连都泄漏一条 + 重新探测）。
  8. **绝不开启 dartssh2 的 zlib 压缩**：fork 的 `_compressData` 会吐出 0 字节，开了就等于亲手造一个假死。
  9. **世代号 `_generation` 是"作废在途尝试"的唯一手段**：`disconnect()` / 目标切换 / `dispose()` 都 `_bumpGeneration()`。`_attemptOnce` 在建链前后各复查一次 `aborted()`，`_openTunnel` 在登记 `_client` 前、`authenticated` 后、绑定端口后各复查一次；被取消的尝试抛 `TunnelAbortedException`，**不落失败状态、不排退避**。只靠 `_wantConnected` 挡不住——`await SSHSocket.connect` 回来时没人复查，会把已断开的隧道连回来并起看门狗。
  10. `_teardown()` 必须在**任何 await 之前**同步摘走 `_client`/`_server`：否则 `await server.close()` 让出的那一拍里，旧 client 的 `_onTransportClosed` 守卫（`_client != client`）仍然通过，会给一条即将成功的新隧道排个退避定时器 → 十几秒后新隧道被自己拆掉。同理：建链成功分支必须 `_retryTimer?.cancel()`（`clearNextRetry` 只清界面字段），`_scheduleRetry` 的回调要校验世代。
  11. **"端到端存活"只认下行数据**：`_pipe` 只在 `forward.stream` 侧调 `_noteForwardActivity()`。上行 `forward.sink.add` 只是入队，半开链路上本地能"一直在发"，用它当证据 = 假死永不可发现（而且 `probeOk` 被写真后连横幅都藏了）。新鲜窗捷径只允许**维持**既有健康，不能把 `probeOk` 从 false 翻成 true；`_teardown` 必须清 `_lastForwardActivity`。
  12. `forwardLocal()` 超时后**必须自己收尾迟到的 channel**：`Future.timeout` 不取消源 future，服务端晚一拍回 OPEN_CONFIRM 时 dartssh2 仍会把 channel 登记进 `_channels` 并在远端建一条 TCP；超时/失败分支要 `openFuture.then((c) => c.destroy())`，否则每次超时永久泄漏一条 channel + 一条远端连接。
  13. `_inflight` 去重要连**目标 key** 一起比（`_targetKey`）：否则 A 实例的在建尝试会被 `connect(B)` 当成 B 的成功返回 → B 的页面跑在 A 的隧道上。
  14. 网络接口变化**不许清零退避**：tun0/WiFi 交接会让签名每 15s 变一次，`_resetAttempt()` 等于每 15s 一轮全量握手（认证风暴）。用 `networkRetryCooldown`(12s) + `_attempt` 降级不归零。
  15. 主机类型缓存（`_hostTypes`，key=`host:port:username`）**只在拿到非空输出时写**：`_execOn` 超时返回 null 曾被当成"这是 Windows"永久缓存，Linux 主机从此走 PowerShell 采集、`ensureUploadDir` 探测 `C:/Users/...`。
  16. 主机密钥 TOFU 不匹配**不许用服务级 bool 传递**（`testConnection`/监控/Unsloth 并发共用会串档，把主隧道的 DNS 失败误判成 hostKey 弹红）：走 `_verifyHostKey(onMismatch:)` 局部标志 → 抛 `TunnelHostKeyMismatchException`。
  17. `ForegroundTunnelService` 的**期望态与实态分开**（`_want` / `_started`）并用 `_chain` 串行下发。旧实现 `_started` 在 await 之后才置位 + `stop()` 用 `if (!_started) return`：`disconnect()`→`connect()` 紧邻时会留下永久 wakelock，或者整个会话没有前台服务（后台重连最怕 Doze）。
- **dartssh2 fork 的本地加固**（`third_party/dartssh2`，同步上游时务必保留，共 5 处）：
  `ssh_socket_io.dart` 加 `TCP_NODELAY`；`ssh_transport.dart` `_onSocketData` 的非 `SSHError` 改为 `closeWithError(SSHInternalError)`（原来 `rethrow` 变成 uncaught zone error → 接收循环卡死而 `isClosed` 仍为 false，就是"显示已连接但已经死了"的成因）；`ssh_client.dart` `_handleTransportClosed` 用 `Channel_Open_Failure` 收尾 `_channelOpenReplyWaiters`（并 `_channelIdAllocator.release` 归还 id）；`_closeChannels()` 与 `close()` 各自包 try/finally——`channel.destroy()` 在传输已死时同步抛 `SSHStateError`，不防护的话 `_channels.clear()` 被跳过、**`_transport.close()` 永不执行**（fd 与远端 sshd 连接槽泄漏，还被调用方静默吞掉）。
- **UI 侧不变量（`webview_screen.dart`）**：
  - `_webViewAlive`：连上过就**常驻** WebView。旧结构按状态切分支、WebView 只活在 connected 分支，每次闪断都 dispose 整棵 WebView（SPA 状态全丢 + 整站重载），把网络抖动放大成"老是重新加载"。换实例时显式置假强制重建。
  - 链路不健康时：不弹红色全屏、不显示加载遮罩、**不烧** `_pageRetryCount`，只挂非阻塞横幅（`_buildTunnelBanner`）+ 置 `_pageNeedsReload`；`_onTunnelState` 在恢复健康时自动补载。
  - `_onAuthError` 先带已保存 token 自动重试一次（`_authRetryCount`）再要用户填 Token。
  - 顶栏必须有主动刷新入口：`_buildConnectionButton` → `forceRefresh()`（旧版顶栏没有任何重连入口，假死时用户只能杀 App）。
- **回归**：`test/tunnel_policy_test.dart`（分类 / 退避单调+封顶+抖动 / 分级 / 状态文案 / 环形缓冲）。改策略层必须让这些断言继续成立。

---

## Tailscale 场景断连排查清单（2026-11 专项）

用户报"VPN 的 SSH 很容易断、一直提示连不上"时，**先看 App 内「连接诊断」的事件流**，
按类别分流，别再让用户盲猜：

| 事件流特征 | 判定 | 处置 |
| --- | --- | --- |
| `dns` / `Failed host lookup: *.ts.net` | Tailscale 未就绪或 MagicDNS 没生效 | 确认 App 有本地网络/VPN 权限；改用 IP 直连（设置里填 IP，不走 MagicDNS） |
| `unreachable` / `Network is unreachable` | 节点没在线、key 过期、或不在同一 tailnet | `tailscale status` 看对端是否 `offline`；重登 |
| `refused` | 服务端 sshd 没起 / 端口不对 | 属配置类 → App 直接提示"改设置"，不无限重试 |
| `timeout` + 反复 `probe` 失败但 `ping` 传输层活着 | **云端服务没起**（DSH 3080 / Zcode 8787 / WorkBuddy 8790） | 提示"云端服务没有应答"，不重建 SSH；让用户起服务，别甩锅网络 |
| 建链后突然 `transport closed`、`forward open timeout` | 中间设备/NAT 掐空闲连接 | 见下方服务端配置 |
| 回前台必断 | 系统冻结进程 + Doze 掐网 | App 已用前台服务 + 回前台 `notifyShouldReconnectNow`；仍断则查电池优化白名单 |

**服务端 `/etc/ssh/sshd_config` 建议**（空闲被 NAT/运营商掐断的最常见解药）：
`ClientAliveInterval 20`、`ClientAliveCountMax 6`、`TCPKeepAlive yes`；
改完 `sshd -t` 校验再 `systemctl reload sshd`。

**客户端环境建议**：手机与服务端尽量**同一运营商/同一 NAT 出口**（跨运营商对端直连
最容易被打孔超时）；把 App 加入电池优化白名单；Tailscale 侧开启 `Keepalive`
（`tailscale set --... ` 或管理面板的 persistent keepalive）避免 DERP 空闲掉线。

**验证方式**：设置→主机→「测试连接」确认 SSH 可通；主界面顶栏云图标点一下 =
`forceRefresh()` 端到端探活；然后开「连接诊断」挂机 10 分钟，看 `probe`/`transport`
事件密度，比让用户复现"有时候会断"有用得多。

---

## 质量整改记录（2026-09 体检整改，commit 2360f85）

- **主机密钥 TOFU**：`tunnel_service.dart` 不再无条件信任主机密钥。指纹按 `host:port+算法` 存 SharedPreferences（键 `ssh_hostkey_*`）；首次记录、后续比对、不匹配拒绝并提示。服务器重装/换密钥后：设置页「清除指纹」按钮（`TunnelService.clearHostKeyFingerprints()`）清除后重新记录。
- **明文流量**：`AndroidManifest.xml` 移除全局 `usesCleartextTraffic="true"`，改用 `res/xml/network_security_config.xml` 仅对 `127.0.0.1`/`localhost` 放行明文（SSH 隧道 WebView 访问）。
- **APK 不再提交 Git**：`apk/` 已入 `.gitignore`，历史版本上传 GitHub Releases；本地构建产物仍为 `build/app/outputs/flutter-apk/app-release.apk`。
- **测试与 CI**：`test/` 有 4 个单元测试（artifact_recognizer / moon_astronomy / config / download）；`.github/workflows/ci.yml` 跑 analyze+test（Flutter 3.27.0/stable 矩阵），打 tag 自动构建 APK 并上传 Releases。
- **版本号（单一来源）**：`pubspec.yaml` 的 `version` 是唯一版本来源（构建 versionName/versionCode）。「关于」对话框经 `package_info_plus` 运行时读取构建产物显示（如 `v0.1.9 (build 15)`），不再手工维护常量；`lib/config.dart` 的 `fallbackAppVersion` 仅在读取失败时兜底。发版时同步：pubspec `version` + README 顶部「当前版本」+ config `fallbackAppVersion`（兜底，正常 release 可不动）。

---

## 手机端"看不见智能体在做什么"：完成态工具行摘要被 CSS 藏掉（2026-10-04）

- **现象**：手机会话页一回合只剩「终端✓ / 思考」占位行，用户完全看不出执行了什么；提问行只剩红色「AskUserQuestion」连问题文本都没有。
- **根因**：`zcode-phone-server/public/index.html` 此前为避免"命令行夹杂"观感，用 `.tool.completed .tdesc { display:none }` 有意隐藏了完成态摘要（inputSummary 数据一直在，只是被藏）；且 `inputSummary` 不认识 AskUserQuestion 的 `questions[].question`，提问行 desc 为空。
- **修复**：完成态恢复摘要（压暗 var(--faint) + 省略号截断，完整输入仍在展开卡片）；删除 setToolStatus 里配套的"摘要补进详情体首行"补偿逻辑；`inputSummary` 增加 `questions[0].question` 兜底。
- **验证/部署注意**：server.mjs 对 `/` 每次请求都 `fs.readFileSync` index.html（约 :1700），改页面**无需重启**；页面经 /api/state 的构建指纹（md5 前 8 位）比对自动 reload，手机端下一次轮询即生效。

---

## 对话过程大量重复输出：正文"直播块 vs 落库副本"双路渲染无去重（2026-10-04）

- **现象**：回合进行中同一段回复正文出现两块、同步增长，直到回合结束才合并——用户看到"很多重复的输出"。
- **根因**：引擎（zcode.cjs）对同一回合**同时**发 `model.streaming`（token 直播）与 `part.upserted/part.delta`（部件落库）两类事件（引擎源码 grep 坐实）。页面把直播 token 画进 `__live-text` 累积块、把落库部件画成真实 partId 元素，两路都渲染。思考行早有"落库追平直播才交接"的去重（upserted 分支 + renderTail 长度比较），**正文 text 漏了同款处理**。
- **修复**：新增 `settleLiveText(m)`（落库文本总长追平直播块前只记数据不渲染副本，追平即移除直播块）；挂在 part.upserted/part.delta/renderTail 三个正文入口；`model.streaming` 增加 hasReal 守卫（真实部件已接管就不再重建直播块，思考/正文同款）；part.delta 的 reasoning `!pe` 分支补上与 upserted 同款的直播去重。
- **教训**：给"直播+落库"双通道页面加渲染路径时，两条通道必须同一时刻只渲染一份——新增部件类型（text/reasoning/tool）都要过一遍 settle 去重，漏一个就是"重复输出"类用户报告。

---

## 成果预览/下载"成片失败"根因与渲染层重做（2026-11，P0 commit 8ce86d4）

- **一次泄漏拖垮全部预览与下载**：`TunnelService.ensureUploadDir` 成功路径 `return dir`
  从不 `sftp.close()`。每上传一次泄漏一条 SSH 通道，远端 sshd `MaxSessions=10` 打满后
  **所有** SFTP 操作一起失败——预览报"路径不存在或无权限"、下载报"隧道可能未连接"。
  教训：任何 `await client.sftp()` 都必须有 `finally` 收尾，成功分支尤其容易漏。
- **`SftpFile.close()` 会抛，不能裸放 `finally`**：dartssh2 的 `close()` 是
  `await _close()`，通道已死时抛错**顶掉已成功的返回值**（表现为"点开偶尔失败、再点就好"），
  并跳过同块后续的 `sftp.close()` → 会话泄漏。统一走 `TunnelService.closeRemoteFile()`
  （best-effort，内部吞异常）。
- **唤醒卡死的 await 只有一个办法**：`SftpClient` 构造时**不注册** onDone/onError，
  `_waitReply` 无超时 → 链路半开时 await 永久悬挂，监督器重建隧道也救不回旧 await。
  唯一解法是 `SftpClient.close()`（`void`，会把 `_replyWaiters` 全部以
  `SftpAbortError` 完成）。因此所有活跃会话登记进 `_liveSftpClients`，`_teardown()`
  调 `abortLiveSftpSessions()`；其余路径一律用 `TimeoutException` 显式限时。
- **短读会留下"看起来成功"的洞**：fork 里 `onProgress` 累加的是**请求**长度
  （`bytessRecieved += chunkLength`）而非实收，服务端短读即进度虚高。续传偏移一律以
  `_chunks` 缓冲区实际字节数为准，完成时再校验 `downloadedBytes == totalBytes`，
  否则判"下载不完整（x/y 字节）"——**绝不相信库的进度计数**。
- **在途流必须用世代号作废**：`_generation` 递增 + 取消订阅 + `closeRemoteFile`，
  否则"暂停后继续"两条流写同一缓冲区、"取消后迟到的 completed"会存出只有尾包的坏文件。
- **0 字节与失败是两件事**：`readRemoteFileBytes` 原来失败返回 `null`，上层拿空内容
  继续 `saveFile` → 存出 0 字节文件还 toast"保存成功"。现在失败一律抛
  `RemoteReadException(kind: …)`，UI 按 `RemoteFailureKind` 给分类建议。
- **`?token=` 让后缀判定全线失效**：判定必须先过 `ArtifactRules.normalizeForSuffix`
  （剥 `?`/`#` 与结尾分隔符）。同一份后缀表在桥脚本里写了 4 遍且各自漂移，
  现在收敛为 `RESOURCE_EXT`/`TEXT_EXT` 两个 JS 常量（新增后缀两处同步：JS + Dart）。
- **渲染主路径改系统 WebView**（`lib/artifact_render_html.dart`）：
  `flutter_widget_from_html_core` 不执行脚本、外链 CSS/flex 无效，`flutter_markdown`
  无 `imageBuilder`/`onTapLink` 且不传 `baseUrl` → 报告里的截图全 404。`InAppWebView`
  `initialData` + `baseUrl` 指向隧道 origin 一次解决。原生渲染保留为"快速模式"
  （AppBar 的 html/手机图标可切）；代码类默认仍走原生（超长文件更稳）。
  原生侧补齐：横向滚动（此前长行被折行毁掉缩进）+ 行号 + `SelectionArea`
  （`flutter_highlight` 0.7.0 **没有** `selectable` 参数）。
- **CSV/JSON 必须单独分发**：`.csv` 走 MarkdownBody 会被挤成一段（Markdown 表格要 `|`），
  `.json` 缩进被吃掉。`ArtifactWebDocument.parseDelimited` 是手写解析器（引号内
  分隔符/换行、`""` 转义、CRLF、`,;\t|` 自动识别），有独立测试。
- **SVG 不能进"图片"分支**：`Image.memory` 不认 SVG，只会得到"图片解码失败"；
  `.svg` 走文本读取 + HTML 渲染。`isImageSuffix` 因此刻意不含 `.svg`。
- **PDF 保持下载**：Android WebView 不内嵌渲染 PDF，硬塞只得到空白页。
- **测试基线**：`flutter test` 现为 **112 例**（本轮新增 artifact_render_html 13 例、
  查看器布局回归 9 例、识别/下载 11 例）；`flutter analyze` 允许且仅有 third_party 的 10 条 info。
- **JS 桥是 analyze/test 的盲区**：注入脚本写在 Dart 字符串里，少个括号、分支不 `send`
  只在真机点击时暴露成"点了没反应"。`tool/check_bridges_js.mjs`（已入 CI）用假 DOM 跑
  点击分发，断言 `?token=` 后缀、file 分支带 dirs、fetch 失败带原因、含空格路径、
  `.so.N` 归资源、composer 区放行。**改桥脚本必须先过它**。
- **顶栏宽度是分配问题不是字号问题**：leading + 6 个图标把 360dp 吃光，标题只剩几像素
  （真机截图就是"文…"）。栏上只留 3 个高频动作 + ⋯ 菜单，标题显示文件名并支持
  长按复制「文件名 + 路径 + 链接」。查看器要报错就得知道自己在读哪条路——
  `ArtifactViewerScreen.path` 就是为此而加（此前它根本不知道自己读的是哪条路径）。
