import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = CameraModel.shared
        if model.burstActive {
            model.stopBurst()
            model.notice = "正在停止连拍，请等照片下载完成后退出。"
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if model.busy {
            model.notice = "请等待当前相机操作完成后退出。"
            return .terminateCancel
        }
        if model.manualFocus.moving {
            model.cancelFocus()
            model.notice = "正在停止调焦，请等待镜头停止后退出。"
            return .terminateCancel
        }
        if model.captureInProgress && !model.burstRecoverable {
            let alert = NSAlert()
            alert.messageText = "照片正在传回 Mac"
            alert.informativeText = "请等待下载完成后退出。"
            alert.runModal()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if model.finishingVideo {
            let alert = NSAlert()
            alert.messageText = "视频正在保存，请稍后退出。"
            alert.runModal()
            return .terminateCancel
        }
        if model.localRecording {
            let alert = NSAlert()
            alert.messageText = "正在本地录制"
            alert.informativeText = "退出前将完成并保存当前视频。"
            alert.addButton(withTitle: "保存并退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            model.stopMovie { success in
                if success { model.shutdown { NSApp.reply(toApplicationShouldTerminate: $0) } }
                else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    let failure = NSAlert()
                    failure.messageText = "视频未能保存"
                    failure.informativeText = model.notice
                    failure.runModal()
                }
            }
            return .terminateLater
        }
        model.shutdown { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
}

@main
struct LR1ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = CameraModel.shared

    var body: some Scene {
        Window("LR1 Control", id: "main") {
            ControlView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 740)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1220, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("连接与使用说明") { model.showHelp = true }
            }
        }
    }
}

private enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.085)
    static let panel = Color(red: 0.087, green: 0.102, blue: 0.125)
    static let line = Color.white.opacity(0.09)
    static let accent = Color(red: 0.36, green: 0.85, blue: 0.87)
    static let secondary = Color(red: 0.59, green: 0.64, blue: 0.70)
}

struct ControlView: View {
    @EnvironmentObject var model: CameraModel
    @State private var authenticationExpanded = false

