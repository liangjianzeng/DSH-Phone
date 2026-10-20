#!/usr/bin/env bash
# 把本机签好名的 release APK 挂到 GitHub Releases（并可选删掉旧 release）。
#
# 用法：
#   GITHUB_TOKEN=<token> ./tool/publish_release.sh v0.2.3 \
#       [--apk build/app/outputs/flutter-apk/app-release.apk] \
#       [--notes-file /tmp/rel_v023.md] [--delete v0.2.0]
#
# token 要求：fine-grained PAT，Repository permissions → **Contents: Read and write**
# （classic PAT 勾 repo 即可）。GitHub → Settings → Developer settings →
# Fine-grained personal access tokens，Repository access 只选 DSH-Phone 最省权限。
#
# 为什么必须 token：本机**到 github.com（网页主机）不通**——curl 直接超时，
# 只有 api.github.com / uploads.github.com 通。所以 gh 的设备码授权（要访问
# github.com/login/device）这条路是死的，只能拿 PAT 走 API；而仓库那把 SSH key
# 能 git push，却建不了 release、传不了 asset。
set -euo pipefail

REPO="liangjianzeng/DSH-Phone"
API="https://api.github.com/repos/$REPO"
EXPECTED_FP="fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992"
CT="application/vnd.android.package-archive"

TAG="${1:-}"; shift || true
APK="build/app/outputs/flutter-apk/app-release.apk"
NOTES_FILE=""
DELETE_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --delete) DELETE_TAG="$2"; shift 2 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "用法: GITHUB_TOKEN=<token> $0 <tag> [--apk 路径] [--notes-file 文件] [--delete 旧tag]"; exit 2; }
: "${GITHUB_TOKEN:?先设 GITHUB_TOKEN（fine-grained：Contents: Read and write）}"
[[ -f "$APK" ]] || { echo "✗ 找不到 APK：$APK"; exit 1; }

# ── 上 Releases 前自证：必须是正式证书签的包 ─────────────────────
APKSIGNER="$(ls "$HOME"/android-sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$APKSIGNER" ]]; then
  fp="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr -d ':' || true)"
  dn="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/.*certificate DN: //p' | head -1 || true)"
  [[ "$fp" == "$EXPECTED_FP" ]] || { echo "✗ 签名不符（$dn / $fp），拒绝上 Releases"; exit 1; }
  echo "✓ 签名验收：$dn"
else
  echo "⚠ 未找到 apksigner，跳过本地验签"
fi

SIZE="$(stat -c %s "$APK")"
SHA="$(sha256sum "$APK" | awk '{print $1}')"
ASSET="app-release-$TAG.apk"
[[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]] || NOTES_FILE=""
export REPO API GITHUB_TOKEN TAG APK ASSET SIZE SHA NOTES_FILE
export BODY="$TAG

