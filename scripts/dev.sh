#!/usr/bin/env bash
# SwiftBuild may record the deployment target as the SDK version, selecting legacy UI.
# Keep the two versions separate: macOS 14 minimum, the selected SDK for native styling.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_ARGS=(--sdk "$SDK_PATH"
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")

swift build "${BUILD_ARGS[@]}" --product Safarier
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Safarier"

# Fail before launching if a toolchain silently drops the SDK metadata again.
xcrun vtool -show-build "$BIN" | awk -v expected="$SDK_VERSION" '
  function normalized(version) { sub(/(\.0)+$/, "", version); return version }
  $1 == "minos" { minimum = normalized($2) }
  $1 == "sdk" { sdk = normalized($2) }
  END { exit !(minimum == "14" && sdk == normalized(expected)) }
' || { echo "SDK metadata mismatch; refusing to launch $BIN" >&2; exit 1; }

exec "$BIN" "$@"
