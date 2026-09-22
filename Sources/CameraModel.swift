import AppKit
import Combine
import Foundation

struct CameraDescriptor: Decodable, Identifiable {
    let index: Int
    let name: String
    let connection: String
    let id: String
}

struct PropertyOption: Decodable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

struct CameraProperty: Decodable, Identifiable {
    let code: UInt32
    let name: String
    let value: String
    let label: String
    let writable: Bool
    let options: [PropertyOption]
    var id: UInt32 { code }
}

struct DownloadedPhoto: Decodable, Identifiable {
    let path: String
    let name: String
    var id: String { path }
}

struct CameraLog: Decodable, Identifiable {
    let id: Int
    let time: String
    let level: String
    let message: String
}

struct ManualFocusSnapshot: Decodable {
    var isMF = false
    var stepEnabled = false
    var positionEnabled = false
    var moving = false
    var position: Int?
    var minimum = 0
    var maximum = 65535
    var increment = 1
    var steps: [Int] = []
    var status = ""
    init() {}
}

struct CameraSnapshot: Decodable {
    var ok = true
    var message = ""
    var initialized = false
    var connected = false
    var connecting = false
    var pendingPhoto: Bool? = false
    var captureConfirmed: Bool? = false
    var burstActive: Bool? = false
    var burstDraining: Bool? = false
    var burstRecoverable: Bool? = false
    var burstCaptured: Int? = 0
    var burstDownloaded: Int? = 0
    var burstFiles: Int? = 0
    var burstModes: [PropertyOption]? = []
    var burstElapsed: Double? = 0
    var burstStatus: String? = ""
    var manualFocus: ManualFocusSnapshot?
    var cameraName = ""
    var cameras: [CameraDescriptor] = []
    var properties: [CameraProperty] = []
    var recording = false
    var recordingKnown = false
    var saveDirectory = ""
    var downloads: [DownloadedPhoto] = []
    var logs: [CameraLog] = []

    init() {}
}

/// The SDK and its device handle are only accessed on this queue.
final class CameraTransport: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.lr1.control.sdk", qos: .userInitiated)

    func request(_ payload: [String: Any]) -> Result<CameraSnapshot, Error> {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let request = String(decoding: data, as: UTF8.self)
            guard let pointer = request.withCString({ lr1_request($0) }) else {
                throw NSError(domain: "LR1", code: 1, userInfo: [NSLocalizedDescriptionKey: "SDK 未返回状态。"])
            }
            defer { lr1_free(pointer) }
            let response = Data(bytes: pointer, count: strlen(pointer))
            return .success(try JSONDecoder().decode(CameraSnapshot.self, from: response))
        } catch { return .failure(error) }
    }

    func liveView() -> Data? {
        var length: Int32 = 0
        guard let bytes = lr1_copy_live_view(&length) else { return nil }
        defer { lr1_free(bytes) }
        guard length > 0 else { return nil }
        return Data(bytes: bytes, count: Int(length))
    }
}

@MainActor
final class CameraModel: ObservableObject {
    static let shared = CameraModel()
    @Published var snapshot = CameraSnapshot()
    @Published var selectedCamera = -1
    @Published var username = ""
    @Published var password = ""
    @Published var fingerprint = ""
    @Published var liveViewEnabled = false
    @Published var liveImage: NSImage?
    @Published var lastFrameDate: Date?
    @Published var busy = false
    @Published var activity = "正在启动相机服务…"
    @Published var notice = ""
    @Published var noticeIsError = false
    @Published var showLogs = false
    @Published var showHelp = false
    @Published var localRecording = false
    @Published var finishingVideo = false
    @Published var lastVideo: URL?
    @Published var recordingSeconds = 0
    @Published var saveDirectory: String
    @Published var selectedBurstMode = ""
    @Published var burstDuration = 1.0
    @Published var focusStep = 1
    @Published var focusPositionInput = ""
    private let transport = CameraTransport()
    private let videoRecorder = LocalVideoRecorder()
    private var recordingStartedAt: Date?
    private var timer: Timer?
    private var pollInFlight = false
    private var lastStatusPoll = Date.distantPast
    private var shuttingDown = false

    private init() {
        saveDirectory = UserDefaults.standard.string(forKey: "photoDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/LR1 Captures").path
    }

