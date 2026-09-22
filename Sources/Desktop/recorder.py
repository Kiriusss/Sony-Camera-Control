"""Small MJPEG AVI muxer: keeps SDK preview JPEGs without a video codec dependency."""

from __future__ import annotations

from pathlib import Path
import struct


def _chunk(tag: bytes, data: bytes) -> bytes:
    return tag + struct.pack("<I", len(data)) + data + (b"\0" if len(data) & 1 else b"")


class PreviewRecorder:
    """Classic AVI, limited to 1 GiB; timing is mapped to a fixed 5 fps timeline."""

    MAX_BYTES = 1024 * 1024 * 1024

    def __init__(self, path: Path, width: int, height: int, timestamp: float, fps: int = 5):
        if width <= 0 or height <= 0 or width > 32767 or height > 32767 or fps <= 0:
            raise ValueError("预览画面尺寸或帧率无效。")
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.width, self.height, self.fps = width, height, fps
        self.started_at = timestamp
        self.frames = 0
        self._indices: list[tuple[int, int]] = []
        self._last_jpeg: bytes | None = None
        self._closed = False
        self._file = path.open("xb")
        self._file.write(self._header(0, 0))
        self._movi_start = self._file.tell() - 4

    def _header(self, frames: int, movi_size: int) -> bytes:
        main = struct.pack("<14I", round(1_000_000 / self.fps), 0, 0, 0x10, frames,
                           0, 1, 0, self.width, self.height, 0, 0, 0, 0)
        stream = struct.pack("<4s4sIHH8I4h", b"vids", b"MJPG", 0, 0, 0, 0,
                             1, self.fps, 0, frames, 0, 0xFFFFFFFF, 0,
                             0, 0, self.width, self.height)
        bitmap = struct.pack("<IiiHH4sIiiII", 40, self.width, self.height, 1, 24,
                             b"MJPG", self.width * self.height * 3, 0, 0, 0, 0)
        streams = _chunk(b"LIST", b"strl" + _chunk(b"strh", stream) + _chunk(b"strf", bitmap))
        headers = _chunk(b"LIST", b"hdrl" + _chunk(b"avih", main) + streams)
        return b"RIFF\0\0\0\0AVI " + headers + b"LIST" + struct.pack("<I", 4 + movi_size) + b"movi"

    def _write_frame(self, jpeg: bytes) -> None:
        # Leave room for idx1 so the file stays safely below the classic AVI size limit.
        if self._file.tell() + len(jpeg) + 8 + (self.frames + 1) * 16 > self.MAX_BYTES:
            raise RuntimeError("预览录像已达到 1 GiB，已结束并保存。请开始新的录像。")
        offset = self._file.tell() - self._movi_start
        self._file.write(_chunk(b"00dc", jpeg))
        self._indices.append((offset, len(jpeg)))
        self.frames += 1

    def append(self, jpeg: bytes, timestamp: float) -> None:
        if self._closed:
            raise RuntimeError("录像已结束。")
        target = max(0, int((timestamp - self.started_at) * self.fps + 1e-6))
        if target < self.frames:
            return
        # Never block the worker with an unbounded backlog after suspend or a stalled camera.
        if target - self.frames > 50:
            raise RuntimeError("取景中断超过 10 秒，已结束并保存录像。")
        while self.frames < target:
            self._write_frame(self._last_jpeg or jpeg)
        self._write_frame(jpeg)
        self._last_jpeg = jpeg

    def finish(self) -> Path:
        if self._closed:
            return self.path
        try:
            end_movi = self._file.tell()
            indices = b"".join(struct.pack("<4sIII", b"00dc", 0x10, offset, size)
                               for offset, size in self._indices)
            self._file.write(_chunk(b"idx1", indices))
            total = self._file.tell()
            self._file.seek(0)
            self._file.write(self._header(self.frames, end_movi - self._movi_start - 4))
            self._file.seek(4)
            self._file.write(struct.pack("<I", total - 8))
            self._file.flush()
        finally:
            self._file.close()
            self._closed = True
        return self.path
