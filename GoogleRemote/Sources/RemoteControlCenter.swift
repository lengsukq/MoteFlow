import AppKit
import SwiftUI

enum RemotePage: String, CaseIterable, Identifiable {
    case remote = "遥控器"
    case dualMac = "双机互联"
    case permissions = "权限引导"
    case voice = "语音输入"
    case actionLibrary = "动作库"
    case settings = "运行设置"
    case diagnostics = "硬件诊断"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .remote: "appletvremote.gen4"
        case .dualMac: "macbook.and.ipad"
        case .permissions: "checkmark.shield"
        case .voice: "waveform"
        case .actionLibrary: "square.stack.3d.up"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }

    var description: String {
        switch self {
        case .remote: "直观测试按键、一键修改单击与长按功能、管理蓝牙连接"
        case .dualMac: "已配对 Mac 自动连接、一键合并或覆盖同步配置、切换本机/远程映射跟随"
        case .permissions: "一页看清所有已添加与未添加的系统权限，一键授权或定位到对应设置项"
        case .voice: "将遥控器麦克风语音实时送入豆包或在本机转写为文字"
        case .actionLibrary: "组合打开应用、发送快捷键、延时与脚本的可复用多步动作"
        case .settings: "设置开机后自动匹配、菜单栏后台轻量模式与备份导出"
        case .diagnostics: "查看底层 HID 报文、蓝牙服务与局域网诊断信息"
        }
    }
}

enum RemoteWorkspaceSection: String, CaseIterable, Identifiable {
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
        case .test: "试按与状态"
        case .mapping: "改键与预设"
        case .connection: "蓝牙与配对"
        }
    }

    var symbol: String {
        switch self {
        case .test: "cursorarrow.rays"
        case .mapping: "slider.horizontal.3"
        case .connection: "dot.radiowaves.left.and.right"
        }
    }
}

private enum RemoteDiagnosticSection: String, CaseIterable, Identifiable {
    case hid
    case connection

    var id: String { rawValue }
    var title: String { self == .hid ? "按键学习与采样" : "蓝牙与系统日志" }
}

/// Compact single-card workbench bar replacing the previous multi-card stack so
/// the interactive remote illustration stays visible above the fold.
private struct RemoteWorkbenchHeaderBar: View {
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var monitor: HIDCaptureManager
    @Binding var section: RemoteWorkspaceSection
    let onSwitchModel: (RemoteDeviceModel) -> Void

    private var hardwareModel: RemoteDeviceModel? {
        guard let device = monitor.currentDeviceIdentity else { return nil }
        return RemoteDeviceProfileRegistry.identify(
            vendorID: device.vendorID,
            productID: device.productID,
            productName: device.productName
        )
    }

