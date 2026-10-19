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
# 5. 发版：上传 build/app/outputs/flutter-apk/app-release.apk 到 GitHub Releases
#    （历史版本不再提交进 Git，apk/ 已被 .gitignore 忽略）
```

## 关键构建配置（Linux 特有）

- **`android/gradle.properties`**：`org.gradle.java.home` 指向本机 **JDK 17**，例如 `/usr/lib/jvm/java-17-openjdk-arm64`（aarch64）。Linux 无 Android Studio 时 flutter 尊重 `JAVA_HOME`，也可通过 `JAVA_HOME` 设置。
- **`android/gradle.properties`**：`android.enableJetifier=false`（已启用 AndroidX）。
- **`android/app/build.gradle`**：`minSdkVersion = 23`（`flutter_secure_storage` 10.x 要求）。
- **`android/settings.gradle`**：AGP `8.2.1`。

> ⚠️ `org.gradle.java.home` 是机器特定路径，跨平台打包时各机需按本文件修改为对应 JDK 17 路径，不要直接提交本机路径。

## aarch64（ARM64）打包机专属

aarch64 Linux 上编 Android APK 有四个与项目代码无关的坑（x86-64 机器一条 `flutter build apk` 就完事）。
一条命令搞定：**`tool/build_apk.sh`**（先自检，再构建）。

```bash
# 一次性（root）：x86-64 原生工具（aapt2 / NDK clang）需要的 amd64 运行库
sudo dpkg --add-architecture amd64
# 另建 /etc/apt/sources.list.d/amd64-foreign.sources，URIs 指 http://archive.ubuntu.com/ubuntu/
# （ports.ubuntu.com 没有 amd64），Architectures: amd64，Components: main
sudo apt-get update
sudo apt-get install -y libc6:amd64 libstdc++6:amd64 zlib1g:amd64
# AOT 快照生成器只能靠模拟跑，而 qemu-user 会崩，改用 FEX
sudo add-apt-repository -y ppa:fex-emu/fex
sudo apt-get install -y fex-emu-armv8.2

# 一次性：补 Flutter 缺失的 arm64 主机 AOT 产物（官方只发 linux-x64 版）
tool/build_apk.sh --fix-artifacts

# 日常
tool/build_apk.sh                 # release APK（只 AOT arm64，约 6 分钟）
tool/build_apk.sh --debug         # debug 包（JIT，不需要 gen_snapshot）
tool/build_apk.sh --check         # 只自检，看哪一条环境没配好
```

| 症状 | 原因 | 处置 |
|------|------|------|
| `Could not open '/lib64/ld-linux-x86-64.so.2'`、`AAPT2 … Daemon startup failed` | Google 不发 linux_arm64 的 aapt2/build-tools（`repository2-3.xml` 里 0 处），全靠 qemu binfmt 跑 x86-64 二进制，缺 amd64 运行库 | 上面的 `apt-get install …:amd64` |
| Gradle 报找不到 compileSdk / `flutter doctor` 说 cmdline-tools 缺失 | `android/local.properties` 的 `sdk.dir` 指向发行版自带的 `/usr/lib/android-sdk`（只有 platform-tools） | 改成含 `platforms` + `build-tools` 的 SDK（本机 `/home/jianzengliang/android-sdk`） |
| `Dart snapshot generator failed with exit code 255` / AOT target 失败 | Flutter 不发 arm64 Linux 主机的 Android `gen_snapshot`（`flutter_tools` 的 `_linuxBinaryDirs` 只有 `linux-x64`，master 至今如此） | `tool/build_apk.sh --fix-artifacts` |
| `AOT snapshotter exited with code -11`、`qemu: QEMU internal SIGSEGV addr=0x20` | qemu-user 自身跑不了 Dart 的 gen_snapshot（8.2 与 10.0 表现一致，`-cpu`/`-singlestep`/`-R`/屏蔽 `/proc/self/maps` 均无效；guest 的尺寸下溢 `mmap` 被 qemu 误判成功） | 装 FEX；`--fix-artifacts` 生成的包装会自动走 FEX |
| CMake 只报 `The C compiler identification is unknown` | 缺 `zlib1g:amd64`，NDK 的 x86-64 clang 起不来 | `sudo apt-get install -y zlib1g:amd64` |

- 只构建 arm64：`flutter build apk --release --target-platform=android-arm64`（`ndk.abiFilters` 已限定 arm64，不写这个参数会白跑三次 AOT）。
- 本机没有 `android/key.properties` / `key.jks` 时，`build.gradle` 会**静默回退 debug 签名**：能安装自测，但不能覆盖安装已发布的正式版，也不要拿去发版。正式包仍走 CI（打 tag）或 x86-64 打包机。
- 更多排查细节（含每条结论的验证方式）见 `MEMORY.md` 的「Linux(aarch64) 打包机」。

## 版本记录

- **v0.1.2**：适配 Linux (aarch64) 构建环境（JDK 路径 / analyzer 排除 / minSdkVersion）。