**APK**：\`$ASSET\`（覆盖安装即可，数据保留）
**大小**：$SIZE bytes（$(awk -v b="$SIZE" 'BEGIN{printf "%.2f", b/1048576}') MiB）
**sha256**：\`$SHA\`
"

echo "① 建/取 release $TAG …"
code="$(python3 - <<'PY' | tr -d '[:space:]'
import json,os,subprocess
nf=os.environ["NOTES_FILE"]
body=open(nf,encoding="utf-8").read() if nf else os.environ["BODY"]
payload=json.dumps({"tag_name":os.environ["TAG"],"name":os.environ["TAG"],"body":body,
                    "draft":False,"prerelease":False},ensure_ascii=False)
print(subprocess.run(["curl","-sS","-o","/tmp/rel_pub.json","-w","%{http_code}","-X","POST",
  os.environ["API"]+"/releases","-H","Authorization: Bearer "+os.environ["GITHUB_TOKEN"],
  "-H","Accept: application/vnd.github+json","-d",payload],capture_output=True,text=True).stdout)
PY
)"
if [[ "$code" == "201" ]]; then
  id="$(python3 -c 'import json;print(json.load(open("/tmp/rel_pub.json"))["id"])')"
  echo "   已创建 release id=$id"
else
  msg="$(python3 -c 'import json;d=json.load(open("/tmp/rel_pub.json"));print(d.get("message") or "")' 2>/dev/null || true)"
  # 422 = tag 已有 release（走更新）；其余（401/403）都是权限问题，直接把 API
  # 原文吐出来——"Resource not accessible by integration" 就是 token 没有
  # Contents:write，硬撑着往下跑只会变成 KeyError: 'id'。
  if [[ "$code" != "422" ]]; then
    echo "✗ 创建 release 失败：HTTP $code ${msg:+（$msg）}"
    case "$msg" in
      *"not accessible by integration"*|*"Not Found"*)
        echo "  → token 权限不足。需要 fine-grained PAT：Repository permissions →"
        echo "    **Contents: Read and write**（设备码授权拿到的是 GitHub App 令牌，"
        echo "    没有 Contents:write，建不了 release）。" ;;
    esac
    exit 1
  fi
  echo "   release 已存在 → 查询 + PATCH 更新说明"
  curl -sS -o /tmp/rel_pub.json -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "$API/releases/tags/$TAG"
  id="$(python3 -c 'import json;print(json.load(open("/tmp/rel_pub.json"))["id"])')"
  RELEASE_ID="$id" python3 - <<'PY'
import json,os,subprocess
nf=os.environ["NOTES_FILE"]
body=open(nf,encoding="utf-8").read() if nf else os.environ["BODY"]
payload=json.dumps({"name":os.environ["TAG"],"body":body,"draft":False},ensure_ascii=False)
subprocess.run(["curl","-sS","-o","/dev/null","-X","PATCH",
  os.environ["API"]+"/releases/"+os.environ["RELEASE_ID"],
  "-H","Authorization: Bearer "+os.environ["GITHUB_TOKEN"],
  "-H","Accept: application/vnd.github+json","-d",payload])
PY
fi

echo "② 清理同名旧 asset（幂等重传）…"
curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/releases/$id/assets" -o /tmp/rel_assets.json
python3 - <<'PY'
import json,os,subprocess
for a in json.load(open("/tmp/rel_assets.json")):
    if a["name"]==os.environ["ASSET"]:
        subprocess.run(["curl","-sS","-o","/dev/null","-X","DELETE",
          os.environ["API"]+"/releases/assets/"+str(a["id"]),
          "-H","Authorization: Bearer "+os.environ["GITHUB_TOKEN"],
          "-H","Accept: application/vnd.github+json"])
PY

echo "③ 上传 $ASSET（$SIZE bytes）…"
curl -sS --fail-with-body -o /tmp/asset_pub.json \
  -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: $CT" \
  -X POST "$API/uploads/releases/$id/assets?name=$ASSET" --data-binary "@$APK" >/dev/null
url="$(python3 -c 'import json;print(json.load(open("/tmp/asset_pub.json"))["browser_download_url"])')"

echo "④ 验证公网直链…"
head_code="$(curl -sS -o /dev/null -w '%{http_code}' -L -I "$url")"
got="$(curl -sS -o /dev/null -w '%{size_download}' -L "$url")"
[[ "$head_code" == "200" ]] || { echo "✗ 直链不可达（HTTP $head_code）"; exit 1; }
[[ "$got" == "$SIZE" ]] || { echo "✗ 直链字节数不符：$got ≠ $SIZE"; exit 1; }
echo "   ✓ HTTP 200，$got bytes 与本地一致"

if [[ -n "$DELETE_TAG" ]]; then
  echo "⑤ 删除旧 release $DELETE_TAG（保留 git tag 与历史）…"
  curl -sS -o /tmp/rel_del.json -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "$API/releases/tags/$DELETE_TAG"
  if python3 -c 'import json,sys;d=json.load(open("/tmp/rel_del.json"));sys.exit(0 if "id" in d else 1)'; then
    old="$(python3 -c 'import json;print(json.load(open("/tmp/rel_del.json"))["id"])')"
    curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" "$API/releases/$old"
    echo "   ✓ 已删除 $DELETE_TAG 的 release"
  else
    echo "   （$DELETE_TAG 无对应 release，跳过）"
  fi
fi

echo
echo "✓ 完成。$TAG 直链可直接下载："
echo "  $url"
echo "  sha256 $SHA ｜ $SIZE bytes ｜ 签名 CN=TongYiLite"
echo "  README「安装包」那条直链即刻生效。"
