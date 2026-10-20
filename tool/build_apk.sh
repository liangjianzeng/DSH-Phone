#!/usr/bin/env bash
# DSH-Phone —— Linux(aarch64) 本机 APK 构建脚本
#
# 为什么需要这个脚本：在 aarch64 Linux 上编 Android APK 有三个必踩的坑，
# 全部与项目代码无关，靠记忆手工敲命令必然反复失败：
#
#   1) 本机 SDK 指向错误。flutter 会读 android/local.properties 的 sdk.dir；
#      若指向发行版自带的 /usr/lib/android-sdk（只有 platform-tools，没有
#      platforms/build-tools/ndk），Gradle 直接找不到 compileSdk。
#   2) Android 工具链没有 arm64 Linux 版。Google 的 repository2-3.xml 里
#      linux_arm64 出现 0 次——aapt2 只发 x86-64，本机 build-tools 里的
#      aapt2 同样是 x86-64。缺 amd64 运行库时报：
#        x86_64-binfmt-P: Could not open '/lib64/ld-linux-x86-64.so.2'
#        AAPT2 ... Daemon startup failed
#      解法：装 amd64 多架构运行库，让 qemu-user binfmt 透明执行官方 x64 二进制。
#   3) Flutter 不给 arm64 Linux 主机发 Android AOT 快照生成器。flutter_tools
#      的 _linuxBinaryDirs 只有 linux-x64（master 分支至今如此），但运行时按
#      hostArch 去找 android-*-release/linux-arm64/gen_snapshot → 缺失；
#      被复制进去的杂牌 x64 二进制又会撞上第 2 条。报：
#        Dart snapshot generator failed with exit code 255
#        Target android_aot_release_android-arm64 failed
#      解法：--fix-artifacts 从官方仓库取 linux-x64.zip 里的官方 gen_snapshot
#      放进 linux-arm64 目录（md5 与官方一致，不要用别处的二进制顶替）。
#   4) 补齐第 3 条后仍不够：qemu-user 跑 Dart 的 gen_snapshot 会自己崩
#      （qemu-x86_64: QEMU internal SIGSEGV {code=MAPERR, addr=0x20}，
#      表现为 AOT snapshotter exited with code -11）。qemu 8.2.2 与 10.0.0
#      一致，-cpu max / -singlestep / -R / 隐藏 /proc/self/maps 全无效；
#      根因是 guest 里 Dart 发出的尺寸下溢 mmap(NULL, -4096) 被 qemu 误判为
#      成功（真内核返回 ENOMEM），VM 随即进入坏状态。
#      解法：换 FEX（FEXCore，ARM 官方生态的 x86-64 on AArch64 模拟器）跑
#      gen_snapshot——官方 x64 gen_snapshot 在 FEX 下 21s 正常产出 app.so。
#      --fix-artifacts 会在 gen_snapshot 位置放一层薄包装：有 FEX 走 FEX，
#      没有 FEX 退回 binfmt(qemu)，只影响这一个文件，不动系统 binfmt。
#      NDK clang / aapt2 用 qemu 就够（缺 zlib1g:amd64 时 clang 会报
#      error while loading shared libraries: libz.so.1）。
#
# 用法：
#   tool/build_apk.sh                # release APK（默认只 AOT arm64，最快）
#   tool/build_apk.sh --debug        # debug APK（JIT，不需要 gen_snapshot）
#   tool/build_apk.sh --profile      # profile APK
#   tool/build_apk.sh --all-abi      # 不限定 target-platform（通用包，AOT 三次）
#   tool/build_apk.sh --analyze      # 只跑 flutter analyze
#   tool/build_apk.sh --check        # 只做环境自检
#   tool/build_apk.sh --fix-artifacts# 修复第 3 条（需联网，幂等）
#   tool/build_apk.sh --install      # 构建成功后 adb install -r（需已连手机）
#
# 环境变量可覆盖：FLUTTER_BIN / ANDROID_HOME / JAVA_HOME / FLUTTER_STORAGE_BASE_URL
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=release
TARGET_PLATFORM=android-arm64
RUN_ANALYZE=0
RUN_CHECK_ONLY=0
FIX_ARTIFACTS=0
RUN_INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --release) MODE=release ;;
    --debug) MODE=debug ;;
    --profile) MODE=profile ;;
    --all-abi) TARGET_PLATFORM= ;;
    --analyze) RUN_ANALYZE=1 ;;
    --check) RUN_CHECK_ONLY=1 ;;
    --fix-artifacts) FIX_ARTIFACTS=1 ;;
    --install) RUN_INSTALL=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$arg（--help 看用法）" >&2; exit 2 ;;
  esac
