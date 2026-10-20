#!/usr/bin/env bash
# 把本机签好名的 release APK 挂到 GitHub Release，并把直链写回 README。
#
# 用法：
#   GITHUB_TOKEN=<token> ./tool/publish_release.sh v0.2.3
#
# token 要求：fine-grained PAT，Repository permissions → **Contents: Read and write**
# （classic PAT 则勾 repo 全量）。生成位置：GitHub → Settings → Developer settings
# → Fine-grained personal access tokens，Repository access 选 DSH-Phone 即可。
#
# 为什么非要 token：Releases 只能走 HTTPS API。仓库用的那把 SSH key
# （~/.ssh/id_ed25519_github）能 git push，但**建不了 release、传不了 asset**，
# 用 SSH 推 tag 也不会自动产生 asset（发版 job 需要证书 Secrets，另一条路）。
set -euo pipefail

REPO="liangjianzeng/DSH-Phone"
API="https://api.github.com/repos/$REPO"
TAG="${1:-}"
APK="${2:-build/app/outputs/flutter-apk/app-release.apk}"
# 与 tool/build_apk.sh 的 EXPECTED_FP 同源：只允许正式证书上 Releases。
EXPECTED_FP="fbbe1b6cf879ab941a65cdd7a7a8dd6f5a6bb640412de38c43cb894f08886992"
CT="application/vnd.android.package-archive"

[[ -n "$TAG" ]] || { echo "用法: GITHUB_TOKEN=<token> $0 <tag> [apk 路径]"; exit 2; }
: "${GITHUB_TOKEN:?先设 GITHUB_TOKEN（fine-grained：Contents: Read and write）}"
[[ -f "$APK" ]] || { echo "✗ 找不到 APK：$APK"; exit 1; }

# ── 上传前自证：必须是正式证书签的包 ──────────────────────────────
APKSIGNER="$(ls "$HOME"/android-sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$APKSIGNER" ]]; then
  fp="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/.*SHA-256 digest: //p' | head -1 | tr -d ':' || true)"
  dn="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/.*certificate DN: //p' | head -1 || true)"
  [[ "$fp" == "$EXPECTED_FP" ]] || { echo "✗ 签名不符（$dn / $fp），拒绝上 Releases"; exit 1; }
  echo "✓ 签名验收：$dn"
else
  echo "⚠ 没找到 apksigner，跳过本地验签（CI 侧仍有指纹门禁）"
fi

SIZE="$(stat -c %s "$APK")"
SHA="$(sha256sum "$APK" | awk '{print $1}')"
ASSET="app-release-$TAG.apk"
BODY="DSH-Phone $TAG

| 项 | 值 |
| --- | --- |
| 文件 | \`$ASSET\` |
| 大小 | $SIZE bytes（$(awk -v b="$SIZE" 'BEGIN{printf "%.2f", b/1048576}') MiB） |
| sha256 | \`$SHA\` |
| 签名 | \`CN=TongYiLite\` |
"

auth=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

echo "① 建/取 release $TAG …"
code="$(curl -sS -o /tmp/rel_publish.json -w '%{http_code}' "${auth[@]}" -X POST "$API/releases" \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"body":sys.argv[2],"draft":False,"prerelease":False},ensure_ascii=False))' "$TAG" "$BODY")")"
if [[ "$code" == "201" ]]; then
  id="$(python3 -c 'import json;print(json.load(open("/tmp/rel_publish.json"))["id"])')"
else
  echo "   （已存在或创建返回 $code，改为查现有 release）"
  curl -sS -o /tmp/rel_publish.json "${auth[@]}" "$API/releases/tags/$TAG"
  id="$(python3 -c 'import json;print(json.load(open("/tmp/rel_publish.json"))["id"])')"
  curl -sS -o /dev/null "${auth[@]}" -X PATCH "$API/releases/$id" \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"body":sys.argv[2],"draft":False},ensure_ascii=False))' "$TAG" "$BODY")"
fi

echo "② 清理同名旧 asset（幂等重传）…"
for aid in $(curl -sS "${auth[@]}" "$API/releases/$id/assets" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    if a["name"]==sys.argv[1]: print(a["id"])' "$ASSET"); do
  curl -sS -o /dev/null "${auth[@]}" -X DELETE "$API/releases/assets/$aid"
done

echo "③ 上传 $ASSET（$SIZE bytes）…"
curl -sS --fail-with-body -o /tmp/asset_publish.json "${auth[@]}" -H "Content-Type: $CT" \
  -X POST "$API/uploads/releases/$id/assets?name=$ASSET" --data-binary "@$APK" >/dev/null
url="$(python3 -c 'import json;print(json.load(open("/tmp/asset_publish.json"))["browser_download_url"])')"

echo "④ 公网直链可达性验证…"
head_code="$(curl -sS -o /dev/null -w '%{http_code}' -L -I "$url")"
remote_len="$(curl -sS -o /dev/null -w '%{size_download}' -L "$url")"
[[ "$head_code" == "200" ]] || { echo "✗ 直链不可达（HTTP $head_code）"; exit 1; }
[[ "$remote_len" == "$SIZE" ]] || { echo "✗ 直链字节数不符：$remote_len ≠ $SIZE"; exit 1; }

echo
echo "✓ 已挂上 Releases，直链可直接下载（HTTP 200，$remote_len bytes 与本地一致）"
echo "  $url"
echo "  sha256 $SHA"
