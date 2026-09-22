"""Serialized ctypes access to the Sony camera bridge."""

from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import sys


def bridge_path() -> Path:
    override = os.environ.get("SONY_CAMERA_BRIDGE")
    if override:
        return Path(override).expanduser().resolve()
    filename = "camera_bridge.dll" if sys.platform == "win32" else "libcamera_bridge.so"
    bundle = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    candidates = [bundle / "native" / filename, Path(sys.executable).parent / "native" / filename]
    source_root = Path(__file__).resolve().parents[2]
    candidates += [source_root / "build" / "native" / filename,
                   source_root / "build" / "native" / "Release" / filename,
                   source_root / "build" / "stage-windows" / "native" / filename,
                   source_root / "build" / "stage-linux" / "native" / filename]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"找不到相机服务 {filename}。请使用完整发行包，或设置 SONY_CAMERA_BRIDGE。")


class CameraTransport:
    """Create and use only on the SDK worker thread. All buffers belong to the bridge."""

    def __init__(self) -> None:
        path = bridge_path()
        self._dll_directories = []
        if os.name == "nt":
            for directory in (path.parent, path.parent / "CrAdapter"):
                if directory.is_dir():
                    self._dll_directories.append(os.add_dll_directory(str(directory)))
        self._library = ctypes.CDLL(str(path))
        self._library.lr1_request.argtypes = [ctypes.c_char_p]
        self._library.lr1_request.restype = ctypes.c_void_p
        self._library.lr1_copy_live_view.argtypes = [ctypes.POINTER(ctypes.c_int)]
        self._library.lr1_copy_live_view.restype = ctypes.c_void_p
        self._library.lr1_free.argtypes = [ctypes.c_void_p]
        self._library.lr1_free.restype = None

    def request(self, payload: dict) -> dict:
        pointer = self._library.lr1_request(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        if not pointer:
            raise RuntimeError("相机服务未返回状态。")
        try:
            response = json.loads(ctypes.string_at(pointer).decode("utf-8"))
            if not isinstance(response, dict):
                raise RuntimeError("相机服务返回了无效状态。")
            return response
        finally:
            self._library.lr1_free(pointer)

    def live_view(self) -> bytes | None:
        length = ctypes.c_int()
        pointer = self._library.lr1_copy_live_view(ctypes.byref(length))
        if not pointer:
            return None
        try:
            if not 0 < length.value <= 64 * 1024 * 1024:
                raise RuntimeError("取景画面长度无效。")
            return ctypes.string_at(pointer, length.value)
        finally:
            self._library.lr1_free(pointer)
