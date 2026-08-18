# DSH-Phone 构建说明

## 环境

- Flutter 不在 PATH，需全路径调用：`C:\dev-tools\flutter\bin\flutter.bat`
- release 签名：`android/key.properties`（storeFile / storePassword / keyAlias / keyPassword）
- `dartssh2` 为本地 fork：`third_party/dartssh2`，经 `pubspec.yaml` 的 `dependency_overrides` 引入

## 构建步骤

```powershell
# 提升版本号（编辑 pubspec.yaml 的 version）
# 拉依赖
& 'C:\dev-tools\flutter\bin\flutter.bat' pub get
# 静态分析
& 'C:\dev-tools\flutter\bin\flutter.bat' analyze lib
# 构建 release APK
& 'C:\dev-tools\flutter\bin\flutter.bat' build apk --release
# 产物
# build/app/outputs/flutter-apk/app-release.apk
# 拷贝到 apk/ 目录并命名
# Copy-Item build/app/outputs/flutter-apk/app-release.apk apk/DSH-Phone-v0.1.1.apk
```

## 版本记录

- **v0.1.1**：多连接实例（最多 3 路）+ 顶栏切换、可配置加载超时、本地 dartssh2 fork 吞吐优化、去隧道节流、断线重连退避上限、release 签名、自定义左侧中央缩放控件、VPN UDP QoS 超时友好提示。
- **v0.1.0**：首个发布版。
