#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_PATH="${SDK_PATH:-$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/LR1-CameraBridgeBuild.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT

# Accept the same SDK_PATH forms as build.sh: the Sony distribution folder
# containing SimpleCli.zip, or its already-extracted SimpleCli root.
if [[ -f "$SDK_PATH/SimpleCli.zip" ]]; then
    mkdir -p "$TEST_BUILD/sdk"
    unzip -q "$SDK_PATH/SimpleCli.zip" -d "$TEST_BUILD/sdk"
    SDK_ROOT="$TEST_BUILD/sdk"
elif [[ -f "$SDK_PATH/app/CRSDK/CameraRemote_SDK.h" ]]; then
    SDK_ROOT="$(cd "$SDK_PATH" && pwd)"
elif [[ -f "$SOURCE_DIR/build/sdk/app/CRSDK/CameraRemote_SDK.h" ]]; then
    SDK_ROOT="$SOURCE_DIR/build/sdk"
else
    echo "找不到 SDK。请将 SDK_PATH 设为含 SimpleCli.zip 的目录或已解包 SDK 根目录。" >&2
    exit 1
fi
if [[ ! -f "$SDK_ROOT/external/crsdk/libCr_Core.dylib" ]]; then
    echo "SDK 中缺少 external/crsdk/libCr_Core.dylib。" >&2
    exit 1
fi
xcrun clang++ -std=c++17 -fobjc-arc -UNDEBUG \
    -I "$SDK_ROOT/app/CRSDK" -I "$SOURCE_DIR/Sources" \
    "$SOURCE_DIR/Tests/CameraBridgeTests.mm" \
    -L "$SDK_ROOT/external/crsdk" -lCr_Core -framework Foundation \
    -Wl,-rpath,"$SDK_ROOT/external/crsdk" \
    -o "$TEST_BUILD/camera-bridge-tests"
"$TEST_BUILD/camera-bridge-tests"
