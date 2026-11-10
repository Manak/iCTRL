#!/usr/bin/env bash
# Builds the Tailscale side of the bridge as a static iOS library:
#   ClaudeBridge/build/ClaudeBridgeTS.xcframework  (ios-arm64, device only)
# Needs Go (brew install go) and Xcode. Run from anywhere.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../build"
MIN_IOS="16.0"

command -v go >/dev/null || { echo "error: Go is not installed (brew install go)" >&2; exit 1; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$HERE"
echo "==> go build (ios/arm64, c-archive)"
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
CC="$CLANG" \
CGO_CFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=$MIN_IOS" \
CGO_LDFLAGS="-isysroot $SDK -arch arm64 -miphoneos-version-min=$MIN_IOS" \
go build -buildmode=c-archive -trimpath -ldflags="-s -w" -o "$WORK/libClaudeBridgeTS.a" .

mkdir -p "$WORK/Headers"
mv "$WORK/libClaudeBridgeTS.h" "$WORK/Headers/ClaudeBridgeTS.h"

echo "==> xcframework"
rm -rf "$OUT/ClaudeBridgeTS.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/libClaudeBridgeTS.a" -headers "$WORK/Headers" \
  -output "$OUT/ClaudeBridgeTS.xcframework" >/dev/null

du -sh "$OUT/ClaudeBridgeTS.xcframework" | awk '{print "✅ " $2 " (" $1 ")"}'
