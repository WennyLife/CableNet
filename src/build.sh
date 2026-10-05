#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${1:-$SOURCE_DIR/build}"
mkdir -p "$BUILD_DIR/CableNet.app/Contents/MacOS" "$BUILD_DIR/CableNet.app/Contents/Resources" "$BUILD_DIR/CableNet.iconset"
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" -framework AppKit -framework SystemConfiguration -framework CoreWLAN -framework ServiceManagement "$SOURCE_DIR/CableNet.swift" -o "$BUILD_DIR/CableNet-$ARCH"
done
lipo -create "$BUILD_DIR/CableNet-arm64" "$BUILD_DIR/CableNet-x86_64" -output "$BUILD_DIR/CableNet.app/Contents/MacOS/CableNet"
cp "$SOURCE_DIR/Info.plist" "$BUILD_DIR/CableNet.app/Contents/Info.plist"
swift "$SOURCE_DIR/make-icon.swift" "$BUILD_DIR/CableNet.iconset"
iconutil -c icns "$BUILD_DIR/CableNet.iconset" -o "$BUILD_DIR/CableNet.app/Contents/Resources/CableNet.icns"
xattr -cr "$BUILD_DIR/CableNet.app"
codesign --force --sign "${CABLENET_SIGNING_IDENTITY:--}" --options runtime --timestamp=none "$BUILD_DIR/CableNet.app"
codesign --verify --deep --strict "$BUILD_DIR/CableNet.app"
echo "App criado em $BUILD_DIR/CableNet.app"
