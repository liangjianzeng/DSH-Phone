# DSH-Phone 构建说明

构建环境按平台拆分，请按所在平台选择对应文档：

- **Windows**：[`BUILD.windows.md`](BUILD.windows.md)
- **Linux / macOS / CI**：[`BUILD.linux.md`](BUILD.linux.md)

## 通用要点

- 提升版本号：编辑 `pubspec.yaml` 的 `version`
- release 签名：`android/key.properties`
- `dartssh2` 为本地 fork（`third_party/dartssh2`），经 `pubspec.yaml` 的 `dependency_overrides` 引入
- 产物：`build/app/outputs/flutter-apk/app-release.apk`；发版时上传 **GitHub Releases**（不再提交进 Git 仓库，`apk/` 已被 `.gitignore` 忽略）

## 版本记录

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
