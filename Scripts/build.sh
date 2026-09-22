#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$SOURCE_DIR/build}"
APP_PATH="${APP_PATH:-$(dirname "$SOURCE_DIR")/LR1 Control.app}"
SDK_PATH="${SDK_PATH:-$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac}"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p "$BUILD_DIR"
if [[ -f "$SDK_PATH/SimpleCli.zip" ]]; then
    mkdir -p "$BUILD_DIR/sdk"
    unzip -q -o "$SDK_PATH/SimpleCli.zip" -d "$BUILD_DIR/sdk"
    SDK_ROOT="$BUILD_DIR/sdk"
elif [[ -f "$SDK_PATH/app/CRSDK/CameraRemote_SDK.h" ]]; then
    SDK_ROOT="$SDK_PATH"
else
    echo "找不到 SDK。请将 SDK_PATH 设为含 SimpleCli.zip 的 SDK 文件夹。" >&2
    exit 1
fi
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
mkdir -p "$APP_PATH/Contents/MacOS" "$FRAMEWORKS" "$APP_PATH/Contents/Resources"
cp -R "$SDK_ROOT/external/crsdk/." "$FRAMEWORKS/"
cp "$SOURCE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "$SOURCE_DIR/使用说明.md" ]]; then
    cp "$SOURCE_DIR/使用说明.md" "$APP_PATH/Contents/Resources/使用说明.md"
fi
if [[ -d "$SOURCE_DIR/ThirdPartyLicenses" ]]; then
    cp -R "$SOURCE_DIR/ThirdPartyLicenses" "$APP_PATH/Contents/Resources/"
fi
if [[ -f "$SOURCE_DIR/THIRD_PARTY_NOTICES.md" ]]; then
    cp "$SOURCE_DIR/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/"
fi
xcrun clang++ -std=c++17 -fobjc-arc -O2 -arch "$ARCH" -mmacosx-version-min=13.0 \
    -I "$SDK_ROOT/app/CRSDK" -I "$SDK_ROOT/app" \
    -c "$SOURCE_DIR/Sources/CameraBridge.mm" -o "$BUILD_DIR/CameraBridge.o"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" \
    -import-objc-header "$SOURCE_DIR/Sources/CameraBridge.h" \
    "$SOURCE_DIR/Sources/CameraModel.swift" "$SOURCE_DIR/Sources/LocalVideoRecorder.swift" "$SOURCE_DIR/Sources/LR1ControlApp.swift" \
    "$BUILD_DIR/CameraBridge.o" -L "$FRAMEWORKS" -lCr_Core -lc++ \
    -framework SwiftUI -framework AppKit -framework Foundation -framework AVFoundation -framework ImageIO \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -o "$APP_PATH/Contents/MacOS/LR1Control"
if [[ -f "$SOURCE_DIR/Scripts/make-icon.swift" ]]; then
    xcrun swift "$SOURCE_DIR/Scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset"
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
while IFS= read -r -d '' library; do
    codesign --force --sign - "$library"
done < <(find "$FRAMEWORKS" -name '*.dylib' -print0)
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "已构建：$APP_PATH"
