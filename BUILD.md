# DSH-Phone 构建说明

构建环境按平台拆分，请按所在平台选择对应文档：

- **Windows**：[`BUILD.windows.md`](BUILD.windows.md)
- **Linux / macOS / CI**：[`BUILD.linux.md`](BUILD.linux.md)

## 通用要点

- 提升版本号：编辑 `pubspec.yaml` 的 `version`
- release 签名：`android/key.properties`
- `dartssh2` 为本地 fork（`third_party/dartssh2`），经 `pubspec.yaml` 的 `dependency_overrides` 引入
- 产物：`build/app/outputs/flutter-apk/app-release.apk`，拷贝到 `apk/` 并命名

## 版本记录

- **v0.1.2**：实例别名 + 首次异常静默重连；修复 Windows 构建（AGP 8.2.1 / minSdk 23 / 禁用 jetifier）；构建说明拆分 Windows / Linux。
- **v0.1.1**：多连接实例（最多 3 路）+ 顶栏切换、可配置加载超时、本地 dartssh2 fork 吞吐优化、去隧道节流、断线重连退避上限、release 签名、自定义左侧中央缩放控件、VPN UDP QoS 超时友好提示。
- **v0.1.0**：首个发布版。
