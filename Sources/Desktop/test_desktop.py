"""Offscreen UI lifecycle checks; the fake transport never touches camera hardware."""

import copy
import os
os.environ["QT_QPA_PLATFORM"] = "offscreen"

from argparse import Namespace
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

import main


class MemorySettings:
    def __init__(self, *args):
        pass

    def value(self, key, default):
        return default

    def setValue(self, *args):
        pass


class FakeTransport:
    calls = []
    reject_shutdown = False
    state = {}

    def __init__(self):
        self.state = {"ok": True, "initialized": False, "connected": False,
                      "cameras": [], "properties": [], "manualFocus": {"moving": False},
                      "logs": [], "downloads": []}
        FakeTransport.state = self.state

    def request(self, payload):
        action = payload["action"]
        self.calls.append((action, threading.get_ident()))
        self.state["ok"] = True
        if action == "initialize":
            self.state["initialized"] = True
        elif action == "shutdown":
            self.state["ok"] = not self.reject_shutdown
            if not self.reject_shutdown:
                self.state["initialized"] = False
                self.state["connected"] = False
        elif action == "focus_cancel":
            self.state["manualFocus"]["moving"] = False
        return copy.deepcopy(self.state)

    def live_view(self):
        return None


class DesktopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setQuitOnLastWindowClosed(False)

    def setUp(self):
        FakeTransport.calls = []
        FakeTransport.reject_shutdown = False
        self.transport_patch = patch.object(main, "CameraTransport", FakeTransport)
        self.settings_patch = patch.object(main, "QSettings", MemorySettings)
        self.transport_patch.start()
        self.settings_patch.start()
        self.window = main.CameraWindow(Namespace(smoke_test=False, screenshot=None, smoke_output=None))
        self.window.show()
        self.until(lambda: any(action == "scan" for action, _ in FakeTransport.calls) and not self.window.busy)

    def tearDown(self):
        FakeTransport.reject_shutdown = False
        self.window.close()
        self.until(lambda: self.window.closed_safely and not self.window.thread.isRunning())
        self.transport_patch.stop()
        self.settings_patch.stop()

    def until(self, condition, timeout=3):
        deadline = time.monotonic() + timeout
        while not condition() and time.monotonic() < deadline:
            QTest.qWait(10)
        self.assertTrue(condition(), "Timed out waiting for GUI lifecycle")

    def test_native_calls_run_on_one_worker_thread(self):
        self.window.command("status")
        self.until(lambda: not self.window.busy)
        identities = {identity for _, identity in FakeTransport.calls}
        self.assertEqual(len(identities), 1)
        self.assertNotIn(threading.get_ident(), identities)

    def test_capture_and_focus_states_disable_unsafe_controls(self):
        state = copy.deepcopy(self.window.snapshot)
        state.update(connected=True, photoReady=True, burstModes=[{"label": "Mid", "value": "3"}],
                     manualFocus={"moving": False, "isMF": True, "stepEnabled": True, "steps": [1, 3]})
        self.window._accept(state)
        self.window._update_controls()
        self.assertTrue(self.window.shoot_button.isEnabled())
        self.assertTrue(self.window.burst_start.isEnabled())
        self.assertTrue(self.window.focus_near.isEnabled())
        state["burstDraining"] = True
        self.window._accept(state)
        self.window._update_controls()
        self.assertFalse(self.window.shoot_button.isEnabled())
        self.assertFalse(self.window.focus_near.isEnabled())
        self.assertTrue(self.window.disconnect_button.isEnabled())
        state["burstDraining"] = False
        state["manualFocus"]["moving"] = True
        self.window._accept(state)
        self.window._update_controls()
        self.assertFalse(self.window.shoot_button.isEnabled())
        self.assertTrue(self.window.focus_cancel.isEnabled())

    def test_failed_shutdown_keeps_worker_and_window_available(self):
        FakeTransport.reject_shutdown = True
        self.window.close()
        self.until(lambda: not self.window.shutting_down)
        self.assertFalse(self.window.closed_safely)
        self.assertTrue(self.window.thread.isRunning())
        self.assertTrue(self.window.isVisible())

    def test_shutdown_cancels_moving_focus_before_release(self):
        FakeTransport.state["manualFocus"]["moving"] = True
        self.window.close()
        self.until(lambda: self.window.closed_safely)
        actions = [action for action, _ in FakeTransport.calls]
        self.assertLess(actions.index("focus_cancel"), actions.index("shutdown"))


if __name__ == "__main__":
    unittest.main()
