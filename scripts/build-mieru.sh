#!/usr/bin/env bash
# 准备官方未修改的 Mieru macOS 辅助程序；校验发布的 SHA-256，保留两个架构及 GPL 源码说明。
# MIERU_VERSION 默认 3.39.0，MIERU_DIR 默认 .build/mieru。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${MIERU_VERSION:-3.39.0}"
OUT="${MIERU_DIR:-$PWD/.build/mieru}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

for arch in arm64 amd64; do
  asset="mieru_${VERSION}_macos_${arch}.tar.gz"
  url="https://github.com/enfein/mieru/releases/download/v${VERSION}/${asset}"
  curl --fail --location --retry 3 "$url" -o "$WORK/$asset"
  curl --fail --location --retry 3 "$url.sha256.txt" -o "$WORK/$asset.sha256.txt"
  expected="$(awk '{print $1; exit}' "$WORK/$asset.sha256.txt")"
  [ "$(sha256 "$WORK/$asset")" = "$expected" ] || { echo "Mieru $arch SHA-256 校验失败" >&2; exit 1; }
  mkdir -p "$WORK/$arch"
  tar -xzf "$WORK/$asset" -C "$WORK/$arch" mieru
  cp "$WORK/$arch/mieru" "$OUT/mieru-$arch"
  chmod 755 "$OUT/mieru-$arch"
done
curl --fail --location --retry 3 "https://raw.githubusercontent.com/enfein/mieru/v${VERSION}/LICENSE" -o "$OUT/LICENSE"
grep -q 'GNU GENERAL PUBLIC LICENSE' "$OUT/LICENSE"
{
  echo "Mieru ${VERSION}, GPL-3.0-or-later, unmodified official release binaries."
  echo "Source: https://github.com/enfein/mieru/tree/v${VERSION}"
  echo "Source archive: https://github.com/enfein/mieru/archive/refs/tags/v${VERSION}.tar.gz"
  echo "Build from source: CGO_ENABLED=0 GOOS=darwin GOARCH=<arm64|amd64> go build ./cmd/mieru"
  for arch in arm64 amd64; do
    echo "darwin/$arch binary SHA-256: $(sha256 "$OUT/mieru-$arch")"
  done
} > "$OUT/SOURCE"
if command -v lipo >/dev/null 2>&1; then
  lipo -create -output "$OUT/mieru" "$OUT/mieru-arm64" "$OUT/mieru-amd64"
  chmod 755 "$OUT/mieru"
fi
