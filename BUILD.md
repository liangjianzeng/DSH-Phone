# DSH-Phone 构建说明

构建环境按平台拆分，请按所在平台选择对应文档：

- **Windows**：[`BUILD.windows.md`](BUILD.windows.md)
- **Linux / macOS / CI**：[`BUILD.linux.md`](BUILD.linux.md)

## 通用要点

- 提升版本号：编辑 `pubspec.yaml` 的 `version`
- release 签名：`android/key.properties`
- `dartssh2` 为本地 fork（`third_party/dartssh2`），经 `pubspec.yaml` 的 `dependency_overrides` 引入
- 产物：`build/app/outputs/flutter-apk/app-release.apk`；发版时上传 **GitHub Releases**（不再提交进 Git 仓库，`apk/` 已被 `.gitignore` 忽略）

## 打完包必须交付（规范，2026-10-20 定）

**APK 必须以"成果文件"的形式输出**（在会话里作为可点击的附件/成果卡片呈现），
**不能只把路径写进代码块**——需求方就是在端侧点这个成果把包装到手机上，代码块里的
路径他点不了、也下载不了（2026-10-20 用户明确要求）。绝对地址照样要给，但作为
**附属说明文字**（说明这来自哪个包、怎么比对），不要包在代码块里当唯一交付物。

**每次打完包，回复里必须给出下面这一整块**——这是固定要求，不用等对方来要：

| 项 | 要求 |
| --- | --- |
| **绝对地址** | 必须是绝对路径（`/home/.../build/app/outputs/flutter-apk/app-release.apk`）。写 `build/...` 这种相对路径对装机方没有意义，他在另一台机器上按这个路径找不到文件 |
| **字节数** | `ls -l` 的真实值，顺手换算 MiB（用来一眼判断"22MB 是不是被截断"，见 MEMORY 的体积拆解） |
| **sha256** | `sha256sum` 全量哈希，装机方比对用；别只给前几位 |
| **签名 + 构建时间** | `CN=TongYiLite…`（`tool/build_apk.sh` 的签名验收行）与产物时间 |
| **对应提交** | `git rev-parse --short HEAD`，并注明代码树是否干净——**包必须等于已提交树**，否则"装了不对"根本无从复现 |

`tool/build_apk.sh` 结尾会自动打印这块（含上面的脏树告警与抽查命令），**直接原样贴出**，不要手抄、不要把路径缩写成相对路径。贴这段之前，先把 APK 本身作为成果发出。

**发版（打 tag 那类）还多两件**，没做完不算交付完成：

1. **上传 GitHub Releases**：`git tag v<版本> && git push origin v<版本>` 触发 CI 的
   `build-apk` job 构建并上传（asset 名 `app-release-v<版本>.apk`，job 会校验签名指纹，
   与 `CN=TongYiLite` 不符直接失败）。证书不入库，需先在仓库 Settings → Secrets 配
   `ANDROID_KEYSTORE_BASE64` 与 `ANDROID_KEY_PROPERTIES_BASE64`（`base64 -w0 android/key.jks`
   与 `base64 -w0 android/key.properties` 的输出）；**没配就发不出去，这是有意的**——
   宁可失败也不要发一个静默回退 debug 签名的包，那种包不能覆盖安装线上正式版。
   现状（2026-10-20 实测，别再凭体积猜）：Releases 里唯一的包 `v0.2.0` **签名是正确的**
   （`apksigner` 读出 `CN=TongYiLite`、指纹与本机一致），173 MB 是**瘦身前打满四架构**
   （arm64-v7a/x86/x86_64）造成的，与签名方式无关；它是**手工上传**的——证书从未入库，
   而 `on: push` 当时只写了 `branches` 没写 `tags`，tag push 根本不触发 workflow，
   所以 v0.2.1/v0.2.2/v0.2.3 从未有过 CI 产出的 asset。两条发版路线并存：**手工发版**
   （打包机签好名 → 网页或 `gh release upload` 上传，历史沿用）与 **CI 发版**
   （配 Secrets 后重跑 job）。
2. **同步 README 的下载信息**：`README.md` 与 `README.html` 顶部「安装包」里的
   最新正式版说明（版本号、大小、sha256、asset 名）必须与新 Release 一致。
   `tool/build_apk.sh` 结尾的「交付信息」块会把这两件事直接列出来提醒。

装机方抽查"这个包到底含不含我这轮的改动"（中文串在 Dart 快照里按 **UTF-16** 存，直接 `grep` UTF-8 会误报缺失）：

```bash
unzip -oq <apk 绝对地址> lib/arm64-v8a/libapp.so -d /tmp/x
python3 -c "d=open('/tmp/x/lib/arm64-v8a/libapp.so','rb').read(); print('某条新文案' in d.decode('utf-16-le','ignore'))"
```

构建前请先确认工作区干净：`git status --porcelain lib tool .github test pubspec.yaml third_party` 为空。
同一条规范也记在 [`MEMORY.md`](MEMORY.md) 的「APK 打包与完整性核验」，两处若不一致以本文为准。

## 版本记录

- **v0.2.3（build 19）**：成果预览与下载重做（WebView 主渲染 + 图片预览 + 失败可自查）；下载字节数校验与 SSH 通道泄漏根因修复；本地端口占用自愈（自纠残骸 + 3090-3099 保留段）；CI 门禁复活（tool/ci_gate.sh 统一、117 例测试）；发版链路修复与交付规范。
- **v0.2.2（build 18）**：GitHub 仓库快捷访问（PAT 免登录）；ASR 全离主线程 + 热词真正生效；回前台自愈；APK 瘦身 92.8MB → 22.3MB。
- **v0.2.1（build 17）**：DSH ⇄ Zcode 双服务模式 + 语音/相机/天气体验与稳定性。
- **v0.2.0（build 16）**：语音输入重构为端侧流式 ASR（sherpa-onnx 流式 Zipformer）。
- **v0.1.8（build 14）**：Unsloth Studio 远程加载 + DSH Token 鉴权适配。
- **v0.1.7（build 13）**：真实月相天文模型 + 锁屏任务通知。
- **v0.1.6（build 12）**：图片直传（视觉工具入口）。
- **v0.1.5（build 11）**：主机监控完善（实例级开关 / GPU 温度 / 设置自动保存）。
- **v0.1.4（build 9/10）**：代码质量与隐患修复一轮。
- **v0.1.3**：成果原生查看器 + 资源下载 + 前台服务后台保活（build 6）。
- **v0.1.2**：实例别名 + 首次异常静默重连；修复 Windows 构建（AGP 8.2.1 / minSdk 23 / 禁用 jetifier）；构建说明拆分 Windows / Linux。
- **v0.1.1**：多连接实例（最多 3 路）+ 顶栏切换、可配置加载超时、本地 dartssh2 fork 吞吐优化、去隧道节流、断线重连退避上限、release 签名、自定义左侧中央缩放控件、VPN UDP QoS 超时友好提示。
- **v0.1.0**：首个发布版。

（各版本详细功能见 `README.md` 的版本记录。）
