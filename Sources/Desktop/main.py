"""Sony Camera Control desktop application for Windows and Debian/KDE."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import sys
import time
import uuid

from PySide6.QtCore import QObject, QSettings, QSize, Qt, QThread, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QCloseEvent, QDesktopServices, QFont, QFontDatabase, QImage, QPixmap
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout,
    QFrame, QGroupBox, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem,
    QMainWindow, QPlainTextEdit, QPushButton, QScrollArea, QSizePolicy, QSpinBox,
    QSplitter, QTabWidget, QVBoxLayout, QWidget,
)

from recorder import PreviewRecorder
from transport import CameraTransport


class CameraWorker(QObject):
    completed = Signal(str, dict)
    failed = Signal(str, str)
    frame_ready = Signal(bytes)
    recording_changed = Signal(bool, str)

    def __init__(self):
        super().__init__()
        self.transport: CameraTransport | None = None
        self.recorder: PreviewRecorder | None = None
        self.last_frame: bytes | None = None
        self.last_frame_time = 0.0
        self.last_dimensions = QSize()

    def stop_recording(self):
        if self.recorder:
            recorder, self.recorder = self.recorder, None
            try:
                path = recorder.finish()
                self.recording_changed.emit(False, f"预览录像已保存：{path}")
            except Exception as error:
                self.recording_changed.emit(False, f"保存录像失败：{error}")

    @Slot(str, dict)
    def execute(self, token: str, payload: dict):
        try:
            action = payload.get("action")
            if action == "local_record_stop":
                self.stop_recording()
                self.completed.emit(token, {})
                return
            if action == "local_record_start":
                if self.recorder:
                    raise RuntimeError("预览录像已经开始。")
                if not self.last_frame or time.monotonic() - self.last_frame_time > 2.5:
                    raise RuntimeError("取景画面尚未就绪，请等待实时画面后再开始录制。")
                name = f"Sony_Preview_{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:6]}.avi"
                path = Path(payload["directory"]) / name
                now = time.monotonic()
                self.recorder = PreviewRecorder(path, self.last_dimensions.width(),
                                                self.last_dimensions.height(), now)
                self.recorder.append(self.last_frame, now)
                self.recording_changed.emit(True, f"正在录制本地预览（AVI / 5 fps）：{name}")
                self.completed.emit(token, {})
                return
            if action == "shutdown":
                self.stop_recording()
                if not self.transport:
                    self.completed.emit(token, {"ok": True, "initialized": False})
                    return
                # Release outstanding lens motion before the native shutdown guard.
                status = self.transport.request({"action": "status"})
                if status.get("manualFocus", {}).get("moving"):
                    self.transport.request({"action": "focus_cancel"})
            if not self.transport:
                self.transport = CameraTransport()
            if action == "poll":
                status = self.transport.request({"action": "status"}) if payload.get("status") else {}
                if status and not status.get("connected"):
                    self.stop_recording()
                    self.last_frame = None
                if payload.get("image") and (not status or status.get("connected")):
                    frame = self.transport.live_view()
                    if frame:
                        image = QImage.fromData(frame, "JPEG")
                        if not image.isNull():
                            now = time.monotonic()
                            self.last_frame, self.last_frame_time = frame, now
                            self.last_dimensions = image.size()
                            if self.recorder:
                                try:
                                    if (image.width(), image.height()) != (self.recorder.width, self.recorder.height):
                                        raise RuntimeError("取景分辨率发生变化，已结束并保存录像。")
                                    self.recorder.append(frame, now)
                                except Exception as error:
                                    self.stop_recording()
                                    self.recording_changed.emit(False, str(error))
                            self.frame_ready.emit(frame)
                    if self.recorder and time.monotonic() - self.last_frame_time > 10:
                        self.stop_recording()
                        self.recording_changed.emit(False, "取景中断超过 10 秒，预览录像已保存。")
                self.completed.emit(token, status)
            else:
                if action == "disconnect":
                    self.stop_recording()
                    self.last_frame = None
                self.completed.emit(token, self.transport.request(payload))
        except Exception as error:
            if payload.get("action") == "local_record_start":
                self.stop_recording()
            self.failed.emit(token, str(error))


class Preview(QLabel):
    def __init__(self):
        super().__init__("连接相机后显示实时取景\n\nUSB / 网络连接 · Sony Camera Remote SDK")
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumSize(420, 250)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setObjectName("preview")
        self._image: QPixmap | None = None

    def set_frame(self, data: bytes):
        pixmap = QPixmap()
        if pixmap.loadFromData(data, "JPEG"):
            self._image = pixmap
            self._rescale()

    def clear_frame(self):
        self._image = None
        self.setPixmap(QPixmap())
        self.setText("连接相机后显示实时取景\n\nUSB / 网络连接 · Sony Camera Remote SDK")

    def _rescale(self):
        if self._image:
            self.setPixmap(self._image.scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio,
                                              Qt.TransformationMode.SmoothTransformation))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._rescale()


class CameraWindow(QMainWindow):
    request = Signal(str, dict)

    def __init__(self, args):
        super().__init__()
        self.args = args
        self.setWindowTitle("Sony Camera Control")
        self.resize(1320, 900)
        self.setMinimumSize(1024, 700)
        self.settings = QSettings("SonyCameraControl", "SonyCameraControl")
        self.save_directory = str(self.settings.value("saveDirectory", str(Path.home() / "Pictures" / "Sony Captures")))
        self.snapshot: dict = {}
        self.busy = False
        self.polling = False
        self.shutting_down = False
        self.closed_safely = False
        self.local_recording = False
        self.recording_started = 0.0
        self.last_frame_time = 0.0
        self.last_status_time = 0.0
        self.last_logs = []
        self.last_downloads = []
        self.property_rows: dict[int, tuple[QLabel, QComboBox]] = {}
        self.smoke_stages = []
        self.exit_code = 0
        self.smoke_finished = False
        self._build_ui()
        self.thread = QThread(self)
        self.worker = CameraWorker()
        self.worker.moveToThread(self.thread)
        self.request.connect(self.worker.execute)
        self.worker.completed.connect(self._completed)
        self.worker.failed.connect(self._failed)
        self.worker.frame_ready.connect(self._frame_ready)
        self.worker.recording_changed.connect(self._recording_changed)
        self.thread.finished.connect(self.worker.deleteLater)
        self.thread.finished.connect(self._thread_stopped)
        self.thread.start()
        self.timer = QTimer(self)
        self.timer.setInterval(200)
        self.timer.timeout.connect(self._poll)
        self.timer.start()
        self._update_controls()
        QTimer.singleShot(0, lambda: self.command("initialize", saveDirectory=self.save_directory))
        if args.smoke_test:
            QTimer.singleShot(45000, self._smoke_timeout)

    @staticmethod
    def _row(*widgets) -> QHBoxLayout:
        row = QHBoxLayout()
        for widget in widgets:
            row.addWidget(widget)
        return row

    @staticmethod
    def _button(text, callback) -> QPushButton:
        button = QPushButton(text)
        button.clicked.connect(callback)
        return button

    def _build_ui(self):
        content = QWidget()
        outer = QVBoxLayout(content)
        outer.setContentsMargins(22, 18, 22, 14)
        heading = QLabel("Sony Camera Control")
        heading.setObjectName("heading")
        self.connection_label = QLabel("相机服务正在启动…")
        self.connection_label.setObjectName("connection")
        outer.addLayout(self._row(heading, self.connection_label))
        splitter = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        sidebar = QVBoxLayout(left)
        sidebar.setContentsMargins(0, 0, 10, 0)

        connection = QGroupBox("相机连接")
        conn = QVBoxLayout(connection)
        self.camera_combo = QComboBox()
        self.camera_combo.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.camera_combo.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.camera_combo.setMinimumContentsLength(10)
        self.scan_button = self._button("搜索相机", lambda: self.command("scan"))
        conn.addLayout(self._row(self.camera_combo, self.scan_button))
        self.connect_button = self._button("连接", self._connect)
        self.disconnect_button = self._button("断开", lambda: self.command("disconnect"))
        conn.addLayout(self._row(self.connect_button, self.disconnect_button))
        self.auth_toggle = QCheckBox("网络连接认证")
        conn.addWidget(self.auth_toggle)
        self.auth = QWidget()
        auth_form = QFormLayout(self.auth)
        auth_form.setContentsMargins(0, 4, 0, 2)
        self.username = QLineEdit()
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.EchoMode.Password)
        self.fingerprint = QLineEdit()
        self.fingerprint.setPlaceholderText("相机证书指纹（如需要）")
        auth_form.addRow("用户名", self.username)
        auth_form.addRow("密码", self.password)
        auth_form.addRow("指纹", self.fingerprint)
        self.auth.setVisible(False)
        self.auth_toggle.toggled.connect(self.auth.setVisible)
        conn.addWidget(self.auth)
        sidebar.addWidget(connection)

        shooting = QGroupBox("拍摄与连拍")
        shoot = QVBoxLayout(shooting)
        self.shoot_button = self._button("拍摄照片", lambda: self.command("shoot"))
        self.shoot_button.setObjectName("primary")
        self.autofocus_button = self._button("自动对焦", lambda: self.command("autofocus"))
        shoot.addLayout(self._row(self.shoot_button, self.autofocus_button))
        self.burst_modes = QComboBox()
        self.burst_modes.setToolTip("仅显示当前相机支持的连拍模式")
        self.burst_duration = QDoubleSpinBox()
        self.burst_duration.setRange(0.5, 10.0)
        self.burst_duration.setSingleStep(0.5)
        self.burst_duration.setValue(1.0)
        self.burst_duration.setSuffix(" 秒")
        shoot.addLayout(self._row(self.burst_modes, self.burst_duration))
        self.burst_start = self._button("开始连拍", self._start_burst)
        self.burst_stop = self._button("停止连拍", lambda: self.command("burst_stop"))
        shoot.addLayout(self._row(self.burst_start, self.burst_stop))
        self.burst_status = QLabel("照片将直接保存到电脑")
        self.burst_status.setWordWrap(True)
        shoot.addWidget(self.burst_status)
        sidebar.addWidget(shooting)

        focus_group = QGroupBox("手动对焦")
        focus = QVBoxLayout(focus_group)
        self.mf_button = self._button("切换 MF 手动", lambda: self.command("set_property", code=265, value="1"))
        self.focus_cancel = self._button("停止对焦", lambda: self.command("focus_cancel"))
        focus.addLayout(self._row(self.mf_button, self.focus_cancel))
        self.focus_steps = QComboBox()
        self.focus_near = self._button("向近处", lambda: self._step_focus(-1))
        self.focus_far = self._button("向远处", lambda: self._step_focus(1))
        focus.addLayout(self._row(self.focus_near, self.focus_steps, self.focus_far))
        self.focus_position = QSpinBox()
        self.focus_position.setRange(0, 65535)
        self.focus_position.setToolTip("镜头报告的位置单位，不代表距离")
        self.focus_set = self._button("设置位置", self._set_focus)
        focus.addLayout(self._row(self.focus_position, self.focus_set))
        self.focus_status = QLabel("连接后读取镜头支持的功能")
        self.focus_status.setWordWrap(True)
        focus.addWidget(self.focus_status)
        sidebar.addWidget(focus_group)

        properties = QGroupBox("相机参数")
        self.properties_form = QFormLayout(properties)
        self.no_properties = QLabel("连接后显示可用参数")
        self.properties_form.addRow(self.no_properties)
        sidebar.addWidget(properties)
        sidebar.addStretch()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(left)
        scroll.setMinimumWidth(375)
        splitter.addWidget(scroll)

        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(10, 0, 0, 0)
        self.live_toggle = QCheckBox("实时取景")
        self.live_toggle.toggled.connect(self._live_toggled)
        self.live_status = QLabel("等待相机")
        self.record_button = self._button("录制本地预览", self._toggle_recording)
        self.record_button.setToolTip("将电脑收到的预览画面保存为 5 fps MJPEG AVI；不启动机内录像")
        right_layout.addLayout(self._row(self.live_toggle, self.live_status, self.record_button))
        self.preview = Preview()
        right_layout.addWidget(self.preview, 5)
        self.notice = QLabel("")
        self.notice.setWordWrap(True)
        self.notice.setMinimumHeight(42)
        self.notice.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        right_layout.addWidget(self.notice)
        tabs = QTabWidget()
        self.downloads = QListWidget()
        self.downloads.setToolTip("双击文件可打开")
        self.downloads.itemDoubleClicked.connect(self._open_download)
        tabs.addTab(self.downloads, "已保存照片")
        logs = QWidget()
        logs_layout = QVBoxLayout(logs)
        self.log_text = QPlainTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setMaximumBlockCount(600)
        logs_layout.addWidget(self.log_text)
        logs_layout.addWidget(self._button("导出日志", self._export_logs))
        tabs.addTab(logs, "运行日志")
        tabs.setMinimumHeight(165)
        right_layout.addWidget(tabs, 2)
        splitter.addWidget(right)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([385, 875])
        outer.addWidget(splitter, 1)

        self.directory_label = QLabel(self.save_directory)
        self.directory_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.directory_label.setWordWrap(True)
        self.choose_directory = self._button("更改保存位置", self._choose_directory)
        open_directory = self._button("打开文件夹", self._open_directory)
        outer.addLayout(self._row(QLabel("保存位置"), self.directory_label, self.choose_directory, open_directory))
        self.setCentralWidget(content)
        self.statusBar().showMessage("Sony Camera Remote SDK · Windows / Linux")
        self.setStyleSheet("""
            QMainWindow, QWidget { background: #181d24; color: #e5eaf0; font-size: 13px; }
            QLabel#heading { font-size: 23px; font-weight: 650; padding-bottom: 10px; }
            QLabel#connection { color: #9cb6cf; padding-left: 25px; padding-bottom: 10px; }
            QGroupBox { border: 1px solid #354252; border-radius: 7px; margin-top: 11px; padding: 15px 10px 10px; }
            QGroupBox::title { subcontrol-origin: margin; left: 12px; color: #a7bbd0; }
            QPushButton { background: #2b3949; border: 1px solid #44566b; border-radius: 5px; padding: 7px 10px; }
            QPushButton:hover { background: #354c63; }
            QPushButton:pressed { background: #233b53; }
            QPushButton:disabled { background: #242a33; color: #697687; border-color: #303a46; }
            QPushButton#primary:enabled { background: #216fbc; border-color: #4194e8; }
            QComboBox, QLineEdit, QSpinBox, QDoubleSpinBox { background: #11171e; border: 1px solid #3c4a5b; border-radius: 4px; padding: 6px; }
            QComboBox:disabled, QSpinBox:disabled, QDoubleSpinBox:disabled { color: #697687; }
            QComboBox QAbstractItemView { background: #202c39; selection-background-color: #246ca7; }
            QLabel#preview { background: #0a0e13; color: #71859b; border: 1px solid #354252; border-radius: 7px; }
            QPlainTextEdit, QListWidget { background: #11171e; border: 1px solid #354252; padding: 5px; }
            QTabWidget::pane { border: 1px solid #354252; }
            QTabBar::tab { background: #222d3a; padding: 8px 18px; }
            QTabBar::tab:selected { background: #354b62; }
            QStatusBar { color: #8da2b7; }
            QCheckBox { spacing: 7px; }
        """)

    def command(self, action: str, **params):
        if self.busy or self.shutting_down:
            return
        self.busy = True
        self.statusBar().showMessage("正在处理相机请求…")
        self._update_controls()
        self.request.emit(action, {"action": action, **params})

    def _connect(self):
        index = self.camera_combo.currentData()
        if index is not None:
            self.command("connect", index=index, user=self.username.text(),
                         password=self.password.text(), fingerprint=self.fingerprint.text())

    def _start_burst(self):
        mode = self.burst_modes.currentData()
        if mode is not None:
            self.command("burst_start", mode=mode, duration=self.burst_duration.value())

    def _step_focus(self, direction):
        step = self.focus_steps.currentData()
        if step:
            self.command("focus_step", step=direction * int(step))

    def _set_focus(self):
        focus = self.snapshot.get("manualFocus") or {}
        increment = int(focus.get("increment") or 1)
        value = self.focus_position.value()
        if (value - int(focus.get("minimum", 0))) % increment:
            self._notice(f"位置必须从最小值起按 {increment} 递增。", True)
            return
        self.command("focus_position", value=value)

    def _choose_directory(self):
        path = QFileDialog.getExistingDirectory(self, "选择照片与预览录像保存位置", self.save_directory)
        if path:
            self.command("set_save_directory", path=path)

    def _open_directory(self):
        path = Path(self.save_directory)
        try:
            path.mkdir(parents=True, exist_ok=True)
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))
        except OSError as error:
            self._notice(str(error), True)

    def _open_download(self, item):
        path = item.data(Qt.ItemDataRole.UserRole)
        if path:
            QDesktopServices.openUrl(QUrl.fromLocalFile(path))

    def _export_logs(self):
        path, _ = QFileDialog.getSaveFileName(self, "导出日志", "Sony-Camera-Control.log", "日志 (*.log);;所有文件 (*)")
        if path:
            try:
                Path(path).write_text(self.log_text.toPlainText() + "\n", encoding="utf-8")
                self._notice("日志已导出。")
            except OSError as error:
                self._notice(str(error), True)

    def _live_toggled(self, enabled):
        if not enabled and self.local_recording and not self.shutting_down:
            self.command("local_record_stop")
        self._update_controls()

    def _toggle_recording(self):
        if self.local_recording:
            self.command("local_record_stop")
        else:
            self.command("local_record_start", directory=self.save_directory)

    @Slot(bool, str)
    def _recording_changed(self, recording, message):
        self.local_recording = recording
        self.recording_started = time.monotonic() if recording else 0
        self._notice(message)
        self._update_controls()

    def _notice(self, text, error=False):
        self.notice.setText(text)
        self.notice.setStyleSheet("color: #ffa59d;" if error else "color: #b7cce1;")

    @Slot(bytes)
    def _frame_ready(self, frame):
        if not self.shutting_down and self.live_toggle.isChecked() and self.snapshot.get("connected"):
            self.preview.set_frame(frame)
            self.last_frame_time = time.monotonic()
            self.live_status.setText("实时画面 · 最高 5 fps")
            self._update_controls()

    def _poll(self):
        if self.local_recording:
            elapsed = int(time.monotonic() - self.recording_started)
            self.record_button.setText(f"停止录像 {elapsed // 60:02d}:{elapsed % 60:02d}")
        if self.shutting_down or self.busy or self.polling or not self.snapshot.get("initialized"):
            return
        now = time.monotonic()
        status = now - self.last_status_time >= 1.0
        image = self.live_toggle.isChecked() and bool(self.snapshot.get("connected"))
        if image and now - self.last_frame_time > 2.5:
            self.live_status.setText("正在等待取景画面…")
            self._update_controls()
        if not status and not image:
            return
        self.polling = True
        if status:
            self.last_status_time = now
        self.request.emit("poll", {"action": "poll", "status": status, "image": image})

    @Slot(str, dict)
    def _completed(self, token, snapshot):
        if token == "poll":
            self.polling = False
        else:
            self.busy = False
        if snapshot:
            self._accept(snapshot)
        if token == "connect":
            self.password.clear()
        if token == "shutdown":
            if snapshot.get("ok") and not snapshot.get("initialized"):
                self.closed_safely = True
                if self.args.smoke_test:
                    self.smoke_stages.append({"action": "shutdown", "ok": True})
                    self._write_smoke_report()
                self.thread.quit()
            else:
                self.shutting_down = False
                self.timer.start()
                self._notice(snapshot.get("message") or "相机尚未安全停止，请等待下载或对焦完成后再次关闭。", True)
                self._update_controls()
            return
        self._update_controls()
        self.statusBar().showMessage("相机已连接" if self.snapshot.get("connected") else "等待连接相机")
        if token not in ("poll", "status") and snapshot.get("message"):
            self._notice(snapshot["message"], not snapshot.get("ok", True))
        if self.args.smoke_test and token in ("initialize", "scan", "status"):
            self.smoke_stages.append({"action": token, "ok": snapshot.get("ok", False),
                                      "initialized": snapshot.get("initialized", False),
                                      "cameras": len(snapshot.get("cameras", [])),
                                      "message": snapshot.get("message", "")})
            if not snapshot.get("ok"):
                self.exit_code = 1
                self._finish_smoke()
            elif token == "initialize":
                self.command("scan")
            elif token == "scan":
                self.command("status")
            else:
                self._finish_smoke()
        elif token == "initialize" and snapshot.get("ok"):
            self.command("scan")

    @Slot(str, str)
    def _failed(self, token, message):
        if token == "poll":
            self.polling = False
        else:
            self.busy = False
        self._notice(f"相机服务错误：{message}", True)
        self.statusBar().showMessage("相机服务发生错误")
        if token == "shutdown":
            self.shutting_down = False
            self.timer.start()
        self._update_controls()
        if self.args.smoke_test:
            self.exit_code = 1
            self.smoke_stages.append({"action": token, "ok": False, "message": message})
            self._write_smoke_report()
            if token != "shutdown":
                self._finish_smoke()

    def _accept(self, snapshot):
        was_connected = bool(self.snapshot.get("connected"))
        self.snapshot = snapshot
        connected = bool(snapshot.get("connected"))
        if connected and not was_connected:
            self.live_toggle.setChecked(True)
        elif not connected and was_connected:
            self.live_toggle.setChecked(False)
            self.last_frame_time = 0.0
            self.preview.clear_frame()
        if snapshot.get("saveDirectory"):
            self.save_directory = snapshot["saveDirectory"]
            self.directory_label.setText(self.save_directory)
            if not self.args.smoke_test:
                self.settings.setValue("saveDirectory", self.save_directory)
        cameras = [(camera.get("name", "Sony"), camera.get("index"), camera.get("connection", ""))
                   for camera in snapshot.get("cameras", [])]
        entries = [(f"{name} · {connection}" if connection else name, index) for name, index, connection in cameras]
        self._fill_combo(self.camera_combo, entries)
        self._fill_combo(self.burst_modes, [(option["label"], option["value"]) for option in snapshot.get("burstModes", [])])
        focus = snapshot.get("manualFocus") or {}
        self._fill_combo(self.focus_steps, [(f"{step} 档", int(step)) for step in focus.get("steps", [])])
        minimum, maximum = int(focus.get("minimum", 0)), int(focus.get("maximum", 65535))
        self.focus_position.setRange(minimum, max(minimum, maximum))
        self.focus_position.setSingleStep(max(1, int(focus.get("increment", 1))))
        position = focus.get("position")
        if connected and not was_connected and position is not None:
            self.focus_position.setValue(int(position))
        position_text = f"当前位置 {position} · " if position is not None else ""
        self.focus_status.setText(position_text + (focus.get("status") or ("MF 手动对焦" if focus.get("isMF") else "切换到 MF 后可手动调整")))
        burst = snapshot.get("burstStatus", "")
        if snapshot.get("burstActive") or snapshot.get("burstDraining") or snapshot.get("burstCaptured"):
            burst += f"\n拍摄 {snapshot.get('burstCaptured', 0)} 张 · 下载 {snapshot.get('burstDownloaded', 0)} 张 · 文件 {snapshot.get('burstFiles', 0)}"
        elif snapshot.get("pendingPhoto"):
            burst = "等待相机完成拍摄并下载照片…"
        self.burst_status.setText(burst or "照片将直接保存到电脑")
        self._render_properties(snapshot.get("properties", []))
        logs = snapshot.get("logs", [])
        if logs != self.last_logs:
            previous = max((row.get("id", 0) for row in self.last_logs), default=0)
            self.last_logs = logs
            self.log_text.setPlainText("\n".join(f"{row.get('time', '')} [{row.get('level', '')}] {row.get('message', '')}" for row in logs))
            self.log_text.verticalScrollBar().setValue(self.log_text.verticalScrollBar().maximum())
            errors = [row for row in logs if row.get("id", 0) > previous and row.get("level") == "error"]
            if errors:
                self._notice(errors[-1].get("message", ""), True)
        downloads = snapshot.get("downloads", [])
        if downloads != self.last_downloads:
            self.last_downloads = downloads
            self.downloads.clear()
            for photo in reversed(downloads):
                item = QListWidgetItem(f"{photo.get('name', Path(photo['path']).name)}\n{photo['path']}")
                item.setData(Qt.ItemDataRole.UserRole, photo["path"])
                item.setToolTip(photo["path"])
                self.downloads.addItem(item)
            if downloads:
                self._notice(f"照片已保存：{downloads[-1].get('name', '')}")

    @staticmethod
    def _fill_combo(combo, entries):
        current = [(combo.itemText(i), combo.itemData(i)) for i in range(combo.count())]
        if current == entries:
            return
        selected = combo.currentData()
        combo.blockSignals(True)
        combo.clear()
        for label, value in entries:
            combo.addItem(str(label), value)
        index = combo.findData(selected)
        if index >= 0:
            combo.setCurrentIndex(index)
        combo.blockSignals(False)

    def _render_properties(self, properties):
        codes = {int(prop["code"]) for prop in properties}
        for code in list(self.property_rows):
            if code not in codes:
                _, combo = self.property_rows.pop(code)
                self.properties_form.removeRow(combo)
        self.no_properties.setVisible(not properties)
        for prop in properties:
            code = int(prop["code"])
            if code not in self.property_rows:
                label, combo = QLabel(prop["name"]), QComboBox()
                combo.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
                combo.setMinimumContentsLength(12)
                combo.activated.connect(lambda index, c=code, w=combo: self.command("set_property", code=c, value=w.itemData(index)))
                self.properties_form.addRow(label, combo)
                self.property_rows[code] = label, combo
            label, combo = self.property_rows[code]
            label.setText(prop["name"])
            options = [(entry["label"], entry["value"]) for entry in prop.get("options", [])]
            value = prop.get("value")
            if value not in [entry[1] for entry in options]:
                options.insert(0, (prop.get("label", str(value)), value))
            # Do not rearrange an open popup beneath the user's pointer.
            if not combo.view().isVisible():
                self._fill_combo(combo, options)
                combo.setCurrentIndex(combo.findData(value))

    def _update_controls(self):
        snapshot = self.snapshot
        connected = bool(snapshot.get("connected"))
        ready = connected and not self.busy and not self.shutting_down
        focus = snapshot.get("manualFocus") or {}
        capture = any(snapshot.get(key) for key in ("pendingPhoto", "burstActive", "burstDraining"))
        configurable = ready and not capture and not focus.get("moving")
        available = not self.busy and not self.shutting_down
        shoot = configurable and bool(snapshot.get("photoReady")) and not snapshot.get("recording")
        self.scan_button.setEnabled(available and bool(snapshot.get("initialized")) and not connected and not snapshot.get("connecting"))
        self.camera_combo.setEnabled(available and not connected)
        self.connect_button.setEnabled(available and not connected and not snapshot.get("connecting") and self.camera_combo.count() > 0)
        self.disconnect_button.setEnabled(ready)
        self.shoot_button.setEnabled(shoot)
        self.autofocus_button.setEnabled(configurable)
        self.burst_modes.setEnabled(configurable and not self.local_recording)
        self.burst_duration.setEnabled(configurable and not self.local_recording)
        self.burst_start.setEnabled(shoot and self.burst_modes.count() > 0 and not self.local_recording)
        self.burst_stop.setEnabled(ready and bool(snapshot.get("burstActive")))
        self.focus_cancel.setEnabled(ready and bool(focus.get("moving")))
        mf_property = next((prop for prop in snapshot.get("properties", []) if prop["code"] == 265), {})
        supports_mf = mf_property.get("writable") and any(option.get("value") == "1" for option in mf_property.get("options", []))
        self.mf_button.setEnabled(configurable and not focus.get("isMF") and bool(supports_mf))
        can_step = configurable and bool(focus.get("isMF")) and bool(focus.get("stepEnabled")) and self.focus_steps.count() > 0
        for widget in (self.focus_near, self.focus_far, self.focus_steps):
            widget.setEnabled(can_step)
        can_position = configurable and bool(focus.get("isMF")) and bool(focus.get("positionEnabled"))
        self.focus_position.setEnabled(can_position)
        self.focus_set.setEnabled(can_position)
        for prop in snapshot.get("properties", []):
            if int(prop["code"]) in self.property_rows:
                self.property_rows[int(prop["code"])][1].setEnabled(configurable and bool(prop.get("writable")))
        self.choose_directory.setEnabled(available and bool(snapshot.get("initialized")) and not capture and not self.local_recording and not focus.get("moving"))
        self.live_toggle.setEnabled(ready and not self.local_recording)
        fresh = self.live_toggle.isChecked() and time.monotonic() - self.last_frame_time < 2.5
        self.record_button.setEnabled(available and (self.local_recording or (configurable and fresh)))
        if not self.local_recording:
            self.record_button.setText("录制本地预览")
        if self.shutting_down:
            self.connection_label.setText("正在安全停止相机…")
        elif connected:
            self.connection_label.setText(f"已连接 · {snapshot.get('cameraName', 'Sony')}")
        elif snapshot.get("connecting"):
            self.connection_label.setText("正在连接相机…")
        elif snapshot.get("initialized"):
            self.connection_label.setText("未连接 · 请通过 USB / 网络连接相机")
        else:
            self.connection_label.setText("相机服务尚未就绪")

    def closeEvent(self, event: QCloseEvent):
        if self.closed_safely:
            event.accept()
            return
        event.ignore()
        if self.shutting_down:
            return
        self.shutting_down = True
        self.timer.stop()
        self._update_controls()
        self._notice("正在停止拍摄、保存录像并释放相机连接…")
        self.request.emit("shutdown", {"action": "shutdown"})

    @Slot()
    def _thread_stopped(self):
        self.close()
        QApplication.instance().exit(self.exit_code)

    def _finish_smoke(self):
        if self.smoke_finished:
            return
        self.smoke_finished = True
        self.timer.stop()
        QTimer.singleShot(250, self._capture_and_close)

    def _capture_and_close(self):
        if self.args.screenshot:
            path = Path(self.args.screenshot).resolve()
            path.parent.mkdir(parents=True, exist_ok=True)
            if not self.grab().save(str(path)):
                self.exit_code = 1
                self.smoke_stages.append({"action": "screenshot", "ok": False})
        self._write_smoke_report()
        self.close()

    def _write_smoke_report(self):
        report = {"ok": self.exit_code == 0, "platform": sys.platform, "stages": self.smoke_stages,
                  "connected": bool(self.snapshot.get("connected")), "shutdown": self.closed_safely}
        text = json.dumps(report, ensure_ascii=False, indent=2)
        if self.args.smoke_output:
            path = Path(self.args.smoke_output)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text + "\n", encoding="utf-8")
        if sys.stdout:
            print(text, flush=True)

    def _smoke_timeout(self):
        if not self.closed_safely:
            self.exit_code = 1
            self.smoke_stages.append({"action": "timeout", "ok": False})
            self._write_smoke_report()
            if not self.shutting_down:
                self.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Sony Camera Control for Windows and Linux")
    parser.add_argument("--smoke-test", action="store_true", help="Initialize, scan, query status, then release SDK and exit")
    parser.add_argument("--offscreen", action="store_true", help="Use Qt's offscreen platform for automated checks")
    parser.add_argument("--screenshot", help="Save a smoke-test screenshot to this PNG path")
    parser.add_argument("--smoke-output", help="Write smoke-test JSON to this file (also works in GUI builds)")
    args = parser.parse_args()
    if args.offscreen:
        os.environ["QT_QPA_PLATFORM"] = "offscreen"
    app = QApplication(sys.argv[:1])
    # The Windows offscreen Qt plugin has no native font database. Load an installed
    # system font for CI screenshots; normal desktop launches use the same fallback list.
    if os.name == "nt" and not QFontDatabase.families():
        fonts = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
        for name in ("msyh.ttc", "segoeui.ttf"):
            path = fonts / name
            if path.is_file():
                QFontDatabase.addApplicationFont(str(path))
    font = QFont()
    font.setFamilies(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "WenQuanYi Micro Hei", "DejaVu Sans"])
    font.setPointSize(10)
    app.setFont(font)
    app.setApplicationName("Sony Camera Control")
    app.setOrganizationName("SonyCameraControl")
    app.setQuitOnLastWindowClosed(False)
    window = CameraWindow(args)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