    var body: some View {
        VStack(spacing: 20) {
            header
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: 16) {
                        connectionPanel
                        exposurePanel
                        manualFocusPanel
                    }
                }
                .frame(width: 300)
                ScrollView {
                    VStack(spacing: 16) {
                        liveViewPanel.frame(height: 340)
                        capturePanel
                        burstPanel
                        storagePanel
                    }
                }
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 18)
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $model.showLogs) { logSheet }
        .sheet(isPresented: $model.showHelp) { helpSheet }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Palette.accent.opacity(0.13))
                Image(systemName: "camera.aperture").font(.system(size: 27, weight: .light)).foregroundStyle(Palette.accent)
            }.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("LR1 CONTROL").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(2)
                Text("相机控制台").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.snapshot.connected ? Palette.accent : Palette.secondary).frame(width: 6, height: 6)
                Text(model.snapshot.connected ? model.snapshot.cameraName : "相机未连接")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(Palette.panel, in: Capsule())
            Button { model.showHelp = true } label: { Image(systemName: "questionmark.circle").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("连接与使用说明")
                .accessibilityLabel("连接与使用说明")
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("连接相机", icon: "cable.connector")
            VStack(alignment: .leading, spacing: 8) {
                Text("USB / 网络").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                if model.snapshot.cameras.isEmpty {
                    HStack {
                        Image(systemName: "camera").foregroundStyle(Palette.secondary)
                        Text(model.busy ? "正在查找相机…" : "暂未发现相机").font(.system(size: 13))
                        Spacer()
                    }.padding(12).background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Picker("相机", selection: $model.selectedCamera) {
                        ForEach(model.snapshot.cameras) { camera in
                            Text("\(camera.name) · \(camera.connection)").tag(camera.index)
                        }
                    }.labelsHidden().disabled(model.busy || model.snapshot.connected)
                }
            }
            HStack(spacing: 8) {
                Button(action: model.scan) { Label("搜索", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(QuietButton()).disabled(model.busy || model.snapshot.connected)
                Button(action: model.snapshot.connected ? model.disconnect : model.connect) {
                    Text(model.snapshot.connected ? "断开连接" : "连接相机").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButton())
                .disabled(model.busy || model.snapshot.connecting || (!model.snapshot.connected && model.selectedCamera < 0) || model.localRecording || model.finishingVideo || model.manualFocus.moving || (model.captureInProgress && !model.burstRecoverable))
            }
            DisclosureGroup("网络认证", isExpanded: $authenticationExpanded) {
                VStack(spacing: 8) {
                    TextField("相机用户名", text: $model.username)
                    SecureField("相机密码", text: $model.password)
                    TextField("相机指纹（从相机认证信息中获取）", text: $model.fingerprint)
                    Text("仅网络认证需要；按相机的访问认证信息填写。密码不保存。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }.textFieldStyle(.roundedBorder).padding(.top, 8).disabled(model.busy || model.snapshot.connected)
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
            if !model.snapshot.connected {
                Text("用 USB 数据线连接 LR1，并将相机 USB 连接模式设为 PC 遥控。无需存储卡。")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.panel()
    }

    private var exposurePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("拍摄参数", icon: "slider.horizontal.3")
            if model.snapshot.properties.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(["曝光模式", "快门速度", "光圈", "ISO", "白平衡"], id: \.self) { name in
                        HStack { Text(name); Spacer(); Text("—").foregroundStyle(Palette.secondary) }
                    }
                    Text(model.snapshot.connected ? "正在读取相机参数…" : "连接后读取相机支持的参数")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 3)
                }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                ForEach(model.snapshot.properties) { property in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(property.name).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        if property.writable && !property.options.isEmpty {
                            Picker(property.name, selection: Binding(get: { property.value }, set: { model.setProperty(property, value: $0) })) {
                                if !property.options.contains(where: { $0.value == property.value }) {
                                    Text(property.label).tag(property.value)
                                }
                                ForEach(property.options) { option in Text(option.label).tag(option.value) }
                            }.labelsHidden().disabled(!model.canConfigure)
                        } else {
                            Text(property.label).font(.system(size: 13, weight: .medium)).padding(.vertical, 3)
                        }
                    }
                }
            }
        }.panel()
    }

    private var liveViewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                sectionTitle("实时取景", icon: "viewfinder")
                Spacer()
                if model.localRecording {
                    Label("REC", systemImage: "record.circle.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                }
                Button {
                    model.liveViewEnabled.toggle()
                    if !model.liveViewEnabled { model.liveImage = nil; model.lastFrameDate = nil }
                } label: {
                    Label(model.liveViewEnabled ? "暂停取景" : "开启取景", systemImage: model.liveViewEnabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(!model.ready || model.localRecording)
            }.padding(.horizontal, 18).padding(.vertical, 15)
            ZStack {
                Color.black.opacity(0.42)
                if let image = model.liveImage, model.liveViewEnabled {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if !model.freshLiveView {
                        VStack { Spacer(); Text("画面暂未更新").font(.system(size: 12)).padding(8).background(.black.opacity(0.7), in: Capsule()).padding(14) }
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "viewfinder").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Palette.secondary.opacity(0.45))
                        VStack(spacing: 7) {
                            Text(model.snapshot.connected ? (model.liveViewEnabled ? "等待相机画面" : "取景已暂停") : "等待连接 LR1")
                                .font(.system(size: 16, weight: .medium))
                            Text(model.snapshot.connected ? "取景画面由相机实时传回" : "连接相机后，在这里查看实时画面")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                VStack { Spacer(); HStack {
                    Text(model.freshLiveView ? "LIVE VIEW" : "PREVIEW").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
                    Spacer()
                    if model.freshLiveView { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
                }.foregroundStyle(Palette.secondary).padding(14) }
            }
            .frame(minHeight: 270, maxHeight: .infinity)
        }
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        .frame(maxHeight: .infinity)
    }

    private var manualFocusPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("手动对焦", icon: "scope")
            if !model.snapshot.connected {
                Text("连接后读取镜头支持的调焦方式。")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                HStack {
                    Text(model.manualFocus.isMF ? "MF 手动对焦" : "当前为自动对焦")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    if !model.manualFocus.isMF {
                        Button("切换为 MF", action: model.enableManualFocus)
                            .buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(!model.canConfigure)
                    }
                }
                HStack {
                    Text("步进量").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Picker("对焦步进量", selection: $model.focusStep) {
                        if model.manualFocus.steps.isEmpty { Text("暂不可用").tag(1) }
                        ForEach(model.manualFocus.steps, id: \.self) { step in
                            Text(step == 1 ? "细 · 1" : step == 3 ? "中 · 3" : step == 7 ? "粗 · 7" : "\(step) 级").tag(step)
                        }
                    }.labelsHidden().disabled(!model.canConfigure || !model.manualFocus.isMF || !model.manualFocus.stepEnabled)
                }
                HStack(spacing: 8) {
                    Button { model.moveFocus(near: true) } label: { Label("近焦", systemImage: "minus.magnifyingglass").frame(maxWidth: .infinity) }
                        .buttonStyle(QuietButton())
                    Button { model.moveFocus(near: false) } label: { Label("远焦", systemImage: "plus.magnifyingglass").frame(maxWidth: .infinity) }
                        .buttonStyle(QuietButton())
                }.disabled(!model.canConfigure || !model.manualFocus.isMF || !model.manualFocus.stepEnabled)
                Divider().overlay(Palette.line)
                HStack {
                    Text("当前焦位").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(model.manualFocus.position.map(String.init) ?? "—")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 8) {
                    TextField("目标位置", text: $model.focusPositionInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canConfigure || !model.manualFocus.isMF || !model.manualFocus.positionEnabled)
                        .onSubmit { model.setFocusPosition() }
                    Button("应用", action: model.setFocusPosition)
                        .disabled(!model.canSetFocusPosition)
                }
                Text("位置为镜头归一化数值，范围 \(model.manualFocus.minimum)–\(model.manualFocus.maximum)，不是距离（米）。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if model.manualFocus.moving {
                    Button("停止调焦", action: model.cancelFocus)
                        .buttonStyle(QuietButton()).disabled(model.busy)
                }
                if !model.manualFocus.status.isEmpty {
                    Text(model.manualFocus.status).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.panel()
    }

    private var capturePanel: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("照片").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Button(action: model.shoot) { Label(model.singlePhotoPending ? (model.snapshot.captureConfirmed == true ? "正在传回照片…" : "等待相机拍摄…") : "拍摄照片", systemImage: "camera.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(AccentButton()).disabled(!model.canConfigure || model.snapshot.recording)
                    Button(action: model.autofocus) { Text("AF").frame(width: 30) }
                        .buttonStyle(QuietButton()).disabled(!model.canConfigure).help("触发自动对焦")
                        .accessibilityLabel("自动对焦")
                }
                Text("无卡拍摄 · 直接传回 Mac").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(Palette.line).frame(width: 1, height: 76)
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("视频").font(.system(size: 13, weight: .semibold)); Spacer(); Text(model.recordingStatus).font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                HStack(spacing: 8) {
                    Button(action: model.startMovie) { Label("开始", systemImage: "record.circle").frame(maxWidth: .infinity) }
                        .buttonStyle(QuietButton()).disabled(!model.canConfigure || !model.freshLiveView || model.localRecording || model.finishingVideo)
                    Button { model.stopMovie() } label: { Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(QuietButton()).disabled(!model.localRecording)
                }
                Text("取景画面 · 按取景分辨率保存至 Mac").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.frame(maxWidth: .infinity)
        }.panel()
    }

    private var burstPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("连拍", icon: "square.stack.3d.up.fill")
                Spacer()
                if model.burstActive {
                    Text(String(format: "连拍中 · %.1f 秒", model.snapshot.burstElapsed ?? 0))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.accent)
                } else if model.burstDraining {
                    Text("等待照片传回").font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连拍档位").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Picker("连拍档位", selection: $model.selectedBurstMode) {
                        if model.burstModes.isEmpty { Text("连接后读取").tag("") }
                        ForEach(model.burstModes) { Text($0.label).tag($0.value) }
                    }.labelsHidden().disabled(!model.canConfigure || model.burstModes.isEmpty)
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("自动停止时间").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Picker("自动停止时间", selection: $model.burstDuration) {
                        ForEach([0.5, 1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { seconds in
                            Text(String(format: "%g 秒", seconds)).tag(seconds)
                        }
                    }.labelsHidden().disabled(!model.canConfigure)
                }.frame(width: 105)
                Button(action: model.startBurst) { Label("开始连拍", systemImage: "camera.on.rectangle").frame(minWidth: 76) }
                    .buttonStyle(AccentButton()).disabled(!model.canStartBurst)
                Button(action: model.stopBurst) { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(QuietButton()).disabled(!model.burstActive || model.busy)
            }
            if let status = model.snapshot.burstStatus, !status.isEmpty {
                Text(status).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("到时自动停止，也可提前停止。照片直接传回 Mac，实际张数由相机决定。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if (model.snapshot.burstCaptured ?? 0) > 0 || (model.snapshot.burstFiles ?? 0) > 0 {
                Text("已收齐 \(model.snapshot.burstDownloaded ?? 0) 张照片 · 已下载 \(model.snapshot.burstFiles ?? 0) 个文件")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            if model.burstRecoverable {
                Button("结束等待并断开连接", action: model.disconnect)
                    .buttonStyle(QuietButton()).disabled(model.busy)
            }
        }.panel()
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地保存位置").font(.system(size: 12, weight: .medium))
                    Text(model.saveDirectory).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle).help(model.saveDirectory)
                }
                Spacer(minLength: 8)
                Button("更改…", action: model.chooseDirectory).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent).disabled(model.busy || model.captureInProgress || model.manualFocus.moving)
                Button(action: model.openDirectory) { Image(systemName: "arrow.up.forward.square").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("在 Finder 中打开").accessibilityLabel("打开照片文件夹")
            }
            if let last = model.snapshot.downloads.last {
                Divider().overlay(Palette.line)
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    Text(last.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("显示照片") { model.reveal(last) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.font(.system(size: 11))
            }
            if let video = model.lastVideo {
                HStack {
                    Image(systemName: "film").foregroundStyle(Palette.accent)
                    Text(video.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("显示视频") { NSWorkspace.shared.activateFileViewerSelecting([video]) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.font(.system(size: 11))
            }
        }.panel()
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if model.busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
            else { Image(systemName: model.noticeIsError ? "exclamationmark.circle" : "circle.fill").font(.system(size: model.noticeIsError ? 12 : 5)).foregroundStyle(model.noticeIsError ? .orange : Palette.secondary) }
            Text(model.busy ? model.activity : (!model.notice.isEmpty ? model.notice : "就绪"))
                .font(.system(size: 11)).foregroundStyle(model.noticeIsError && !model.busy ? .orange : Palette.secondary)
                .lineLimit(2).textSelection(.enabled)
            Spacer()
            Button { model.showLogs = true } label: { Label("运行日志", systemImage: "text.alignleft").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
            Text("SDK 2.02").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary.opacity(0.65)).padding(.leading, 12)
        }.frame(minHeight: 20)
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("运行日志").font(.title2.bold()); Spacer(); Button("导出…", action: model.exportLog); Button("完成") { model.showLogs = false }.keyboardShortcut(.defaultAction) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.snapshot.logs.isEmpty { Text("暂无日志").foregroundStyle(.secondary) }
                    ForEach(model.snapshot.logs) { log in
                        HStack(alignment: .top, spacing: 12) {
                            Text(log.time).foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
                            Text(log.message).foregroundStyle(log.level == "error" ? Color.orange : Color.primary)
                        }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 780, height: 470).background(Palette.background)
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("连接 LR1").font(.title2.bold()); Spacer(); Button("完成") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
            helpStep("01", "连接相机", "为 LR1 接好电源，使用可传输数据的 USB 线连接 Mac。相机菜单中的 USB 连接模式选择“PC 遥控”，关闭其他占用相机的遥控软件。")
            helpStep("02", "搜索并连接", "点击“搜索”，选择发现的 LR1 后连接。使用网络连接时，Mac 与相机应处于同一网络；如启用访问认证，请展开“网络认证”，填写相机菜单中显示的用户名、密码和指纹。")
            helpStep("03", "设置与拍摄", "参数列表由相机返回；当前模式不允许修改的参数仅显示读数。“AF”触发自动对焦，“拍摄照片”无卡拍摄一张，原始照片直接传到所选 Mac 文件夹；下载完成后显示文件名。")
            helpStep("04", "连拍", "选择相机支持的连拍档位和自动停止时间，点击“开始连拍”。可随时点击“停止”；停止拍摄后继续接收照片，RAW＋JPEG/HEIF 两个文件收齐才计为一张完整照片。下载完成后可继续单张拍摄。")
            Text("如果未发现设备，请检查相机供电、USB 模式及数据线；网络连接还需允许 macOS 本地网络访问。详细错误可在“运行日志”中查看。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(5)
        }.padding(28).frame(width: 600).background(Palette.background)
    }

    private func helpStep(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Palette.secondary); Text(title).font(.system(size: 13, weight: .semibold)) }
    }
}

private struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
}
private extension View { func panel() -> some View { modifier(PanelModifier()) } }

private struct AccentButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.vertical, 11).padding(.horizontal, 10)
            .foregroundStyle(enabled ? Palette.background : Palette.secondary.opacity(0.65))
            .background(enabled ? Palette.accent.opacity(configuration.isPressed ? 0.7 : 1) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
private struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.vertical, 11).padding(.horizontal, 10)
            .foregroundStyle(enabled ? Color.white.opacity(0.9) : Palette.secondary.opacity(0.45))
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
