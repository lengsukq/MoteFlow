import AppKit
import SwiftUI

/// Streamlined 4-destination primary navigation + 1 collapsible advanced drawer.
enum RemotePage: String, CaseIterable, Identifiable {
    case remote = "我的遥控器"
    case voice = "语音助手"
    case dualMac = "双机协同"
    case settings = "偏好与备份"
    case permissions = "系统权限体检"
    case diagnostics = "硬件与日志诊断"

    var id: String { rawValue }

    var isPrimaryDestination: Bool {
        switch self {
        case .remote, .voice, .dualMac, .settings: true
        case .permissions, .diagnostics: false
        }
    }

    var symbol: String {
        switch self {
        case .remote: "appletvremote.gen4"
        case .voice: "waveform"
        case .dualMac: "macbook.and.ipad"
        case .settings: "gearshape"
        case .permissions: "checkmark.shield"
        case .diagnostics: "wrench.and.screwdriver"
        }
    }

    var description: String {
        switch self {
        case .remote: "按手中实体键自动高亮选中，右侧即刻修改单击与长按功能并当场验证"
        case .voice: "一键接入豆包 AI 语音或开启免驱动离线语音打字，内置屏幕共享防回音静音"
        case .dualMac: "一个遥控器无缝控制两台 Mac，支持已配对自动重连与直观真机方案切换"
        case .settings: "管理自动接管生效、菜单栏轻量模式、本机历史快照与统一 JSON 全量备份"
        case .permissions: "集中检查 macOS 核心权限与按需扩展能力，支持一键请求或跳转系统设置"
        case .diagnostics: "统一查看按键 HID、蓝牙语音与双机网络日志，按需采样未知遥控器硬件码"
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
    @State private var voiceSection: RemoteVoiceSection = .live
    @State private var settingsSection: RemoteSettingsSection = .daily
    @State private var diagnosticLogFilter: RemoteDiagnosticLogFilter = .all
    @State private var showAdvancedSidebarGroup = false
    @State private var showingConnectionSheet = false
    @State private var showingActionLibrarySheet = false
    @State private var liveActionBannerText: String?
    @State private var liveBannerToken = UUID()
    @State private var fileError: String?

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .tint(RemotePalette.indigo)
        .onAppear {
            coordinator.onActionFeedback = { message, key in
                let token = UUID()
                liveBannerToken = token
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
                    liveActionBannerText = message
                    if let key { selectedMappingKey = key }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    guard liveBannerToken == token else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        liveActionBannerText = nil
                    }
                }
            }
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
        .sheet(isPresented: $showingConnectionSheet) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("蓝牙遥控器与连接通道")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("普通按键只需在 macOS 蓝牙里配对一次；下方用于扫描语音通道或双机引导")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { showingConnectionSheet = false }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }
                ScrollView {
                    RemoteOverviewPage(
                        onOpenDiagnostics: {
                            showingConnectionSheet = false
                            showAdvancedSidebarGroup = true
                            diagnosticLogFilter = .all
                            selection = .diagnostics
                        },
                        onOpenDualMac: {
                            showingConnectionSheet = false
                            selection = .dualMac
                        }
                    )
                }
            }
            .padding(20)
            .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 580)
        }
        .sheet(isPresented: $showingActionLibrarySheet) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("动作库与脚本组合器")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("支持快捷键、启动 App、延时与本地脚本（Bash / Zsh / Python），保存后即可绑定给「\(selectedMappingKey.title)」")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成并返回按键配置") { showingActionLibrarySheet = false }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }
                ScrollView {
                    RemoteActionLibraryPage(library: actionLibrary)
                }
            }
            .padding(20)
            .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 680)
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

    // MARK: - Streamlined Sidebar (4 Primary + 1 Collapsible Advanced Group)

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
                    Text("遥控 · 语音 · 双机协同")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 16)

            List(selection: $selection) {
                Section("核心工作台") {
                    sidebarRemoteRow
                    sidebarVoiceRow
                    sidebarDualMacRow
                    sidebarSettingsRow
                }

                Section {
                    DisclosureGroup(isExpanded: $showAdvancedSidebarGroup) {
                        sidebarPermissionsRow
                        sidebarRow(.diagnostics)
                    } label: {
                        HStack(spacing: 6) {
                            Label("高级调试与体检", systemImage: "wrench.and.screwdriver")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            if permissionCenter.missingCoreCount > 0 {
                                Circle()
                                    .fill(RemotePalette.amber)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
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

    private var sidebarRemoteRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.remote.rawValue, systemImage: RemotePage.remote.symbol)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            if hidCapture.isExclusive {
                Circle()
                    .fill(RemotePalette.positive)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 5)
        .tag(RemotePage.remote)
    }

    private var sidebarVoiceRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.voice.rawValue, systemImage: RemotePage.voice.symbol)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            if bluetooth.isRecording {
                Text("说话中")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RemotePalette.positive, in: Capsule())
            } else if bluetooth.virtualMicrophone.outputPointedToVirtualMic {
                Circle()
                    .fill(RemotePalette.amber)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 5)
        .tag(RemotePage.voice)
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
                Text("转发中")
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

    private var sidebarSettingsRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.settings.rawValue, systemImage: RemotePage.settings.symbol)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            if permissionCenter.missingCoreCount > 0 {
                Text("缺权限")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RemotePalette.amber, in: Capsule())
            }
        }
        .padding(.vertical, 5)
        .tag(RemotePage.settings)
    }

    private var sidebarPermissionsRow: some View {
        HStack(spacing: 6) {
            Label(RemotePage.permissions.rawValue, systemImage: RemotePage.permissions.symbol)
                .font(.system(size: 12.5, weight: .medium))
            Spacer(minLength: 4)
            if permissionCenter.missingCoreCount > 0 {
                Text("缺 \(permissionCenter.missingCoreCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RemotePalette.amber, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .tag(RemotePage.permissions)
    }

    private var sidebarStatusFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)

            Label(
                hidCapture.isExclusive
                    ? (hidCapture.executeHardwareActions ? "遥控器已就绪 · 按键生效中" : "遥控器已连 · 仅预览模式")
                    : (hidCapture.autoSeizeEnabled ? "等待唤醒或配对遥控器" : "遥控器接管已暂停"),
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
                    : (lanRelay.isConnected ? "双机已连 · 控制「\(lanRelay.localPeerName)」" : "单机模式 · \(lanRelay.localPeerName)"),
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
                    Text("收起到菜单栏（轻量常驻）")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(RemotePalette.indigo)
            }
            .buttonStyle(.plain)
            .help("隐藏主窗口与 Dock 图标，仅保留右上角菜单栏图标静默运行")
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
                    if let liveActionBannerText {
                        liveExecutionFeedbackPill(liveActionBannerText)
                    }
                    currentPage
                }
                .frame(maxWidth: 1150)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(selection?.rawValue ?? RemotePage.remote.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingConnectionSheet = true
                } label: {
                    Label("连接指引", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("查看蓝牙配对与遥控器连接状态")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    hideQuickStartGuide = false
                    selection = .remote
                } label: {
                    Label("快速上手", systemImage: "sparkles")
                }
                .help("展开 30 秒新手三步引导")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    runtime.enterLightweightMode()
                } label: {
                    Label("轻量模式", systemImage: "menubar.arrow.up.rectangle")
                }
                .help("隐藏主窗口与 Dock 图标到右上角菜单栏运行")
            }
        }
    }

    private func liveExecutionFeedbackPill(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RemotePalette.positive)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text("实时按键响应")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RemotePalette.positive.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(RemotePalette.positive.opacity(0.28), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
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
                Text(selection?.rawValue ?? "我的遥控器")
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
                            ? "正在控制：\(lanRelay.connectedPeerName ?? "远端 Mac") ⇄"
                            : "控制：\(lanRelay.localPeerName) ⇄",
                        symbol: lanRelay.isForwardingToRemoteMac ? "macbook.and.ipad" : "desktopcomputer",
                        tint: lanRelay.isForwardingToRemoteMac ? RemotePalette.turquoise : RemotePalette.indigo
                    )
                }
                .buttonStyle(.plain)
                .help("点击或按 \(lanRelay.switchShortcut.display) 切换控制哪台 Mac")
            }

            Button {
                hidCapture.setRemoteControlActive(!hidCapture.isRemoteControlActive)
            } label: {
                RemoteStatusPill(
                    title: hidCapture.isRemoteControlActive ? "遥控控制已开启" : "已暂停控制（点击恢复）",
                    symbol: hidCapture.isRemoteControlActive ? "bolt.fill" : "pause.circle",
                    tint: hidCapture.isRemoteControlActive ? RemotePalette.positive : RemotePalette.amber
                )
            }
            .buttonStyle(.plain)
            .help("一键暂停或恢复遥控器接管与动作执行")

            Button {
                showingConnectionSheet = true
            } label: {
                RemoteStatusPill(
                    title: hidCapture.isExclusive ? "遥控器已连" :
                        (bluetooth.connectedDeviceID != nil ? "仅语音已连" : "连接遥控器"),
                    symbol: hidCapture.isExclusive ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right",
                    tint: hidCapture.isExclusive ? RemotePalette.positive : RemotePalette.indigo
                )
            }
            .buttonStyle(.plain)
            .help("点击查看遥控器蓝牙配对与语音连接通道")
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
                        store: mappingStore,
                        onOpenPermissions: {
                            showAdvancedSidebarGroup = true
                            selection = .permissions
                        },
                        onDismiss: { hideQuickStartGuide = true }
                    )
                }

                if hidCapture.isExclusive && !hidCapture.executeHardwareActions && hideQuickStartGuide {
                    executionPausedBanner
                }

                RemoteMappingPage(
                    store: mappingStore,
                    library: actionLibrary,
                    monitor: hidCapture,
                    selected: $selectedMappingKey,
                    onOpenLibrary: { showingActionLibrarySheet = true },
                    onOpenConnection: { showingConnectionSheet = true }
                )
            }

        case .voice:
            RemoteVoicePage(
                transcriber: transcriber,
                onOpenConnection: { showingConnectionSheet = true },
                onOpenVoiceBinding: {
                    selectedMappingKey = .assistant
                    selection = .remote
                },
                onOpenSettings: { selection = .settings },
                section: $voiceSection
            )

        case .dualMac:
            RemoteDualMacPage(
                onOpenRemoteMapping: {
                    selectedMappingKey = .input
                    selection = .remote
                },
                onOpenPermissions: {
                    showAdvancedSidebarGroup = true
                    selection = .permissions
                },
                onOpenBackupSettings: {
                    settingsSection = .backup
                    selection = .settings
                },
                onOpenNetworkLogs: {
                    showAdvancedSidebarGroup = true
                    diagnosticLogFilter = .lan
                    selection = .diagnostics
                }
            )

        case .settings:
            RemoteSettingsPage(
                monitor: hidCapture,
                runtime: runtime,
                permissionCenter: permissionCenter,
                section: $settingsSection,
                onOpenDualMac: {
                    selection = .dualMac
                },
                onOpenPermissions: {
                    showAdvancedSidebarGroup = true
                    selection = .permissions
                },
                onReopenGuide: {
                    hideQuickStartGuide = false
                    selection = .remote
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

        case .diagnostics:
            RemoteDiagnosticsPage(
                monitor: hidCapture,
                selectedMappingKey: $selectedMappingKey,
                logFilter: $diagnosticLogFilter,
                onExportWave: exportWave
            )
        }
    }

    private var executionPausedBanner: some View {
        RemoteCard(padding: 13) {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(RemotePalette.amber)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("遥控器已连接，当前处于「仅预览高亮」状态")
                        .font(.system(size: 13, weight: .semibold))
                    Text("当前按实体遥控器只会在下方遥控器图上高亮选中；恢复后即可真实操控电脑。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("恢复按键执行") {
                    hidCapture.executeHardwareActions = true
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    private func exportWave() {
        guard let data = bluetooth.waveFileData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MoteFlow-voice-diagnostic.wav"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { fileError = error.localizedDescription }
        }
    }
}
