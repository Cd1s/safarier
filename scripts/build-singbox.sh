#!/usr/bin/env bash
# 交叉编译 Safarier 自带的精简版 sing-box：darwin/arm64（Apple 芯片）和 darwin/amd64（Intel）两个切片，
# 由 build-app.sh 合并成 Universal 后打进 Safarier.app/Contents/Helpers。
# 在编译机上跑（不在 Mac 上编译），产物取回到 .build/sing-box/（sing-box-arm64、sing-box-amd64、LICENSE、COPYING、SOURCE；
# 有 lipo 时另有合并好的 Universal sing-box）：
#   remote-build --fetch out/sing-box:.build -- scripts/build-singbox.sh
# 环境变量：SINGBOX_VERSION（默认 1.14.4，和 SingboxConfigBuilder 实测过的版本一致），
#           SINGBOX_TAGS（默认 with_utls：VLESS Reality 和节点链接里的 fp 指纹要用 uTLS；设成空字符串只编核心——
#           socks 入站，vless / vmess / trojan / shadowsocks（含 SS2022）/ socks / anytls 出站，ws / http / grpc-lite 传输，TLS。
#           TUN、QUIC、WireGuard、Tailscale、Clash API 等可选功能都不编进来），
#           SINGBOX_ARCHS（默认 "arm64 amd64"）。
set -euo pipefail

VERSION="${SINGBOX_VERSION:-1.14.4}"
TAGS="${SINGBOX_TAGS-with_utls}"
ARCHS="${SINGBOX_ARCHS:-arm64 amd64}"
cd "$(dirname "$0")/.."
OUT="$PWD/out/sing-box"
SRC="$PWD/out/sing-box-src/$VERSION"
LDFLAGS="-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=$VERSION"

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/SagerNet/sing-box.git "$SRC"
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

rm -rf "$OUT"
mkdir -p "$OUT"
for arch in $ARCHS; do
  echo "==> darwin/$arch（tags: ${TAGS:-无}）"
  (
    cd "$SRC"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -tags "$TAGS" -ldflags "$LDFLAGS" -o "$OUT/sing-box-$arch" ./cmd/sing-box
  )
done

# 编译机通常是 Linux，没有 lipo：留两个切片，由 Mac 上的 build-app.sh 合并。
if command -v lipo >/dev/null 2>&1 && [ -f "$OUT/sing-box-arm64" ] && [ -f "$OUT/sing-box-amd64" ]; then
  lipo -create -output "$OUT/sing-box" "$OUT/sing-box-arm64" "$OUT/sing-box-amd64"
  echo "==> 已合并 Universal：$(lipo -archs "$OUT/sing-box")"
fi

cp "$SRC/LICENSE" "$OUT/LICENSE"
# 上游 LICENSE 只是版权声明；GPL 要求随程序附上许可证全文。
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o "$OUT/COPYING"
grep -q 'GNU GENERAL PUBLIC LICENSE' "$OUT/COPYING"
{
  echo "sing-box $VERSION，GPL-3.0-or-later（版权声明见 LICENSE，许可证全文见 COPYING），未修改源码。"
  echo "源码：https://github.com/SagerNet/sing-box/tree/v$VERSION（commit $(git -C "$SRC" rev-parse HEAD)）"
  echo "工具链：$(go version)；build tags：${TAGS:-无}；CGO_ENABLED=0"
  echo "Safarier.app 里的 sing-box 是下面各切片用 lipo -create 合并的 Universal 文件："
  for arch in $ARCHS; do
    echo "  darwin/$arch：CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -tags \"$TAGS\" -ldflags \"$LDFLAGS\" ./cmd/sing-box"
    echo "    sha256 $(sha256 "$OUT/sing-box-$arch")"
  done
} > "$OUT/SOURCE"
ls -la "$OUT"
