#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_OUTPUT="${1:-${TMPDIR:-/tmp}/LR1Control-VideoTests}"
mkdir -p "$TEST_OUTPUT"
xcrun swiftc -parse-as-library \
  "$SOURCE_ROOT/Sources/LocalVideoRecorder.swift" \
  "$SOURCE_ROOT/Tests/LocalVideoRecorderTests.swift" \
  -o "$TEST_OUTPUT/local-video-tests"
"$TEST_OUTPUT/local-video-tests" "$TEST_OUTPUT"
