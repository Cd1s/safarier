#!/usr/bin/env bash
# 发版后更新 Casks/safarier.rb：version + 两个架构的 sha256（读 Release 的 *.zip.sha256）。
# 缺 zip 或 sha256 资产时直接失败，不写半套数据。Release 发布后由 GitHub Actions
# 自动调用（.github/workflows/update-cask.yml），本地手动跑作为兜底。
#
# 用法：scripts/update-cask.sh [tag]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CASK="$ROOT/Casks/safarier.rb"
# 下载地址固定为实际发布仓库，不提供覆盖开关，避免校验值和 URL 对不上。
CASK_REPO="Cd1s/safarier"
TAG="${1:-}"

[ -f "$CASK" ] || { echo "找不到 Cask：$CASK" >&2; exit 1; }
command -v gh >/dev/null || { echo "需要 gh 命令行工具" >&2; exit 1; }
command -v curl >/dev/null || { echo "需要 curl 命令行工具" >&2; exit 1; }

if [ -z "$TAG" ]; then
  TAG="$(gh api "repos/$CASK_REPO/releases/latest" --jq .tag_name)"
fi
# Cask 的 version 不带前缀 v，tag 带；两者对应同一个发布。
VERSION="${TAG#v}"
[ -n "$VERSION" ] || { echo "无法确定版本号（tag：$TAG）" >&2; exit 1; }

assets="$(gh release view "$TAG" -R "$CASK_REPO" --json assets --jq '.assets[].name')"

# 从发布的 .sha256 文件读校验值，格式：<hash>  <filename>
sha256_of() {
  local arch="$1" file url hash
  file="Safarier-v${VERSION}-macOS-${arch}.zip"
  grep -qxF "$file" <<<"$assets" \
    || { echo "Release $TAG 里没有 $file" >&2; exit 1; }
  grep -qxF "$file.sha256" <<<"$assets" \
    || { echo "Release $TAG 里没有 $file.sha256，无法安全确定校验值" >&2; exit 1; }

  url="https://github.com/$CASK_REPO/releases/download/$TAG/$file.sha256"
  hash="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$url" | awk '{print $1; exit}')"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "$file.sha256 内容不是 SHA-256：$hash" >&2; exit 1; }
  echo "$hash"
}

ARM_SHA="$(sha256_of arm64)"
INTEL_SHA="$(sha256_of x86_64)"

# 原地替换：version 行 + 各 on_arm / on_intel 块里的第一条 sha256。
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ARM_SHA="$ARM_SHA" INTEL_SHA="$INTEL_SHA" VERSION="$VERSION" awk '
  /^  version / {
    print "  version \"" ENVIRON["VERSION"] "\""
    next
  }
  /^  on_arm do/ { in_arm = 1; in_intel = 0; print; next }
  /^  on_intel do/ { in_intel = 1; in_arm = 0; print; next }
  /^  end$/ { in_arm = 0; in_intel = 0; print; next }
  in_arm && /^    sha256 / && !arm_done {
    print "    sha256 \"" ENVIRON["ARM_SHA"] "\""
    arm_done = 1
    next
  }
  in_intel && /^    sha256 / && !intel_done {
    print "    sha256 \"" ENVIRON["INTEL_SHA"] "\""
    intel_done = 1
    next
  }
  { print }
' "$CASK" > "$tmp"

# 三处都必须真的被替换到，否则多半是 Cask 结构变了，不能静默写坏。
[ "$(grep -c "^  version \"$VERSION\"$" "$tmp")" -eq 1 ] || { echo "未能替换 version 行" >&2; exit 1; }
[ "$(grep -c "^    sha256 \"$ARM_SHA\"$" "$tmp")" -eq 1 ] || { echo "未能替换 arm64 的 sha256" >&2; exit 1; }
[ "$(grep -c "^    sha256 \"$INTEL_SHA\"$" "$tmp")" -eq 1 ] || { echo "未能替换 x86_64 的 sha256" >&2; exit 1; }

# mktemp 建出的文件是 0600，还原成源码文件的常规权限再替换。
chmod 644 "$tmp"
mv "$tmp" "$CASK"
trap - EXIT

echo "已更新 $CASK"
echo "  version  $VERSION"
echo "  arm64    $ARM_SHA"
echo "  x86_64   $INTEL_SHA"
echo
echo "接着：提交到仓库（上游 PR 会带上它），然后线上验证安装："
echo "  brew tap cd1s/safarier https://github.com/Cd1s/safarier"
echo "  brew install --cask cd1s/safarier/safarier"
