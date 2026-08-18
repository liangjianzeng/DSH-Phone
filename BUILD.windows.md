# DSH-Phone Windows 构建说明

> Linux / macOS / CI 构建见 [`BUILD.linux.md`](BUILD.linux.md)。

## 环境

- **系统**：Windows + Android Studio（可选，见"常见问题"）
- **Flutter**：不在 PATH，需全路径调用：`C:\dev-tools\flutter\bin\flutter.bat`
- **JDK**：必须使用 **JDK 17**（AGP 8.2 / Gradle 8.3 要求）
- **release 签名**：`android/key.properties`（storeFile / storePassword / keyAlias / keyPassword）
- `dartssh2` 为本地 fork：`third_party/dartssh2`，经 `pubspec.yaml` 的 `dependency_overrides` 引入

## 构建步骤

```powershell
# 1. 提升版本号（编辑 pubspec.yaml 的 version）
# 2. 拉依赖
& 'C:\dev-tools\flutter\bin\flutter.bat' pub get
# 3. 静态分析
& 'C:\dev-tools\flutter\bin\flutter.bat' analyze lib
# 4. 构建 release APK
& 'C:\dev-tools\flutter\bin\flutter.bat' build apk --release
# 5. 拷贝产物
Copy-Item build/app/outputs/flutter-apk/app-release.apk apk/DSH-Phone-v0.1.2.apk
```

## 关键构建配置（Windows 特有）

- **`android/gradle.properties`**：`org.gradle.java.home` 必须指向本机 **JDK 17**（当前为 `C:\\dev-tools\\jdk17.0.20_8`），否则会误用 Android Studio 的 JBR（Java 21）导致构建失败。
- **`android/gradle.properties`**：`android.enableJetifier=false`（已启用 AndroidX，jetifier 无法转换 Java 21 编译的依赖）。
- **`android/app/build.gradle`**：`minSdkVersion = 23`（`flutter_secure_storage` 10.x 要求）。
- **`android/settings.gradle`**：AGP `8.2.1`（支持 SDK 36，规避 AGP<8.2.1 + Java 21 已知 bug）。

## 常见问题

- **flutter 强制用 Android Studio 的 JBR（Java 21）**：flutter 检测到 Android Studio 时优先用其自带 JDK，`JAVA_HOME` 无效。必须通过 `org.gradle.java.home` 显式指向本机 JDK 17。
- **`Unsupported class file major version 65`（Jetifier）**：bcprov-jdk18on 等依赖为 Java 21 编译，jetifier 无法转换，需 `android.enableJetifier=false`。
- **minSdk 冲突**：`flutter_secure_storage` 要求 minSdk 23，勿改回 `flutter.minSdkVersion`（21）。

## 版本记录

- **v0.1.2**：修复 Windows 构建（AGP 8.2.1 / minSdk 23 / 禁用 jetifier）。
