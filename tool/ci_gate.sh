#!/usr/bin/env bash
# 统一质量门禁：CI 与本地提交前跑**同一份**脚本，避免"本地一套标准、CI 另一套"。
#
#   tool/ci_gate.sh              # 全量（JS 桥 → 第三方 fork → analyze → test）
#   tool/ci_gate.sh --skip-test  # 跳过单元测试（快速自查）
#
# 设计约束（都是踩出来的）：
#   1) `flutter analyze` 默认把 info 也当致命（实测有一个 info 就 exit 1）。
#      Flutter 一升级就冒 deprecation info（新版 Radio→RadioGroup），代码没动
#      CI 也会全红——本仓库门禁曾红两周无人发现。故只卡 error/warning，
#      info 单独汇总展示，不静默丢弃。
#   2) 根 analyze 已排除 third_party/**（vendored 上游的 deprecation 不该拖死
#      主门禁），但 fork 里的**编译错误**必须查，否则只会在 flutter test 编译期
#      露头，表现为"某几个 test 文件 loading [E]"，看不出根因。
#   3) GitHub Actions 日志匿名访问是 403：失败原因必须落到 ::error:: 注解里，
#      不登录也能用 /check-runs/{id}/annotations 读到。
set -uo pipefail
cd "$(dirname "$0")/.."

SKIP_TEST=0
[[ "${1:-}" == "--skip-test" ]] && SKIP_TEST=1

SUMMARY="${GITHUB_STEP_SUMMARY:-}"   # 本地跑时为空 → 不写注解/摘要
fail=0

note() { printf '%s\n' "$*"; }

annotate() { # $1=log $2=grep 模式
  [[ -n "$SUMMARY" ]] || return 0
  grep -E "$2" "$1" 2>/dev/null | sed 's/%/%25/g' | head -40 |
    while IFS= read -r line; do printf '::error::%s\n' "$line"; done
  return 0
}

summary_block() { # $1=标题 $2=文件
  [[ -n "$SUMMARY" ]] || return 0
  {
    echo "### $1"
    echo '```'
    cat "$2"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
  return 0
}

run_gate() { # $1=名称 $2=日志 $3=注解模式 $4=命令（bash -c 形式）
  local name="$1" log="$2" pattern="$3" cmd="$4"
  note "━━━ $name ━━━"
  bash -c "$cmd" > "$log" 2>&1
  local code=$?
  tail -30 "$log"
  if (( code != 0 )); then
    annotate "$log" "$pattern"
    summary_block "$name 失败（exit $code）" "$log"
    note "✗ $name 失败（exit $code）"
    fail=1
  else
    note "✓ $name"
  fi
}

# 1) 注入式 JS 桥：脚本写在 Dart 字符串里，analyze/test 看不见其内部。
run_gate "JS 桥校验" /tmp/gate_js.log '✗|Error|error|失败' \
  'node tool/check_bridges_js.mjs'

# 2) vendored fork：只卡 error/warning（info 是上游 deprecation，交人工与同步时处理）。
#    （flutter_foreground_task fork 已退役回归官方包，仅剩 dartssh2。）
run_gate "第三方 fork 分析" /tmp/gate_fork.log 'error -|warning -' \
  'dart analyze third_party/dartssh2'

# 3) 主分析：info 不致命。
run_gate "静态分析" /tmp/gate_analyze.log ' • ' \
  'flutter analyze --no-pub --no-fatal-infos'

# 4) info 级单独汇总（不拦合并，但要看得见）。
if [[ -n "$SUMMARY" ]]; then
  flutter analyze --no-pub --no-fatal-infos > /tmp/gate_infos.log 2>&1 || true
  if grep -q "info •" /tmp/gate_infos.log; then
    {
      echo '### 提示级问题（不卡门禁，等 SDK 升级后统一处理）'
      echo '```'
      grep "info •" /tmp/gate_infos.log | head -60
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  else
    echo '### 提示级问题：无' >> "$GITHUB_STEP_SUMMARY"
  fi
fi

if (( SKIP_TEST == 0 )); then
  # 5) 单元测试。"loading xxx_test.dart [E]" 只是现象，真正原因在其后的 Error 行。
  run_gate "单元测试" /tmp/gate_test.log \
    '\[E\]|Expected:|Actual:|Which:|Error|error:|Couldn.t|Failed to|compilation failed' \
    'flutter test --no-pub --reporter expanded'
fi

# 6) 依赖解析清单：lock 实际随仓库提交（与下方历史注释相反——曾有一段
#    不提交的时期，2026-10 体检时确认早已改为提交），本地 pub get 若改了
#    lock 必须一并提交，否则 CI 与本地依赖面不一致；贴出解析结果省一轮猜测。
if [[ -n "$SUMMARY" ]]; then
  {
    echo '### 依赖解析结果（compact）'
    echo '```'
    flutter pub deps --style=compact 2>/dev/null | head -80
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

note ""
if (( fail == 0 )); then
  note "✓ 质量门禁全部通过"
else
  note "✗ 质量门禁失败（见上面的注解 / Job 摘要）"
fi
exit "$fail"
