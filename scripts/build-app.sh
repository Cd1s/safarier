#!/usr/bin/env bash
# 编出 Universal（arm64 + x86_64）release 二进制，组装 dist/Safarier.app 并做本机 ad-hoc 签名。
# Apple 芯片和 Intel 的 Mac 都能用。只在 Mac mini 上跑（需要 Xcode 工具链：多架构 swift build 和 lipo）。
# 环境变量：SAFARIER_VERSION 覆盖版本号（默认 1.2.3），SAFARIER_BUILD 覆盖构建号（默认 git 提交数），
#           SINGBOX_DIR 覆盖自带 sing-box 的目录（默认 .build/sing-box，由 scripts/build-singbox.sh 在编译机上编出来）。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="${SAFARIER_VERSION:-1.2.3}"
BUILD="${SAFARIER_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
TARGET_ARCH="${SAFARIER_ARCH:-universal}"
BUNDLE_ID="sh.safarier.app"
APP="${SAFARIER_APP_OUT:-$ROOT/dist/Safarier.app}"
SINGBOX_DIR="${SINGBOX_DIR:-$ROOT/.build/sing-box}"

ARCHS_EXPECTED="arm64 x86_64"

# lipo -archs 的输出同时有 arm64 和 x86_64。
is_universal() {
  local archs
  archs=" $(lipo -archs "$1" 2>/dev/null || true) "
  [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]]
}

# 编译机交回的是两个单架构切片（Linux 上没有 lipo），在这里合并成 Universal。
if ! { [ -f "$SINGBOX_DIR/sing-box" ] && is_universal "$SINGBOX_DIR/sing-box"; } \
   && [ -f "$SINGBOX_DIR/sing-box-arm64" ] && [ -f "$SINGBOX_DIR/sing-box-amd64" ]; then
  echo "==> 合并 sing-box 切片：lipo -create"
  lipo -create -output "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box-arm64" "$SINGBOX_DIR/sing-box-amd64"
  chmod 755 "$SINGBOX_DIR/sing-box"
fi
for file in sing-box LICENSE COPYING SOURCE; do
  if [ ! -f "$SINGBOX_DIR/$file" ]; then
    echo "缺少 $SINGBOX_DIR/$file。先在编译机上编自带的 sing-box：" >&2
    echo "  remote-build --fetch out/sing-box:.build -- scripts/build-singbox.sh" >&2
    exit 1
  fi
done
is_universal "$SINGBOX_DIR/sing-box" \
  || { echo "$SINGBOX_DIR/sing-box 不是 Universal（需要 $ARCHS_EXPECTED，实际：$(lipo -archs "$SINGBOX_DIR/sing-box" 2>/dev/null || echo 不是 Mach-O)）" >&2; exit 1; }
# VLESS Reality 和 fp 指纹要 uTLS；不带 with_utls 编的 sing-box 遇到这类节点会启动失败。
if ! "$SINGBOX_DIR/sing-box" version | grep -q 'with_utls'; then
  echo "警告：$SINGBOX_DIR/sing-box 没有编进 with_utls，VLESS Reality 节点会连不上" >&2
fi

echo "==> swift build -c release --arch arm64 --arch x86_64"
swift build -c release --arch arm64 --arch x86_64 --product Safarier
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Safarier"
is_universal "$BIN" || { echo "$BIN 不是 Universal：$(lipo -archs "$BIN")" >&2; exit 1; }

echo "==> 组装 $APP ($TARGET_ARCH)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/sing-box"
case "$TARGET_ARCH" in
  universal)
    cp "$BIN" "$APP/Contents/MacOS/Safarier"
    cp "$SINGBOX_DIR/sing-box" "$APP/Contents/Helpers/sing-box"
    ;;
  arm64|x86_64)
    lipo "$BIN" -thin "$TARGET_ARCH" -output "$APP/Contents/MacOS/Safarier"
    lipo "$SINGBOX_DIR/sing-box" -thin "$TARGET_ARCH" -output "$APP/Contents/Helpers/sing-box"
    ;;
  *)
    echo "未知 SAFARIER_ARCH=$TARGET_ARCH（支持 universal、arm64、x86_64）" >&2
    exit 1
    ;;
esac
chmod 755 "$APP/Contents/MacOS/Safarier" "$APP/Contents/Helpers/sing-box"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$SINGBOX_DIR/LICENSE" "$SINGBOX_DIR/COPYING" "$SINGBOX_DIR/SOURCE" "$APP/Contents/Resources/ThirdParty/sing-box/"

echo "==> 生成图标"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$ICON_WORK/icon.png"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$ICON_WORK/icon.png" --out "$ICONSET/icon_${spec#*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 界面文案是简体中文；开发区域设成 zh-Hans，系统菜单（关于、退出、编辑…）跟着用中文。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleDisplayName</key>
	<string>Safarier</string>
	<key>CFBundleExecutable</key>
	<string>Safarier</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Safarier</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSCameraUsageDescription</key>
	<string>网页请求使用摄像头时（例如视频会议），Safarier 会先询问你。</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>网页请求使用麦克风时（例如视频会议），Safarier 会先询问你。</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Safarier</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> ad-hoc 签名"
# 由内向外签：先签里面的 sing-box，再签整个 App（App 的签名把它封进去）。不用 --deep，否则会把 sing-box 重签掉。
codesign -s - --force --identifier sh.safarier.sing-box "$APP/Contents/Helpers/sing-box"
codesign -s - --force "$APP"
codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/Safarier" "$APP/Contents/Helpers/sing-box"; do
  if [ "$TARGET_ARCH" = "universal" ]; then
    is_universal "$binary" || { echo "$binary 不是 Universal：$(lipo -archs "$binary")" >&2; exit 1; }
  else
    [ "$(lipo -archs "$binary")" = "$TARGET_ARCH" ] || { echo "$binary 架构不是 $TARGET_ARCH：$(lipo -archs "$binary")" >&2; exit 1; }
  fi
  echo "    ${binary#"$APP/"}：$(lipo -archs "$binary")"
done

echo "==> 完成：${APP}（${VERSION} build ${BUILD}，arch：${TARGET_ARCH}）"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature)=' || true
