import struct
import tempfile
from pathlib import Path
import unittest

from recorder import PreviewRecorder


class PreviewRecorderTests(unittest.TestCase):
    def test_frame_index_and_duration_preserve_gaps(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.avi"
            recorder = PreviewRecorder(path, 640, 480, 10.0)
            first, second = b"\xff\xd8first\xff\xd9", b"\xff\xd8second\xff\xd9"
            recorder.append(first, 10.0)
            recorder.append(second, 10.6)
            recorder.finish()
            data = path.read_bytes()
            self.assertEqual(data[:4], b"RIFF")
            self.assertEqual(struct.unpack_from("<I", data, 4)[0], len(data) - 8)
            avih = data.index(b"avih") + 8
            self.assertEqual(struct.unpack_from("<I", data, avih + 16)[0], 4)
            idx = data.index(b"idx1") + 8
            movi = data.index(b"movi")
            for frame in range(4):
                tag, flags, offset, length = struct.unpack_from("<4sIII", data, idx + frame * 16)
                self.assertEqual(tag, b"00dc")
                self.assertEqual(flags, 0x10)
                self.assertEqual(data[movi + offset:movi + offset + 4], b"00dc")
                expected = first if frame < 3 else second
                self.assertEqual(data[movi + offset + 8:movi + offset + 8 + length], expected)
            self.assertEqual(recorder.finish(), path)

    def test_stalled_preview_can_be_finalized(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.avi"
            recorder = PreviewRecorder(path, 640, 480, 0)
            recorder.append(b"jpeg", 0)
            with self.assertRaisesRegex(RuntimeError, "10 秒"):
                recorder.append(b"jpeg", 12)
            recorder.finish()
            self.assertIn(b"idx1", path.read_bytes())

    def test_size_limit_preserves_valid_completed_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.avi"
            recorder = PreviewRecorder(path, 640, 480, 0)
            recorder.MAX_BYTES = 300
            recorder.append(b"jpeg", 0)
            with self.assertRaisesRegex(RuntimeError, "1 GiB"):
                recorder.append(b"j" * 120, 1)
            recorder.finish()
            self.assertLess(path.stat().st_size, 320)

    def test_existing_file_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing.avi"
            path.write_bytes(b"existing")
            with self.assertRaises(FileExistsError):
                PreviewRecorder(path, 640, 480, 0)
            self.assertEqual(path.read_bytes(), b"existing")


if __name__ == "__main__":
    unittest.main()