done

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }

# ---------------------------------------------------------------- 组件定位
# Flutter：优先显式指定，其次 PATH，再次常见的 ~/flutter、/opt/flutter
FLUTTER="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER" ]]; then
  for c in "$(command -v flutter || true)" "$HOME/flutter/bin/flutter" /opt/flutter/bin/flutter; do
    [[ -n "$c" && -x "$c" ]] && { FLUTTER="$c"; break; }
  done
fi
[[ -n "$FLUTTER" ]] || { echo "找不到 flutter（设 FLUTTER_BIN 或加入 PATH）" >&2; exit 1; }
# 不要用 flutter 的 symlink 目标反推 root，Cache.flutterRoot 认的是 bin/ 的上级
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER")/.." && pwd)"

# Android SDK：必须含 platforms + build-tools；发行版的 /usr/lib/android-sdk
# 常常只有 platform-tools，会让 Gradle 报找不到 compileSdk，故按能力挑而不是按存在挑
pick_sdk() {
  for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/android-sdk" \
           /opt/android-sdk /usr/lib/android-sdk; do
    [[ -n "$c" && -d "$c/platforms" && -d "$c/build-tools" ]] && { echo "$c"; return; }
  done
  echo ""
}
ANDROID_SDK="$(pick_sdk)"

# JDK 17：AGP 8.2.1 / Gradle 8.3 要求；flutter 若检测到 Android Studio 会强行
# 用它自带的 JBR(Java 21)，所以 android/gradle.properties 里另有 org.gradle.java.home
pick_jdk17() {
  local arch; arch="$(uname -m)"
  for c in "${JAVA_HOME:-}" \
           "/usr/lib/jvm/java-17-openjdk-${arch}" \
           /usr/lib/jvm/java-17-openjdk-arm64 \
           /usr/lib/jvm/temurin-17-jdk-${arch} \
           /usr/lib/jvm/openjdk-17; do
    [[ -n "$c" && -x "$c/bin/java" ]] && { echo "$c"; return; }
  done
  echo ""
}
JAVA17="$(pick_jdk17)"

STORAGE_BASE="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
ENGINE="$(tr -d '[:space:]' < "$FLUTTER_ROOT/bin/internal/engine.version" || true)"
ENG_DIR="$FLUTTER_ROOT/bin/cache/artifacts/engine"

# ---------------------------------------------------------------- 环境自检
echo "== 环境自检（$(uname -srm)）"
ok "flutter  $FLUTTER"
[[ -n "$ENGINE" ]] && ok "engine   ${ENGINE:0:12}…" || bad "读不到 bin/internal/engine.version"

ver="$("$FLUTTER" --version 2>&1 | head -1 || true)"
[[ "$ver" == Flutter* ]] && ok "$ver" || bad "flutter 无法执行：$ver"

