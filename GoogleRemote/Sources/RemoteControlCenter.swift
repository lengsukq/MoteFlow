import AppKit
import SwiftUI

private enum RemotePage: String, CaseIterable, Identifiable {
    case remote = "遥控器"
    case actionLibrary = "动作库"
    case voice = "语音"
    case diagnostics = "诊断"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .remote: "appletvremote.gen4"
        case .actionLibrary: "square.stack.3d.up"
        case .voice: "waveform"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }

    var description: String {
        switch self {
        case .remote: "权限引导、实时按键测试与遥控器配置"
        case .actionLibrary: "统一管理脚本、快捷键和多步骤动作"
        case .voice: "采集语音并在本机转写"
        case .diagnostics: "设备状态、原始 HID 数据与协议日志"
        case .settings: "运行选项、HID 高级学习与映射导出"
        }
    }
}

private struct RemoteModelSwitcher: View {
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var monitor: HIDCaptureManager
    let onSwitch: (RemoteDeviceModel) -> Void

    private var hardwareModel: RemoteDeviceModel? {
        guard let device = monitor.currentDeviceIdentity else { return nil }
        return RemoteDeviceProfileRegistry.identify(
            vendorID: device.vendorID, productID: device.productID,
            productName: device.productName
        )
    }

    var body: some View {
        RemoteCard(padding: 12) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("遥控器预设", systemImage: "appletvremote.gen4")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(hardwareModel == nil ? "未识别实体设备 · 可先预览" :
                            "已识别实体：\(hardwareModel?.name ?? "")")
                        .font(.system(size: 10))
                        .foregroundStyle(hardwareModel == nil ? .secondary : RemotePalette.positive)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    ForEach(RemoteDeviceProfileRegistry.builtIn) { model in
                        RemoteVisualOption(
                            title: model.name,
                            subtitle: model.modelLabel + (hardwareModel == model ? " · 已识别" : ""),
                            symbol: model == .googleG9N9N ? "appletvremote.gen4" :
                                model == .generic ? "keyboard" : "dot.radiowaves.left.and.right",
                            selected: store.activeModel == model,
                            compact: true,
                            action: { onSwitch(model) }
                        )
                    }
                }
                if let hardwareModel, hardwareModel != store.activeModel {
                    Label("当前展示的预设不是实际连接的设备：为避免误触，实体按键动作将暂停执行。",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(RemotePalette.amber)
                } else if store.activeModel == .xiaomiRemote2 || store.activeModel == .xiaomiRemote2Pro {
                    Label("小米按键图、默认快捷键已初始化；实机 HID 码及麦克风通道仍需测试。",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum RemoteWorkspaceSection: String, CaseIterable, Identifiable {
    case test
    case mapping
    case connection
    var id: String { rawValue }

    var title: String {
        switch self {
        case .test: "按键测试"
        case .mapping: "按键配置"
        case .connection: "连接设备"
        }
    }

    var detail: String {
        switch self {
        case .test: "高亮与实体反馈"
        case .mapping: "快捷键与动作"
        case .connection: "蓝牙与系统 HID"
        }
    }

    var symbol: String {
        switch self {
        case .test: "cursorarrow.rays"
        case .mapping: "keyboard"
        case .connection: "dot.radiowaves.left.and.right"
        }
    }
}

private enum RemoteDiagnosticSection: String, CaseIterable, Identifiable {
    case hid
    case connection
    var id: String { rawValue }
    var title: String { self == .hid ? "按键识别" : "蓝牙与日志" }
}

private struct RemoteWorkspaceToolbar: View {
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var bluetooth: RemoteBluetoothManager
    let configuredCount: Int
    let learnedCount: Int
    @Binding var section: RemoteWorkspaceSection
    let onDiagnostics: () -> Void

    var body: some View {
        RemoteCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                workspaceSwitcher
                HStack(spacing: 12) {
                    Label("\(learnedCount) 个 HID 码", systemImage: "checkmark.circle")
                    Label("\(configuredCount) 个按键已配置", systemImage: "slider.horizontal.3")
                    Spacer(minLength: 6)
                    Button("打开诊断", systemImage: "stethoscope", action: onDiagnostics)
                        .buttonStyle(RemoteActionButtonStyle())
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var workspaceSwitcher: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 9)], spacing: 9) {
            ForEach(RemoteWorkspaceSection.allCases) { item in
                RemoteVisualOption(
                    title: item.title, subtitle: item.detail,
                    symbol: item.symbol, selected: section == item,
                    compact: true, action: { section = item }
                )
            }
        }
        .accessibilityLabel("遥控器工作流程")
    }
}

struct ContentView: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var transcriber = NativeVoiceTranscriber()
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var actionRunner: RemoteActionRunner
    @EnvironmentObject private var runtime: RemoteAppRuntime
    @State private var selectedMappingKey: RemoteKey = .assistant
    @State private var selection: RemotePage? = .remote
    @State private var remoteSection: RemoteWorkspaceSection = .test
    @State private var voiceSection: RemoteVoiceSection = .live
    @State private var diagnosticSection: RemoteDiagnosticSection = .hid
    @State private var fileError: String?

    private func sidebarItem(_ page: RemotePage) -> some View {
        Label(page.rawValue, systemImage: page.symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 7)
            .tag(page)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image("MoteFlowMark")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MoteFlow")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .tracking(0.15)
                        Text("遥控 · 语音 · 自动化")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 25)
                .padding(.bottom, 22)

                List(selection: $selection) {
                    Section("设备与使用") {
                        sidebarItem(.remote)
                        sidebarItem(.voice)
                    }
                    Section("自动化") {
                        sidebarItem(.actionLibrary)
                    }
                    Section("系统与维护") {
                        sidebarItem(.settings)
                        sidebarItem(.diagnostics)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: 10) {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                    Label(hidCapture.isExclusive ? "实体按键已就绪" :
                          hidCapture.autoSeizeEnabled ? "等待遥控器连接" : "自动拦截已暂停",
                          systemImage: hidCapture.isExclusive ? "checkmark.shield.fill" : "circle.dotted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hidCapture.isExclusive ? RemotePalette.positive : .secondary)
                    Label(bluetooth.connectedDeviceID != nil ? "语音蓝牙已连接" :
                          bluetooth.isBluetoothReady ? "语音蓝牙未连接" : "蓝牙未开启",
                          systemImage: bluetooth.connectedDeviceID != nil ?
                          "waveform.circle.fill" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(bluetooth.connectedDeviceID != nil ? RemotePalette.positive : .secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .frame(minWidth: 210)
            .background(.ultraThinMaterial)
            .navigationSplitViewColumnWidth(min: 198, ideal: 222, max: 262)
        } detail: {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        topHeader
                        currentPage
                            .id(selection)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 9)))
                    }
                    .frame(maxWidth: 1150)
                    .padding(.horizontal, 23)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: selection)
            }
            .navigationTitle(selection?.rawValue ?? RemotePage.remote.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        runtime.enterLightweightMode()
                    } label: {
                        Label("收起到菜单栏", systemImage: "menubar.rectangle")
                    }
                    .help("进入轻量模式：隐藏主窗口，继续监听遥控器。可从菜单栏重新打开。")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        bluetooth.toggleScan()
                        if bluetooth.isScanning {
                            selection = .remote
                            remoteSection = .connection
                        }
                    } label: {
                        Label(bluetooth.isScanning ? "停止扫描" : "扫描蓝牙设备",
                              systemImage: bluetooth.isScanning ? "stop.circle" : "arrow.clockwise")
                    }
                    .disabled(!bluetooth.isBluetoothReady)
                    .help(bluetooth.isScanning ? "停止 BLE 扫描" : "开始扫描周围的 BLE 设备")
                }
            }
        }
        .tint(RemotePalette.indigo)
        .onAppear {
            runtime.startKeepingRemoteAlive(hidCapture, runner: actionRunner, bluetooth: bluetooth)
            // ATVV is the voice key's *separate* BLE control channel. Keep its
            // hardware feedback wired independently of which page is visible.
            bluetooth.onATVVControlReport = { [weak hidCapture] payload in
                hidCapture?.recordATVVControl(payload)
            }
            bluetooth.onATVVAudioEnded = { [weak hidCapture] in
                hidCapture?.endATVVVoiceSession()
            }
            hidCapture.onVoiceSessionStart = { [weak bluetooth, weak mappingStore, weak actionLibrary, weak actionRunner] in
                guard let mappingStore, let actionLibrary, let actionRunner else { return }
                // Set the input before triggering Doubao's listening hotkey.
                bluetooth?.virtualMicrophone.prepareVoiceInputWindow()
                // A configured assistant LONG PRESS with a single keyboard
                // step uses the duration of the ATVV session, not a timer.
                let holdAction = mappingStore.action(for: .assistant, gesture: .longPress)
                let steps = actionLibrary.steps(for: holdAction)
                if steps?.count == 1,
                   let step = steps?.first,
                   step.kind == .keyboard,
                   let shortcut = step.shortcut {
                    switch hidCapture.doubaoShortcutTrigger {
                    case .tap: actionRunner.tapVoiceShortcut(shortcut)
                    case .hold: actionRunner.beginVoiceShortcutHold(shortcut)
                    }
                } else {
                    let tapAction = mappingStore.action(for: .assistant, gesture: .tap)
                    guard tapAction.kind != .none && tapAction.kind != .voiceInput else { return }
                    actionRunner.test(action: tapAction, label: "实体语音助手 · ATVV",
                                      library: actionLibrary)
                }
            }
            hidCapture.onVoiceSessionEnd = { [weak bluetooth, weak actionRunner] in
                actionRunner?.endVoiceShortcutHold()
                bluetooth?.stopCurrentVoiceSession()
                bluetooth?.virtualMicrophone.finishVoiceInputWindow()
            }
            hidCapture.longPressThresholdForKey = { [weak mappingStore] key in
                mappingStore?.binding(for: key).effectiveThreshold ?? 0.65
            }
            hidCapture.onMappedGesture = { [weak mappingStore, weak actionLibrary, weak actionRunner, weak hidCapture] key, gesture in
                guard let mappingStore, let actionLibrary, let actionRunner,
                      let device = hidCapture?.currentDeviceIdentity,
                      let model = RemoteDeviceProfileRegistry.identify(
                        vendorID: device.vendorID, productID: device.productID,
                        productName: device.productName
                      ), model == mappingStore.activeModel,
                      model.keys.contains(key) else { return }
                let action = mappingStore.action(for: key, gesture: gesture)
                guard action.kind != .none && action.kind != .voiceInput else { return }
                actionRunner.test(action: action, label: "实体\(key.title) · \(gesture.title)", library: actionLibrary)
            }
            hidCapture.tryAutomaticCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hidCapture.tryAutomaticCapture()
        }
        .onChange(of: hidCapture.executeHardwareActions) { _, enabled in
            if !enabled { actionRunner.endVoiceShortcutHold() }
        }
        .onChange(of: hidCapture.currentDeviceIdentity) { _, device in
            guard let device,
                  let model = RemoteDeviceProfileRegistry.identify(
                    vendorID: device.vendorID, productID: device.productID,
                    productName: device.productName
                  ) else { return }
            mappingStore.selectModel(model)
            if !model.keys.contains(selectedMappingKey) { selectedMappingKey = .up }
        }
        .alert("操作失败", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("确定") { fileError = nil }
        } message: {
            Text(fileError ?? "未知错误")
        }
    }

    private var topHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(selection?.rawValue ?? "遥控器")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                Text(selection?.description ?? "连接并配置实体遥控器")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if hidCapture.executeHardwareActions {
                RemoteStatusPill(title: "动作执行中已启用", symbol: "bolt.fill", tint: RemotePalette.amber)
            }
            RemoteStatusPill(
                title: hidCapture.isExclusive ? "遥控器 HID 已拦截" :
                    bluetooth.connectedDeviceID == nil ? "等待设备" : "BLE 已连接（非 HID）",
                symbol: hidCapture.isExclusive ? "lock.shield.fill" :
                    bluetooth.connectedDeviceID == nil ? "circle.dotted" : "checkmark.circle.fill",
                tint: hidCapture.isExclusive ? RemotePalette.positive :
                    bluetooth.connectedDeviceID == nil ? RemotePalette.amber : RemotePalette.indigo
            )
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch selection ?? .remote {
        case .remote:
            VStack(alignment: .leading, spacing: 16) {
                RemoteWorkspaceToolbar(
                    monitor: hidCapture,
                    bluetooth: bluetooth,
                    configuredCount: mappingStore.configuredCount,
                    learnedCount: hidCapture.learnedCodes.count,
                    section: $remoteSection,
                    onDiagnostics: {
                        selection = .diagnostics
                        diagnosticSection = .hid
                    }
                )
                RemoteModelSwitcher(store: mappingStore, monitor: hidCapture) { model in
                    mappingStore.selectModel(model)
                    if !model.keys.contains(selectedMappingKey) { selectedMappingKey = .up }
                }
                if remoteSection == .test {
                    RemoteTestPage(
                        monitor: hidCapture,
                        store: mappingStore,
                        bluetooth: bluetooth,
                        selected: $selectedMappingKey,
                        onConfigure: { remoteSection = .mapping },
                        onConnect: { remoteSection = .connection },
                        onDiagnose: {
                            selection = .diagnostics
                            diagnosticSection = hidCapture.advancedLearningEnabled ? .hid : .connection
                        }
                    )
                } else if remoteSection == .mapping {
                    RemoteMappingPage(store: mappingStore, library: actionLibrary, monitor: hidCapture,
                                      selected: $selectedMappingKey,
                                      onOpenLibrary: { selection = .actionLibrary })
                } else {
                    RemoteOverviewPage(
                        onOpenDiagnostics: {
                            selection = .diagnostics
                            diagnosticSection = .connection
                        }
                    )
                }
            }
        case .actionLibrary:
            RemoteActionLibraryPage(library: actionLibrary)
        case .voice:
            RemoteVoicePage(
                transcriber: transcriber,
                onImport: importWave,
                onExport: exportWave,
                onOpenConnection: {
                    selection = .remote
                    remoteSection = .connection
                },
                onOpenVoiceBinding: {
                    selectedMappingKey = .assistant
                    remoteSection = .mapping
                    selection = .remote
                },
                onOpenSettings: { selection = .settings },
                section: $voiceSection
            )
        case .diagnostics:
            VStack(alignment: .leading, spacing: 16) {
                RemoteCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("硬件与协议诊断")
                                .font(.system(size: 16, weight: .semibold))
                            Text("仅在排障或重新学习硬件码时使用")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("诊断分类", selection: $diagnosticSection) {
                            ForEach(RemoteDiagnosticSection.allCases.filter {
                                $0 != .hid || hidCapture.advancedLearningEnabled
                            }) { section in
                                Text(section.title).tag(section)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 290)
                    }
                }
                if diagnosticSection == .hid && hidCapture.advancedLearningEnabled {
                    RemoteKeyLabPage(monitor: hidCapture, selectedMappingKey: $selectedMappingKey)
                } else {
                    RemoteDiagnosticsPage()
                }
            }
        case .settings:
            RemoteSettingsPage(
                monitor: hidCapture,
                runtime: runtime,
                onOpenLearning: {
                    diagnosticSection = .hid
                    selection = .diagnostics
                },
                onOpenVoiceSetup: {
                    voiceSection = .devices
                    selection = .voice
                }
            )
        }
    }

    private func exportWave() {
        guard let data = bluetooth.waveFileData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GoogleRemote-voice.wav"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { fileError = error.localizedDescription }
        }
    }

    private func importWave() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "导入本地录音"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "wav" else {
                fileError = "仅支持 WAV 音频文件。"
                return
            }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 60_000_000 else {
                    fileError = "请选择不超过 60 MB 的录音文件。"
                    return
                }
                transcriber.recognize(waveData: try Data(contentsOf: url))
            } catch {
                fileError = error.localizedDescription
            }
        }
    }
}
