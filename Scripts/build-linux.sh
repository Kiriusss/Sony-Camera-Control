#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Debian 12/13: apt install build-essential cmake ninja-build python3-venv libpython3-dev
# libudev-dev libxml2 libglib2.0-0 libgl1 libegl1 libopengl0 libxcb-cursor0 libxkbcommon-x11-0
python3 -m venv "$ROOT/build/venv-linux"
if [[ " $* " == *" --native-only "* ]]; then
    exec "$ROOT/build/venv-linux/bin/python" Scripts/build-desktop.py "$@"
fi
python3 -c 'import platform,sys; sys.exit("ARM64 Qt 6.8.3 requires glibc >= 2.39 (use Debian 13 or newer).") if platform.machine() in ("aarch64", "arm64") and tuple(map(int, platform.libc_ver()[1].split("."))) < (2,39) else None'
"$ROOT/build/venv-linux/bin/python" -m pip install -r requirements-desktop.txt
exec "$ROOT/build/venv-linux/bin/python" Scripts/build-desktop.py "$@"
