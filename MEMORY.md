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
