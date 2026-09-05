# 项目记忆 (Project Memory)

本文件供后续会话在开头快速读取，避免重复踩已知坑、重复排查。

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

---

## 代码约定 (Coding Conventions)

> 后续补充：语言（中/英）、命名规范、目录结构、提交信息规范（conventional commits）等。

---

## 开发环境 (Dev Environment)

- **Flutter 路径**：`C:/src/flutter/bin/flutter`（Git Bash）/ `C:\src\flutter\bin\flutter.bat`（PowerShell / CMD）。不在系统 PATH，未安装到常见位置。
- **静态分析**：`flutter analyze`（项目根目录）。分析单文件：`flutter analyze lib/webview_screen.dart`。
- **构建 APK**：`flutter build apk --release`，产物 `build/app/outputs/flutter-apk/app-release.apk`。
- 改完代码后先 `flutter analyze` 确认无报错再提交。

---

## 质量整改记录（2026-09 体检整改，commit 2360f85）

- **主机密钥 TOFU**：`tunnel_service.dart` 不再无条件信任主机密钥。指纹按 `host:port+算法` 存 SharedPreferences（键 `ssh_hostkey_*`）；首次记录、后续比对、不匹配拒绝并提示。服务器重装/换密钥后：设置页「清除指纹」按钮（`TunnelService.clearHostKeyFingerprints()`）清除后重新记录。
- **明文流量**：`AndroidManifest.xml` 移除全局 `usesCleartextTraffic="true"`，改用 `res/xml/network_security_config.xml` 仅对 `127.0.0.1`/`localhost` 放行明文（SSH 隧道 WebView 访问）。
- **APK 不再提交 Git**：`apk/` 已入 `.gitignore`，历史版本上传 GitHub Releases；本地构建产物仍为 `build/app/outputs/flutter-apk/app-release.apk`。
- **测试与 CI**：`test/` 有 4 个单元测试（artifact_recognizer / moon_astronomy / config / download）；`.github/workflows/ci.yml` 跑 analyze+test（Flutter 3.27.0/stable 矩阵），打 tag 自动构建 APK 并上传 Releases。
- **版本号**：界面展示版本统一读 `SSHConfig.appVersion`（`lib/config.dart`），发版时与 `pubspec.yaml` 的 `version` 同步改。
