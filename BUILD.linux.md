# DSH-Phone Linux 构建说明

> Windows 构建见 [`BUILD.windows.md`](BUILD.windows.md)。

## 环境

- **系统**：Linux（含 aarch64 / arm64，如树莓派、ARM 云主机）
- **Flutter**：需先安装，并确保 `flutter` 在 PATH 或配置全路径
- **JDK**：必须使用 **JDK 17**（AGP 8.2 / Gradle 8.3 要求），推荐 `openjdk-17-jdk`
- **release 签名**：`android/key.properties`（storeFile / storePassword / keyAlias / keyPassword）
- `dartssh2` 为本地 fork：`third_party/dartssh2`，经 `pubspec.yaml` 的 `dependency_overrides` 引入

## 构建步骤

```bash
# 1. 提升版本号（编辑 pubspec.yaml 的 version）
# 2. 拉依赖
flutter pub get
# 3. 静态分析
flutter analyze lib
# 4. 构建 release APK
flutter build apk --release
# 5. 拷贝产物
cp build/app/outputs/flutter-apk/app-release.apk apk/DSH-Phone-v0.1.2.apk
```

## 关键构建配置（Linux 特有）

- **`android/gradle.properties`**：`org.gradle.java.home` 指向本机 **JDK 17**，例如 `/usr/lib/jvm/java-17-openjdk-arm64`（aarch64）。Linux 无 Android Studio 时 flutter 尊重 `JAVA_HOME`，也可通过 `JAVA_HOME` 设置。
- **`android/gradle.properties`**：`android.enableJetifier=false`（已启用 AndroidX）。
- **`android/app/build.gradle`**：`minSdkVersion = 23`（`flutter_secure_storage` 10.x 要求）。
- **`android/settings.gradle`**：AGP `8.2.1`。

> ⚠️ `org.gradle.java.home` 是机器特定路径，跨平台打包时各机需按本文件修改为对应 JDK 17 路径，不要直接提交本机路径。

## 版本记录

- **v0.1.2**：适配 Linux (aarch64) 构建环境（JDK 路径 / analyzer 排除 / minSdkVersion）。