    var body: some View {
        RemoteCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        sectionButtons
                        Spacer(minLength: 8)
                        modelPickerControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        sectionButtons
                        HStack {
                            modelPickerControls
                            Spacer()
                        }
                    }
                }

                if let hardwareModel, hardwareModel != store.activeModel {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(RemotePalette.amber)
                        Text("当前预览型号（\(store.activeModel.name)）与实际连接的遥控器（\(hardwareModel.name)）不一致，实体动作已自动暂停以防误触。")
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.amber)
                        Spacer(minLength: 6)
                        Button("切回真机型号") {
                            onSwitchModel(hardwareModel)
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                    }
                }
            }
        }
    }

    private var sectionButtons: some View {
        HStack(spacing: 8) {
            ForEach(RemoteWorkspaceSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .foregroundStyle(section == item ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(section == item ? RemotePalette.indigo : Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("遥控器工作区切换")
    }

    private var modelPickerControls: some View {
        HStack(spacing: 10) {
            Text("已设 \(store.configuredCount)/\(store.activeModel.keys.count) 键")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            Menu {
                ForEach(RemoteDeviceProfileRegistry.builtIn) { model in
                    Button {
                        onSwitchModel(model)
                    } label: {
                        let suffix = (hardwareModel == model) ? "（已连接真机）" : ""
                        if store.activeModel == model {
                            Label(model.name + suffix, systemImage: "checkmark")
                        } else {
                            Text(model.name + suffix)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "appletvremote.gen4")
                    Text(store.activeModel.name)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var actionRunner: RemoteActionRunner
    @EnvironmentObject private var runtime: RemoteAppRuntime
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var transcriber = NativeVoiceTranscriber()
    @StateObject private var permissionCenter = RemotePermissionCenter()
    @State private var coordinator = RemoteSessionCoordinator()
    @AppStorage("MoteFlow.hideQuickStartGuide.v1") private var hideQuickStartGuide = false

    @State private var selectedMappingKey: RemoteKey = .select
    @State private var selection: RemotePage? = .remote
    @State private var remoteSection: RemoteWorkspaceSection = .test
    @State private var voiceSection: RemoteVoiceSection = .live
    @State private var settingsSection: RemoteSettingsSection = .daily
    @State private var diagnosticSection: RemoteDiagnosticSection = .connection
    @State private var fileError: String?

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .tint(RemotePalette.indigo)
        .onAppear {
            coordinator.bindIfNeeded(
                bluetooth: bluetooth,
                hidCapture: hidCapture,
                mappingStore: mappingStore,
                actionLibrary: actionLibrary,
                actionRunner: actionRunner,
                runtime: runtime,
                lanRelay: lanRelay,
                transcriber: transcriber
            )
            permissionCenter.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hidCapture.tryAutomaticCapture()
            permissionCenter.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
        }
        .onChange(of: hidCapture.executeHardwareActions) { _, enabled in
            if !enabled {
                actionRunner.cancelPendingMappedActions()
                actionRunner.endVoiceShortcutHold()
                actionRunner.endMappedShortcutHold()
            }
        }
        .onChange(of: hidCapture.isCapturing) { _, capturing in
            if !capturing {
                actionRunner.cancelPendingMappedActions()
                actionRunner.endMappedShortcutHold()
            }
        }
        .onChange(of: hidCapture.currentDeviceIdentity) { _, device in
            guard let device,
                  let model = RemoteDeviceProfileRegistry.identify(
                    vendorID: device.vendorID,
                    productID: device.productID,
                    productName: device.productName
                  ) else { return }
            mappingStore.selectModel(model)
            if !model.keys.contains(selectedMappingKey) {
                selectedMappingKey = .select
            }
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

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("MoteFlowMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MoteFlow")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("遥控 · 语音 · 双机联动")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)

            List(selection: $selection) {
                Section("日常控制") {
                    sidebarRow(.remote)
                    sidebarDualMacRow
                    sidebarPermissionsRow
                    sidebarRow(.voice)
                }
                Section("进阶与维护") {
                    sidebarRow(.actionLibrary)
                    sidebarRow(.settings)
                    sidebarRow(.diagnostics)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            sidebarStatusFooter
        }
        .frame(minWidth: 214)
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 204, ideal: 226, max: 264)
    }

    private func sidebarRow(_ page: RemotePage) -> some View {
        Label(page.rawValue, systemImage: page.symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 5)
            .tag(page)
    }

    private var sidebarDualMacRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.dualMac.rawValue, systemImage: RemotePage.dualMac.symbol)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            if lanRelay.incomingPairingRequest != nil {
                Circle()
                    .fill(RemotePalette.amber)
                    .frame(width: 8, height: 8)
            } else if lanRelay.isForwardingToRemoteMac {
                Text("远端")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RemotePalette.turquoise, in: Capsule())
            } else if lanRelay.isConnected {
                Circle()
                    .fill(RemotePalette.positive)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 5)
        .tag(RemotePage.dualMac)
    }

    private var sidebarPermissionsRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.permissions.rawValue, systemImage: RemotePage.permissions.symbol)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            if permissionCenter.missingCoreCount > 0 {
                Text("缺 \(permissionCenter.missingCoreCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RemotePalette.amber, in: Capsule())
            } else if !permissionCenter.snapshots.isEmpty {
                Circle()
                    .fill(RemotePalette.positive)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 5)
        .tag(RemotePage.permissions)
    }

    private var sidebarStatusFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)

            Label(
                hidCapture.isExclusive
                    ? (hidCapture.executeHardwareActions ? "遥控器已就绪 · 动作生效中" : "遥控器已连接 · 仅预览")
                    : (hidCapture.autoSeizeEnabled ? "等待遥控器连接" : "自动接管已暂停"),
                systemImage: hidCapture.isExclusive ? "checkmark.shield.fill" : "circle.dotted"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
                hidCapture.isExclusive
                    ? (hidCapture.executeHardwareActions ? RemotePalette.positive : RemotePalette.amber)
                    : .secondary
            )

            Label(
                lanRelay.isForwardingToRemoteMac
                    ? "正在控制：\(lanRelay.connectedPeerName ?? "远端 Mac")"
                    : (lanRelay.isConnected ? "双机已连 · 当前控制本机" : "双机互联：本机独立模式"),
                systemImage: lanRelay.isForwardingToRemoteMac ? "macbook.and.ipad" : "desktopcomputer"
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(lanRelay.isForwardingToRemoteMac ? RemotePalette.turquoise : .secondary)
            .lineLimit(1)

            Button {
                runtime.enterLightweightMode()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "menubar.arrow.up.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("进入轻量模式（收起到菜单栏）")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(RemotePalette.indigo)
            }
            .buttonStyle(.plain)
            .help("隐藏主窗口与 Dock 图标，仅保留右上角菜单栏小图标后台运行")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 15)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    topHeader
                    if let pairing = lanRelay.incomingPairingRequest, selection != .dualMac {
                        globalPairingAlertStrip(pairing)
                    }
                    currentPage
                        .id(selection)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 7)))
                }
                .frame(maxWidth: 1150)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selection)
        }
        .navigationTitle(selection?.rawValue ?? RemotePage.remote.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = .permissions
                } label: {
                    Label("权限引导", systemImage: "checkmark.shield")
                }
                .help("一页查看已添加与未添加的系统权限")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    hideQuickStartGuide = false
                    selection = .remote
                } label: {
                    Label("新手引导", systemImage: "questionmark.circle")
                }
                .help("展开 3 步快速上手向导")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    runtime.enterLightweightMode()
                } label: {
                    Label("轻量模式", systemImage: "menubar.arrow.up.rectangle")
                }
                .help("快速进入轻量模式：隐藏主窗口与 Dock 图标到右上角菜单栏")
            }
        }
    }

    private func globalPairingAlertStrip(_ request: RemoteIncomingPairingRequest) -> some View {
        RemoteCard(padding: 13) {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(RemotePalette.indigo)
                    .font(.system(size: 18, weight: .semibold))
                Text("「\(request.peerName)」请求局域网双机配对（核对码：\(request.verificationCode)）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("拒绝") { lanRelay.rejectIncomingPairing() }
                    .buttonStyle(RemoteActionButtonStyle())
                Button("确认配对") { lanRelay.approveIncomingPairing() }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    private var topHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selection?.rawValue ?? "遥控器")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text(selection?.description ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)

            if lanRelay.isConnected {
                Button {
                    lanRelay.toggleTarget(showHUD: true)
                } label: {
                    RemoteStatusPill(
                        title: lanRelay.isForwardingToRemoteMac
                            ? "正在转发：\(lanRelay.connectedPeerName ?? "远端 Mac") ⇄"
                            : "控制本机 ⇄ 切至远端",
                        symbol: lanRelay.isForwardingToRemoteMac ? "macbook.and.ipad" : "desktopcomputer",
                        tint: lanRelay.isForwardingToRemoteMac ? RemotePalette.turquoise : RemotePalette.indigo
                    )
                }
                .buttonStyle(.plain)
                .help("点击或按 \(lanRelay.switchShortcut.display) 切换控制哪台 Mac")
            }

            Button {
                hidCapture.executeHardwareActions.toggle()
            } label: {
                RemoteStatusPill(
                    title: hidCapture.executeHardwareActions ? "动作生效中" : "仅预览（点击开启生效）",
                    symbol: hidCapture.executeHardwareActions ? "bolt.fill" : "pause.circle",
                    tint: hidCapture.executeHardwareActions ? RemotePalette.positive : RemotePalette.amber
                )
            }
            .buttonStyle(.plain)
            .help("切换是否允许实体遥控器按键真实执行动作")

            RemoteStatusPill(
                title: hidCapture.isExclusive ? "遥控器已接管" :
                    (bluetooth.connectedDeviceID != nil ? "仅语音蓝牙已连" : "等待遥控器"),
                symbol: hidCapture.isExclusive ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right",
                tint: hidCapture.isExclusive ? RemotePalette.positive : RemotePalette.indigo
            )

            Button {
                runtime.enterLightweightMode()
            } label: {
                Label("轻量模式", systemImage: "menubar.arrow.up.rectangle")
            }
            .buttonStyle(RemoteActionButtonStyle())
            .help("快速进入轻量模式：收起到右上角菜单栏运行，不占桌面和程序坞")
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch selection ?? .remote {
        case .remote:
            VStack(alignment: .leading, spacing: 14) {
                if !hideQuickStartGuide {
                    RemoteQuickStartGuideCard(
                        monitor: hidCapture,
                        bluetooth: bluetooth,
                        configuredCount: mappingStore.configuredCount,
                        onOpenMapping: { remoteSection = .mapping },
                        onOpenDualMac: { selection = .dualMac },
                        onOpenPermissions: { selection = .permissions },
                        onDismiss: { hideQuickStartGuide = true }
                    )
                }

                if hidCapture.isExclusive && !hidCapture.executeHardwareActions && hideQuickStartGuide {
                    executionPausedBanner
                }

                RemoteWorkbenchHeaderBar(
                    store: mappingStore,
                    monitor: hidCapture,
                    section: $remoteSection
                ) { model in
                    mappingStore.selectModel(model)
                    if !model.keys.contains(selectedMappingKey) {
                        selectedMappingKey = .select
                    }
                }

                switch remoteSection {
                case .test:
                    RemoteTestPage(
                        monitor: hidCapture,
                        store: mappingStore,
                        library: actionLibrary,
                        bluetooth: bluetooth,
                        selected: $selectedMappingKey,
                        onConfigure: { remoteSection = .mapping },
                        onConnect: { remoteSection = .connection },
                        onOpenDualMac: { selection = .dualMac }
                    )
                case .mapping:
                    RemoteMappingPage(
                        store: mappingStore,
                        library: actionLibrary,
                        monitor: hidCapture,
                        selected: $selectedMappingKey,
                        onOpenLibrary: { selection = .actionLibrary }
                    )
                case .connection:
                    RemoteOverviewPage(
                        onOpenDiagnostics: {
                            selection = .diagnostics
                            diagnosticSection = .connection
                        },
                        onOpenDualMac: {
                            selection = .dualMac
                        }
                    )
                }
            }

        case .dualMac:
            RemoteDualMacPage(
                onOpenRemoteMapping: {
                    selectedMappingKey = .input
                    remoteSection = .mapping
                    selection = .remote
                },
                onOpenPermissions: {
                    selection = .permissions
                },
                onOpenBackupSettings: {
                    settingsSection = .backup
                    selection = .settings
                }
            )

        case .permissions:
            RemotePermissionsPage(
                permissionCenter: permissionCenter,
                onOpenVoiceDrivers: {
                    voiceSection = .devices
                    selection = .voice
                },
                onOpenDualMac: {
                    selection = .dualMac
                }
            )

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

        case .actionLibrary:
            RemoteActionLibraryPage(library: actionLibrary)

        case .settings:
            RemoteSettingsPage(
                monitor: hidCapture,
                runtime: runtime,
                section: $settingsSection,
                onOpenLearning: {
                    diagnosticSection = .hid
                    selection = .diagnostics
                },
                onOpenVoiceSetup: {
                    voiceSection = .devices
                    selection = .voice
                },
                onOpenDualMac: {
                    selection = .dualMac
                },
                onOpenPermissions: {
                    selection = .permissions
                },
                onReopenGuide: {
                    hideQuickStartGuide = false
                    selection = .remote
                }
            )

        case .diagnostics:
            VStack(alignment: .leading, spacing: 16) {
                if hidCapture.advancedLearningEnabled {
                    RemoteCard(padding: 12) {
                        HStack {
                            Text("诊断视图切换")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Picker("诊断分类", selection: $diagnosticSection) {
                                ForEach(RemoteDiagnosticSection.allCases) { section in
                                    Text(section.title).tag(section)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                    }
                }
                if diagnosticSection == .hid && hidCapture.advancedLearningEnabled {
                    RemoteKeyLabPage(monitor: hidCapture, selectedMappingKey: $selectedMappingKey)
                } else {
                    RemoteDiagnosticsPage()
                }
            }
        }
    }

    private var executionPausedBanner: some View {
        RemoteCard(padding: 13) {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(RemotePalette.amber)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("遥控器已连接，但「按键动作生效」当前处于关闭状态")
                        .font(.system(size: 13, weight: .semibold))
                    Text("当前按实体遥控器只会在界面上高亮提示；点击右侧按钮开启后即可真实控制电脑。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("立即开启按键生效") {
                    hidCapture.executeHardwareActions = true
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    // MARK: - Audio File Helpers

    private func exportWave() {
        guard let data = bluetooth.waveFileData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MoteFlow-voice.wav"
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