if [[ -n "$ANDROID_SDK" ]]; then
  ok "Android SDK  $ANDROID_SDK"
  cs=$(sed -n 's/.*compileSdk *= *\([0-9]\+\).*/\1/p' "$PROJ_ROOT/android/app/build.gradle" | head -1)
  if [[ -z "$cs" ]]; then
    warn "build.gradle 里没解析出 compileSdk，跳过 platforms 检查"
  elif [[ -d "$ANDROID_SDK/platforms/android-$cs" ]]; then
    ok "platforms/android-$cs"
  else
    bad "缺 platforms/android-$cs：$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager \"platforms;android-$cs\""
  fi
  if ls "$ANDROID_SDK"/build-tools/*/aapt2 >/dev/null 2>&1; then
    ok "build-tools $(ls "$ANDROID_SDK/build-tools" | tr '\n' ' ')"
  else
    bad "缺 build-tools（含 aapt2）"
  fi
  # 本机 local.properties 常被写成 /usr/lib/android-sdk（那里没有 platforms），
  # IDE/工具还会反复改写它，所以直接自愈，只认这台机器的 SDK。
  lp="$PROJ_ROOT/android/local.properties"
  want="sdk.dir=$ANDROID_SDK"
  if [[ -f "$lp" ]]; then
    cur=$(sed -n 's/^sdk.dir=//p' "$lp" | head -1)
    if [[ "$cur" == "$ANDROID_SDK" ]]; then
      ok "local.properties sdk.dir 正确"
    elif grep -q '^sdk.dir=' "$lp"; then
      sed -i "s|^sdk.dir=.*|$want|" "$lp"
      warn "local.properties sdk.dir=$cur 已自动改为 $ANDROID_SDK"
    else
      printf '%s\n' "$want" >> "$lp"
      warn "local.properties 缺 sdk.dir，已补 $ANDROID_SDK"
    fi
    if ! grep -q '^flutter.sdk=' "$lp"; then
      printf 'flutter.sdk=%s\n' "$FLUTTER_ROOT" >> "$lp"
      warn "local.properties 缺 flutter.sdk，已补 $FLUTTER_ROOT"
    fi
  else
    printf '%s\nflutter.sdk=%s\n' "$want" "$FLUTTER_ROOT" > "$lp"
    warn "已生成 android/local.properties（sdk.dir + flutter.sdk）"
  fi
else
  bad "找不到含 platforms+build-tools 的 Android SDK（设 ANDROID_HOME）"
fi

if [[ -n "$JAVA17" ]]; then
  jv=$("$JAVA17/bin/java" -version 2>&1 | head -1)
  [[ "$jv" == *'"17'* ]] && ok "JDK 17  $JAVA17" || bad "$JAVA17 不是 JDK 17：$jv"
else
  bad "找不到 JDK 17（AGP 8.2.1 要求；apt install openjdk-17-jdk）"
fi

# aapt2 与 gen_snapshot 都是 x86-64，靠 qemu-user binfmt 执行，必须有 amd64 装载器
if [[ -e /lib64/ld-linux-x86-64.so.2 ]]; then
  ok "amd64 运行库就位（/lib64/ld-linux-x86-64.so.2）"
else
  bad "缺 amd64 运行库：aapt2/gen_snapshot 会报 x86_64-binfmt-P Could not open '/lib64/ld-linux-x86-64.so.2'
      sudo dpkg --add-architecture amd64
      # /etc/apt/sources.list.d/amd64-foreign.sources 指向 http://archive.ubuntu.com/ubuntu/
      sudo apt-get update && sudo apt-get install -y libc6:amd64 libstdc++6:amd64 zlib1g:amd64"
fi

# NDK 的 clang 也是 x86-64，缺 zlib1g:amd64 时 CMake 只留一句
# “C compiler identification is unknown”，很难查，这里直接跑一次
if [[ -n "$ANDROID_SDK" ]]; then
  ndk_bad=0; ndk_seen=0
  for ndkclang in "$ANDROID_SDK"/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/clang; do
    [[ -x "$ndkclang" ]] || continue
    ndk_seen=1
    ndkver=${ndkclang#*/ndk/}; ndkver=${ndkver%%/*}
    if out=$("$ndkclang" --version 2>&1 | head -1) && [[ "$out" == *"clang version"* ]]; then
      ok "NDK clang $ndkver 可执行"
    else
      bad "NDK clang $ndkver 跑不起来：$out
      多半缺 amd64 依赖库：sudo apt-get install -y zlib1g:amd64 libstdc++6:amd64"
      ndk_bad=1
    fi
  done
  [[ "$ndk_seen" == 1 ]] || warn "没找到 NDK（flutter.ndkVersion 需要）：sdkmanager \"ndk;26.3.11579264\""
fi

# AOT 快照生成器只能靠模拟跑，qemu 会崩，优先 FEX（见文件头第 4 条）
if command -v FEX >/dev/null 2>&1; then
  ok "FEX 可用（gen_snapshot 走 FEX）"
else
  warn "未装 FEX：gen_snapshot 会退回 qemu 并在 AOT 阶段崩溃
      sudo add-apt-repository -y ppa:fex-emu/fex && sudo apt-get install -y fex-emu-armv8.2"
fi

# gen_snapshot：flutter 按 hostArch 找 linux-arm64 目录，官方却只发 linux-x64
need_abis=(arm64)
[[ -z "$TARGET_PLATFORM" ]] && need_abis=(arm arm64 x64)
for abi in "${need_abis[@]}"; do
  gs="$ENG_DIR/android-$abi-release/linux-arm64/gen_snapshot"
  if [[ -x "$gs" ]] && "$gs" --version >/dev/null 2>&1; then
    ok "gen_snapshot(android-$abi) 可执行"
  elif [[ -f "$gs" ]]; then
    bad "gen_snapshot(android-$abi) 存在但跑不起来（缺 amd64 运行库，或不是官方产物）"
  else
    bad "gen_snapshot(android-$abi) 缺失：跑 tool/build_apk.sh --fix-artifacts"
  fi
done

if [[ -f "$PROJ_ROOT/android/key.properties" && -f "$PROJ_ROOT/android/key.jks" ]]; then
  ok "release 签名 key.properties + key.jks"
else
  warn "无 android/key.properties → release 回退 debug 签名（可安装自测，不能作正式发布包，也不能覆盖安装已装正式版）"
fi

[[ "$FAIL" == 0 ]] || { echo; echo "自检未通过，按上面 ✗ 的提示修好再构建。" >&2; exit 1; }
[[ "$RUN_CHECK_ONLY" == 1 ]] && { echo; echo "自检全部通过。"; exit 0; }

# ---------------------------------------------------------------- 产物修复
# 官方只发 android-<abi>-<mode>/linux-x64.zip，而 flutter 运行时按 hostArch 去
# linux-arm64/ 找，故把官方二进制放进 linux-arm64/（首次构建的 aarch64 机器必做）。
if [[ "$FIX_ARTIFACTS" == 1 ]]; then
  echo "== 补齐 flutter 缓存的 arm64 主机 gen_snapshot"
  [[ -n "$ENGINE" ]] || { echo "缺 engine.version，无法定位官方产物" >&2; exit 1; }
  for abi in arm arm64 x64; do
    for mode in release profile; do
      src="android-$abi-$mode"
      dst="$ENG_DIR/$src/linux-arm64"
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' RETURN
      url="$STORAGE_BASE/flutter_infra_release/flutter/$ENGINE/$src/linux-x64.zip"
      if ! curl -fsSL --retry 3 -o "$tmp/a.zip" "$url"; then
        echo "  下载失败：$url" >&2
        continue
      fi
      unzip -oq "$tmp/a.zip" -d "$tmp"
      [[ -f "$tmp/gen_snapshot" ]] || { echo "  $src 压缩包里没有 gen_snapshot" >&2; continue; }
      mkdir -p "$dst"
      # 真身放 .bin，gen_snapshot 位置换成一层薄包装：有 FEX 用 FEX（qemu 会
      # 在 AOT 阶段内部 SEGV），否则退回 binfmt。flutter_tools 只是 exec 这个
      # 路径，包装对它透明；且 isUpToDate 只检查 linux-x64 目录，不会被覆盖。
      install -m 755 "$tmp/gen_snapshot" "$dst/gen_snapshot.bin"
      [[ -f "$tmp/LICENSE.gen_snapshot.md" ]] && cp -f "$tmp/LICENSE.gen_snapshot.md" "$dst/" || true
      cat > "$dst/gen_snapshot" <<'WRAP'
#!/bin/sh
# aarch64 Linux 主机没有原生 Android AOT 快照生成器（官方只发 linux-x64）。
# qemu-user 跑它会自身崩溃，故优先交给 FEX；无 FEX 时退回 binfmt(qemu)。
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x /usr/bin/FEX ] || command -v FEX >/dev/null 2>&1; then
  exec FEX "$d/gen_snapshot.bin" "$@"
fi
exec "$d/gen_snapshot.bin" "$@"
WRAP
      chmod 755 "$dst/gen_snapshot"
      printf '  ✓ %-32s %s\n' "$src/linux-arm64" "$(md5sum "$dst/gen_snapshot.bin" | cut -c1-10)"
    done
  done
  echo
fi

# ---------------------------------------------------------------- 构建
cd "$PROJ_ROOT"
export ANDROID_HOME="$ANDROID_SDK" ANDROID_SDK_ROOT="$ANDROID_SDK" JAVA_HOME="$JAVA17"

echo "== flutter pub get"
"$FLUTTER" pub get

if [[ "$RUN_ANALYZE" == 1 ]]; then
  echo "== flutter analyze"
  exec "$FLUTTER" analyze --no-pub
fi

args=(build apk --release)
[[ "$MODE" == debug ]] && args=(build apk --debug)
[[ "$MODE" == profile ]] && args=(build apk --profile)
# 只 AOT 需要的 ABI：ndk.abiFilters 已限定打包 arm64，不写这行会白跑三次 AOT
[[ -n "$TARGET_PLATFORM" && "$MODE" != debug ]] && args+=(--target-platform="$TARGET_PLATFORM")

echo "== flutter ${args[*]}"
"$FLUTTER" "${args[@]}"

APK="build/app/outputs/flutter-apk/app-$MODE.apk"
[[ -f "$APK" ]] || { echo "构建结束但没找到 $APK" >&2; exit 1; }
echo
echo "产物：$PROJ_ROOT/$APK"
printf '体积：%s   sha256：%s\n' "$(du -h "$APK" | cut -f1)" "$(sha256sum "$APK" | cut -c1-16)…"
# 无 adb 环境的完整性粗验：关键 so 齐全 + 解压体积≈压缩后 2.4 倍（见 MEMORY.md）
if command -v jar >/dev/null 2>&1; then
  echo "原生库：$(jar tf "$APK" | grep -c '^lib/arm64-v8a/.*\.so$') 个 .so（arm64）"
  jar tf "$APK" | grep -E '^lib/arm64-v8a/lib(app|flutter|onnxruntime|sherpa)' | sed 's/^/    /' || true
fi

# release 签名验收：与 TongYi-Lite 共用正式证书（CN=TongYiLite），
# 指纹不符 = 打了临时/dev 签名，无法覆盖安装线上版（同 AGENTS 铁律）。
EXPECTED_FP="fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992"
APKSIGNER="$(ls "$ANDROID_SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
if [[ -n "$APKSIGNER" ]]; then
  dn="$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*certificate DN: //p' | head -1)"
  fp="$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr -d ':')"
  if [[ "$fp" == "$EXPECTED_FP" ]]; then
    ok "签名验收通过：$dn"
  elif [[ "$MODE" == release ]]; then
    bad "签名不符！$dn ($fp) ≠ CN=TongYiLite/$EXPECTED_FP —— 检查 android/key.jks"
    exit 1
  else
    warn "debug 包签名 $dn（非正式证书，覆盖安装线上版会被拒）"
  fi
fi

# ─────────────────────────────────────────────────────────────
# 交付规范（2026-10-20 用户定的固定要求）：每次打完包，回复里必须给出这个块。
# 由脚本自己打印，靠人记必然漏项——尤其"绝对地址"这一条：写成 build/... 这种
# 相对路径对需求方没有意义，他在另一台机器上按这个路径找不到文件。
echo
echo "━━━ 交付信息（请原样贴给需求方）━━━"
APK_ABS="$PROJ_ROOT/$APK"
APK_BYTES="$(stat -c %s "$APK" 2>/dev/null || wc -c <"$APK" | tr -d ' ')"
APK_MIB="$(awk -v b="$APK_BYTES" 'BEGIN{printf "%.2f", b/1048576}')"
echo "绝对地址：$APK_ABS"
echo "大　　小：$APK_BYTES bytes（≈${APK_MIB} MiB）"
if command -v sha256sum >/dev/null 2>&1; then
  echo "sha256　：$(sha256sum "$APK" | awk '{print $1}')"
fi
echo "构建时间：$(stat -c %y "$APK" 2>/dev/null | cut -d. -f1)"
[[ -n "${dn:-}" ]] && echo "签　　名：$dn"
if git -C "$PROJ_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
  HEAD_SHORT="$(git -C "$PROJ_ROOT" rev-parse --short HEAD)"
  DIRTY="$(git -C "$PROJ_ROOT" status --porcelain lib tool .github test pubspec.yaml third_party 2>/dev/null)"
  if [[ -z "$DIRTY" ]]; then
    echo "对应提交：$HEAD_SHORT（代码树干净，包=已提交树）"
  else
    echo "对应提交：$HEAD_SHORT ⚠ 有未提交的代码改动，包与提交不一致："
    echo "$DIRTY" | sed 's/^/           /'
  fi
fi
echo "提示　　：装机方比对 sha256；抽查新增文案用"
echo "           unzip -oq \"$APK_ABS\" lib/arm64-v8a/libapp.so -d /tmp/x"
echo "           然后 python3 判 '\"文案\"' in open('/tmp/x/lib/arm64-v8a/libapp.so','rb').read().decode('utf-16-le','ignore')"
echo "           （中文串在 Dart 快照里按 UTF-16 存，grep UTF-8 会误报缺失）"
if [[ "$MODE" == release ]]; then
  PUB_VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"
  echo "发版　　：这是 release 包，交付尚未完成——还差两件（规范见 BUILD.md）："
  echo "           1) 打 tag 触发 CI 上传 Releases：git tag v${PUB_VER} && git push origin v${PUB_VER}"
  echo "              （证书不入库：需先在仓库 Settings → Secrets 配 ANDROID_KEYSTORE_BASE64"
  echo "                与 ANDROID_KEY_PROPERTIES_BASE64，否则 job 按设计直接失败，"
  echo "                而不是静默发一个 debug 签名的包）"
  echo "           2) 回 README.md / README.html 核对「安装包」的最新正式版说明："
  echo "              版本号、大小、sha256、asset 名（app-release-v<版本>.apk）"
  echo "           有 API 令牌时可手动补传：gh release upload v${PUB_VER} \"$APK_ABS\" --clobber"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$RUN_INSTALL" == 1 ]]; then
  if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
    adb install -r "$APK"
  else
    echo "未检测到已连接的 adb 设备，跳过安装（adb-wifi.sh 可连手机）" >&2
  fi
fi