    var ready: Bool { snapshot.connected && !busy && !shuttingDown }
    var burstActive: Bool { snapshot.burstActive == true }
    var burstDraining: Bool { snapshot.burstDraining == true }
    var burstRecoverable: Bool { snapshot.burstRecoverable == true }
    var captureInProgress: Bool { snapshot.pendingPhoto == true || burstActive || burstDraining }
    var singlePhotoPending: Bool { snapshot.pendingPhoto == true && !burstActive && !burstDraining }
    var manualFocus: ManualFocusSnapshot { snapshot.manualFocus ?? ManualFocusSnapshot() }
    var canConfigure: Bool { ready && !captureInProgress && !manualFocus.moving }
    var canSetFocusPosition: Bool {
        guard canConfigure, manualFocus.isMF, manualFocus.positionEnabled,
              let value = Int(focusPositionInput), manualFocus.increment > 0,
              manualFocus.minimum <= manualFocus.maximum,
              (manualFocus.minimum...manualFocus.maximum).contains(value) else { return false }
        return (value - manualFocus.minimum) % manualFocus.increment == 0
    }
    var burstModes: [PropertyOption] { snapshot.burstModes ?? [] }
    var canStartBurst: Bool {
        canConfigure && !snapshot.recording && !localRecording && !finishingVideo &&
        burstModes.contains(where: { $0.value == selectedBurstMode })
    }
    var recordingStatus: String {
        if finishingVideo { return "正在保存…" }
        if localRecording { return String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60) }
        return "本地录制"
    }
    var freshLiveView: Bool {
        liveViewEnabled && snapshot.connected && lastFrameDate.map { Date().timeIntervalSince($0) < 2.5 } == true
    }

    func start() {
        guard timer == nil else { return }
        perform(["action": "initialize", "saveDirectory": saveDirectory], activity: "正在启动相机服务…") { [weak self] in
            self?.scan()
        }
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func accept(_ result: Result<CameraSnapshot, Error>, announce: Bool) {
        switch result {
        case .success(let next):
            let wasConnected = snapshot.connected
            let previousLogID = snapshot.logs.last?.id ?? 0
            let previousDownload = snapshot.downloads.last?.path
            snapshot = next
            if let focus = next.manualFocus {
                if !focus.steps.isEmpty && !focus.steps.contains(focusStep) { focusStep = focus.steps[0] }
                if focusPositionInput.isEmpty, let position = focus.position { focusPositionInput = String(position) }
            }
            if let modes = next.burstModes, !modes.isEmpty,
               !modes.contains(where: { $0.value == selectedBurstMode }) {
                selectedBurstMode = modes.first(where: { $0.label.contains("Mid") })?.value ?? modes[0].value
            }
            if !wasConnected && next.connected { liveViewEnabled = true }
            if !next.saveDirectory.isEmpty { saveDirectory = next.saveDirectory }
            if !next.cameras.contains(where: { $0.index == selectedCamera }) {
                selectedCamera = next.cameras.first?.index ?? -1
            }
            if wasConnected && !next.connected {
                if localRecording { stopMovie() }
                liveViewEnabled = false
                liveImage = nil
                lastFrameDate = nil
            }
            if announce || !next.ok {
                notice = next.message
                noticeIsError = !next.ok
            } else if let error = next.logs.last(where: { $0.id > previousLogID && $0.level == "error" }) {
                notice = error.message
                noticeIsError = true
            } else if let download = next.downloads.last, download.path != previousDownload {
                notice = "照片已保存到 Mac：\(download.name)"
                noticeIsError = false
            }
        case .failure(let error):
            notice = "相机服务响应错误：\(error.localizedDescription)"
            noticeIsError = true
        }
    }

    func perform(_ payload: [String: Any], activity: String, completion: (() -> Void)? = nil) {
        guard !busy, !shuttingDown else { return }
        busy = true
        self.activity = activity
        transport.queue.async { [self] in
            let result = transport.request(payload)
            DispatchQueue.main.async { [self] in
                accept(result, announce: true)
                busy = false
                self.activity = ""
                completion?()
            }
        }
    }

    private func poll() {
        if let recordingStartedAt { recordingSeconds = Int(Date().timeIntervalSince(recordingStartedAt)) }
        guard !busy, !pollInFlight, !shuttingDown, snapshot.initialized else { return }
        let wantsStatus = Date().timeIntervalSince(lastStatusPoll) >= 1.0
        let wantsImage = liveViewEnabled && snapshot.connected
        let recordsFrame = localRecording
        guard wantsStatus || wantsImage else { return }
        pollInFlight = true
        if wantsStatus { lastStatusPoll = Date() }
        transport.queue.async { [self] in
            let result = wantsStatus ? transport.request(["action": "status"]) : nil
            let frame = wantsImage ? transport.liveView() : nil
            if recordsFrame, let frame { videoRecorder.append(jpeg: frame, timestamp: ProcessInfo.processInfo.systemUptime) }
            DispatchQueue.main.async { [self] in
                if let result { accept(result, announce: false) }
                if liveViewEnabled, snapshot.connected, let frame, let image = NSImage(data: frame) {
                    liveImage = image
                    lastFrameDate = Date()
                }
                pollInFlight = false
            }
        }
    }

    func scan() { perform(["action": "scan"], activity: "正在搜索 USB / 网络相机…") }
    func connect() {
        guard selectedCamera >= 0 else { return }
        perform(["action": "connect", "index": selectedCamera, "user": username, "password": password, "fingerprint": fingerprint], activity: "正在连接相机…") { [weak self] in
            guard let self else { return }
            self.password = ""
            if self.snapshot.connected { self.liveViewEnabled = true }
        }
    }
    func disconnect() {
        liveViewEnabled = false
        perform(["action": "disconnect"], activity: "正在断开相机…")
    }
    func setProperty(_ property: CameraProperty, value: String) {
        guard canConfigure, value != property.value else { return }
        perform(["action": "set_property", "code": property.code, "value": value], activity: "正在设置\(property.name)…")
    }
    func shoot() { perform(["action": "shoot"], activity: "正在触发拍照…") }
    func autofocus() { perform(["action": "autofocus"], activity: "正在自动对焦…") }
    func startBurst() {
        guard canStartBurst else { return }
        perform(["action": "burst_start", "mode": selectedBurstMode, "duration": burstDuration], activity: "正在对焦并启动连拍…")
    }
    func stopBurst() {
        guard burstActive else { return }
        perform(["action": "burst_stop"], activity: "正在停止连拍…")
    }
    func enableManualFocus() {
        guard let property = snapshot.properties.first(where: { $0.code == 265 }),
              property.writable, property.options.contains(where: { $0.value == "1" }) else {
            notice = "当前相机或镜头不允许从软件切换 MF。"
            noticeIsError = true
            return
        }
        setProperty(property, value: "1")
    }
    func moveFocus(near: Bool) {
        guard canConfigure, manualFocus.isMF, manualFocus.stepEnabled,
              manualFocus.steps.contains(focusStep) else { return }
        perform(["action": "focus_step", "step": near ? -focusStep : focusStep], activity: near ? "正在向近处调焦…" : "正在向远处调焦…")
    }
    func setFocusPosition() {
        guard canSetFocusPosition, let value = Int(focusPositionInput) else { return }
        perform(["action": "focus_position", "value": value], activity: "正在设置对焦位置…")
    }
    func cancelFocus() {
        perform(["action": "focus_cancel"], activity: "正在停止对焦移动…")
    }
    func startMovie() {
        guard canConfigure, freshLiveView, !localRecording, !finishingVideo else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = URL(fileURLWithPath: saveDirectory).appendingPathComponent("LR1_Preview_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mov")
        videoRecorder.start(at: url) { [weak self] _ in self?.stopMovie() }
        recordingStartedAt = Date()
        recordingSeconds = 0
        localRecording = true
        notice = "正在将取景画面录制到 Mac"
        noticeIsError = false
    }
    func stopMovie(completion: ((Bool) -> Void)? = nil) {
        guard localRecording else { completion?(true); return }
        localRecording = false
        recordingStartedAt = nil
        finishingVideo = true
        videoRecorder.finish { [weak self] result in
            guard let self else { return }
            self.finishingVideo = false
            switch result {
            case .success(let url):
                self.lastVideo = url
                self.notice = "视频已保存：\(url.lastPathComponent)"
                self.noticeIsError = false
                completion?(true)
            case .failure(let error):
                self.notice = error.localizedDescription
                self.noticeIsError = true
                completion?(false)
            }
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择照片保存位置"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["action": "set_save_directory", "path": url.path], activity: "正在更新保存位置…") { [weak self] in
            guard let self, self.snapshot.ok else { return }
            UserDefaults.standard.set(self.saveDirectory, forKey: "photoDirectory")
        }
    }

    func openDirectory() { NSWorkspace.shared.open(URL(fileURLWithPath: saveDirectory)) }
    func reveal(_ photo: DownloadedPhoto) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.path)])
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.title = "导出运行日志"
        panel.nameFieldStringValue = "LR1-Control.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = snapshot.logs.map { "\($0.time) [\($0.level)] \($0.message)" }.joined(separator: "\n") + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notice = "日志保存失败：\(error.localizedDescription)"
            noticeIsError = true
        }
    }

    func shutdown(completion: @escaping (Bool) -> Void) {
        guard !shuttingDown else { return }
        shuttingDown = true
        transport.queue.async { [self] in
            let result = transport.request(["action": "shutdown"])
            RunLoop.main.perform(inModes: [.common]) { [self] in
                MainActor.assumeIsolated {
                    accept(result, announce: true)
                    let success: Bool
                    if case .success(let state) = result { success = state.ok && !state.initialized }
                    else { success = false }
                    if success { timer?.invalidate(); timer = nil }
                    else { shuttingDown = false }
                    completion(success)
                }
            }
        }
    }
}
