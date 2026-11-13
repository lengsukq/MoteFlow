import AppKit
import ApplicationServices
import Combine
import CoreBluetooth
import CoreGraphics
import Speech
import SwiftUI
import UserNotifications

enum RemotePermissionFilter: String, CaseIterable, Identifiable {
    case all = "全部权限"
    case missing = "未添加 / 待开启"
    case granted = "已添加"

    var id: String { rawValue }
}

enum RemotePermissionTier: String {
    case core = "基础核心权限（必选）"
    case optional = "双机与语音进阶权限（按需）"
}

enum RemotePermissionGrantState: Equatable {
    case granted
    case notDetermined
    case denied
    case needsSetup

    var isGranted: Bool { self == .granted }

    var badgeTitle: String {
        switch self {
        case .granted: "已添加"
        case .notDetermined: "未添加（待授权）"
        case .denied: "未开启（去设置勾选）"
        case .needsSetup: "待启用"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .notDetermined: "plus.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .needsSetup: "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .granted: RemotePalette.positive
        case .notDetermined, .denied: RemotePalette.amber
        case .needsSetup: RemotePalette.indigo
        }
    }
}

enum RemotePermissionKind: String, CaseIterable, Identifiable {
    case inputMonitoring
    case accessibility
    case bluetooth
    case localNetwork
    case notifications
    case speechRecognition
    case virtualAudio

    var id: String { rawValue }

    var tier: RemotePermissionTier {
        switch self {
        case .inputMonitoring, .accessibility, .bluetooth:
            .core
        case .localNetwork, .notifications, .speechRecognition, .virtualAudio:
            .optional
        }
    }

    var title: String {
        switch self {
        case .inputMonitoring: "输入监控（Input Monitoring）"
        case .accessibility: "辅助功能（Accessibility）"
        case .bluetooth: "蓝牙连接（Bluetooth）"
        case .localNetwork: "本地网络（双机互联）"
        case .notifications: "系统通知（切换提醒）"
        case .speechRecognition: "本地语音识别（离线转文字）"
        case .virtualAudio: "虚拟麦克风驱动（BlackHole 2ch）"
        }
    }

    var symbol: String {
        switch self {
        case .inputMonitoring: "appletvremote.gen4"
        case .accessibility: "keyboard.badge.ellipsis"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .localNetwork: "macbook.and.ipad"
        case .notifications: "bell.badge.fill"
        case .speechRecognition: "waveform.badge.mic"
        case .virtualAudio: "speaker.wave.2.bubble"
        }
    }

    var purpose: String {
        switch self {
        case .inputMonitoring:
            "读取并独占接管遥控器的实体按键信号，防止按遥控器时误触发系统默认行为（受控端若不直连遥控器可不加）。"
        case .accessibility:
            "把遥控器操作转换为键盘快捷键、长按连发、方向键与跨应用复制粘贴（主控与被远程控制的 Mac 均建议开启）。"
        case .bluetooth:
            "扫描并连接蓝牙遥控器、建立 ATVV 语音控制通道。"
        case .localNetwork:
            "在同一局域网（同端口）自动发现另一台 Mac，支持已配对设备自动静默重连与远程按键转发。"
        case .notifications:
            "按快捷键切换回本机或收到配对请求时，在屏幕右上角弹出系统通知横幅与提示音。"
        case .speechRecognition:
            "不经过网络，直接调用 macOS 本地引擎将遥控器语音录音转写为文字。"
        case .virtualAudio:
            "将遥控器麦克风声音通过虚拟声卡送给豆包等语音工具，全程不开启 Mac 物理麦克风。"
        }
    }
}

struct RemotePermissionStatusSnapshot: Identifiable, Equatable {
    let kind: RemotePermissionKind
    let state: RemotePermissionGrantState
    let statusDetail: String
    let primaryActionTitle: String?
    let settingsActionTitle: String?

    var id: RemotePermissionKind { kind }
}

/// Centralized real-time permission inspector so users can view all granted and
/// missing macOS permissions in a single place without hunting across pages.
@MainActor
final class RemotePermissionCenter: ObservableObject {
    @Published private(set) var snapshots: [RemotePermissionStatusSnapshot] = []
    @Published private(set) var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastRefreshedAt = Date()

    private var pollTask: Task<Void, Never>?

    var coreSnapshots: [RemotePermissionStatusSnapshot] {
        snapshots.filter { $0.kind.tier == .core }
    }

    var optionalSnapshots: [RemotePermissionStatusSnapshot] {
        snapshots.filter { $0.kind.tier == .optional }
    }

    var missingCoreCount: Int {
        coreSnapshots.filter { !$0.state.isGranted }.count
    }

    var missingTotalCount: Int {
        snapshots.filter { !$0.state.isGranted }.count
    }

    var grantedTotalCount: Int {
        snapshots.filter { $0.state.isGranted }.count
    }

    func refresh(
        bluetooth: RemoteBluetoothManager,
        lanRelay: RemoteLANRelayManager
    ) {
        bluetooth.virtualMicrophone.refreshDevices()
        rebuildSnapshots(bluetooth: bluetooth, lanRelay: lanRelay)
        refreshNotificationAuthorization(bluetooth: bluetooth, lanRelay: lanRelay)
    }

    func startLiveMonitoring(
        bluetooth: RemoteBluetoothManager,
        lanRelay: RemoteLANRelayManager
    ) {
        refresh(bluetooth: bluetooth, lanRelay: lanRelay)
        pollTask?.cancel()
        pollTask = Task { [weak self, weak bluetooth, weak lanRelay] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled,
                      let self, let bluetooth, let lanRelay else { return }
                self.rebuildSnapshots(bluetooth: bluetooth, lanRelay: lanRelay)
                self.refreshNotificationAuthorization(bluetooth: bluetooth, lanRelay: lanRelay)
            }
        }
    }

    func stopLiveMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refreshNotificationAuthorization(
        bluetooth: RemoteBluetoothManager,
        lanRelay: RemoteLANRelayManager
    ) {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            notificationAuthStatus = .notDetermined
            rebuildSnapshots(bluetooth: bluetooth, lanRelay: lanRelay)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self, weak bluetooth, weak lanRelay] settings in
            Task { @MainActor in
                guard let self else { return }
                self.notificationAuthStatus = settings.authorizationStatus
                if let bluetooth, let lanRelay {
                    self.rebuildSnapshots(bluetooth: bluetooth, lanRelay: lanRelay)
                }
            }
        }
    }

    private func rebuildSnapshots(
        bluetooth: RemoteBluetoothManager,
        lanRelay: RemoteLANRelayManager
    ) {
        var list: [RemotePermissionStatusSnapshot] = []

        // 1. Input Monitoring
        let inputStatus = SystemHIDProbe.inputMonitoringStatus
        let inputState: RemotePermissionGrantState = switch inputStatus {
        case .granted: .granted
        case .notDetermined: .notDetermined
        case .denied, .unknown: .denied
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .inputMonitoring,
            state: inputState,
            statusDetail: inputStatus == .granted
                ? "已授权 · 可直接识别并独占接管已配对遥控器按键"
                : (inputStatus == .notDetermined
                    ? "尚未添加权限 · 点击右侧「请求授权」弹出系统窗口"
                    : "尚未开启 · 请在系统设置「输入监控」列表中勾选 MoteFlow（勾选后重启应用生效）"),
            primaryActionTitle: inputStatus == .notDetermined ? "请求授权" : nil,
            settingsActionTitle: "打开输入监控设置"
        ))

        // 2. Accessibility
        let axTrusted = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        list.append(RemotePermissionStatusSnapshot(
            kind: .accessibility,
            state: axTrusted ? .granted : .denied,
            statusDetail: axTrusted
                ? "已授权 · 键盘快捷键模拟、长按连发与跨应用菜单均可用（如刚勾选后仍无效，请点上方「重启 MoteFlow」）"
                : "尚未添加权限 · 点击「弹出授权提示」并在系统设置「辅助功能」中打开 MoteFlow 开关（勾选后可能需要重启应用生效）",
            primaryActionTitle: axTrusted ? nil : "弹出授权提示",
            settingsActionTitle: "打开辅助功能设置"
        ))

        // 3. Bluetooth
        let btAuth = CBManager.authorization
        let btState: RemotePermissionGrantState
        let btDetail: String
        let btPrimary: String?
        switch btAuth {
        case .allowedAlways:
            if bluetooth.isBluetoothReady {
                btState = .granted
                btDetail = "已授权且系统蓝牙已开启（\(bluetooth.connectionSummary)）"
                btPrimary = nil
            } else {
                btState = .needsSetup
                btDetail = "应用蓝牙权限已添加，但当前系统蓝牙状态为：\(bluetooth.bluetoothState)"
                btPrimary = nil
            }
        case .notDetermined:
            btState = .notDetermined
            btDetail = "首次扫描遥控器时系统会自动弹窗询问蓝牙权限"
            btPrimary = "触发蓝牙授权"
        case .denied, .restricted:
            btState = .denied
            btDetail = "蓝牙权限被关闭 · 请在「隐私与安全性 → 蓝牙」中勾选 MoteFlow"
            btPrimary = nil
        @unknown default:
            btState = .needsSetup
            btDetail = bluetooth.bluetoothState
            btPrimary = nil
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .bluetooth,
            state: btState,
            statusDetail: btDetail,
            primaryActionTitle: btPrimary,
            settingsActionTitle: btAuth == .allowedAlways ? "打开系统蓝牙" : "打开蓝牙权限设置"
        ))

        // 4. Local Network (Dual-Mac LAN)
        let lanState: RemotePermissionGrantState
        let lanDetail: String
        let lanPrimary: String?
        if !lanRelay.isServiceEnabled {
            lanState = .needsSetup
            lanDetail = "双机局域网服务当前已关闭 · 开启后可在同端口自动发现并自动连接已配对 Mac"
            lanPrimary = "一键开启双机服务"
        } else if lanRelay.isListening {
            lanState = .granted
            let ipText = lanRelay.localIPAddresses.first ?? "局域网就绪"
            lanDetail = "端口 \(lanRelay.sharedPort) 监听正常（\(ipText)）· 自动发现与已配对自动重连已就绪"
            lanPrimary = "触发局域网扫描"
        } else {
            lanState = .denied
            lanDetail = "\(lanRelay.listenerStatus) · 若系统拦截，请在「隐私与安全性 → 本地网络」勾选 MoteFlow"
            lanPrimary = "重试启动监听"
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .localNetwork,
            state: lanState,
            statusDetail: lanDetail,
            primaryActionTitle: lanPrimary,
            settingsActionTitle: "打开本地网络设置"
        ))

        // 5. System Notifications
        let notifyState: RemotePermissionGrantState
        let notifyDetail: String
        let notifyPrimary: String?
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            notifyState = .granted
            notifyDetail = "已授权 · 切换到本机或远端 Mac 时会弹出横幅通知与声音提醒"
            notifyPrimary = "发送预览通知"
        case .notDetermined:
            notifyState = .notDetermined
            notifyDetail = "尚未请求系统通知权限 · 开启后切换回本机时右上角会有明确通知提示"
            notifyPrimary = "申请通知权限"
        case .denied:
            notifyState = .denied
            notifyDetail = "系统通知已被关闭（仍保留屏幕顶部悬浮提示条）· 可到系统通知设置中重新允许"
            notifyPrimary = nil
        @unknown default:
            notifyState = .notDetermined
            notifyDetail = "等待检测通知权限"
            notifyPrimary = "申请通知权限"
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .notifications,
            state: notifyState,
            statusDetail: notifyDetail,
            primaryActionTitle: notifyPrimary,
            settingsActionTitle: "打开系统通知设置"
        ))

        // 6. Speech Recognition
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        let speechState: RemotePermissionGrantState
        let speechDetail: String
        let speechPrimary: String?
        switch speechAuth {
        case .authorized:
            speechState = .granted
            speechDetail = "已授权 · 可使用 macOS 离线语音识别将遥控器录音转写为文字"
            speechPrimary = nil
        case .notDetermined:
            speechState = .notDetermined
            speechDetail = "尚未添加（如使用豆包语音输入可不开启此项；仅本地离线转文字时需要）"
            speechPrimary = "申请语音识别权限"
        case .denied, .restricted:
            speechState = .denied
            speechDetail = "未开启 · 如需本地离线转文字，请在「隐私与安全性 → 语音识别」勾选 MoteFlow"
            speechPrimary = nil
        @unknown default:
            speechState = .notDetermined
            speechDetail = "尚未检测语音识别权限"
            speechPrimary = nil
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .speechRecognition,
            state: speechState,
            statusDetail: speechDetail,
            primaryActionTitle: speechPrimary,
            settingsActionTitle: "打开语音识别设置"
        ))

        // 7. Virtual Audio Driver (BlackHole 2ch)
        let hasBlackHole = bluetooth.virtualMicrophone.devices.contains {
            $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
        }
        list.append(RemotePermissionStatusSnapshot(
            kind: .virtualAudio,
            state: hasBlackHole ? .granted : .needsSetup,
            statusDetail: hasBlackHole
                ? "BlackHole 2ch 虚拟声卡已就绪 · 可将遥控器语音直接送入豆包输入法"
                : "未安装 BlackHole 2ch（仅在使用遥控器麦克风向豆包实时说话时需要安装）",
            primaryActionTitle: hasBlackHole ? nil : "前往安装驱动",
            settingsActionTitle: "打开声音设置"
        ))

        snapshots = list
        lastRefreshedAt = Date()
    }

    // MARK: - User Actions

    func performPrimaryAction(
        for kind: RemotePermissionKind,
        bluetooth: RemoteBluetoothManager,
        hidCapture: HIDCaptureManager,
        lanRelay: RemoteLANRelayManager,
        onOpenVoiceDrivers: () -> Void
    ) {
        switch kind {
        case .inputMonitoring:
            _ = SystemHIDProbe.requestInputMonitoring()
            hidCapture.tryAutomaticCapture()
            refresh(bluetooth: bluetooth, lanRelay: lanRelay)

        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestPostEventAccess()
            refresh(bluetooth: bluetooth, lanRelay: lanRelay)

        case .bluetooth:
            if !bluetooth.isScanning {
                bluetooth.toggleScan()
            }
            refresh(bluetooth: bluetooth, lanRelay: lanRelay)

        case .localNetwork:
            if !lanRelay.isServiceEnabled {
                lanRelay.isServiceEnabled = true
            } else {
                lanRelay.refreshDiscovery()
            }
            refresh(bluetooth: bluetooth, lanRelay: lanRelay)

        case .notifications:
            if notificationAuthStatus == .authorized || notificationAuthStatus == .provisional {
                lanRelay.previewLocalSwitchNotification()
            } else {
                RemoteSwitchNotificationCenter.shared.requestAuthorizationIfNeeded()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    self.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
                }
            }

        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { [weak self, weak bluetooth, weak lanRelay] _ in
                Task { @MainActor in
                    guard let self, let bluetooth, let lanRelay else { return }
                    self.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
                }
            }

        case .virtualAudio:
            onOpenVoiceDrivers()
        }
    }

    func openSystemSettings(for kind: RemotePermissionKind) {
        let urlString: String
        switch kind {
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .bluetooth:
            if CBManager.authorization == .allowedAlways {
                urlString = "x-apple.systempreferences:com.apple.BluetoothSettings"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
            }
        case .localNetwork:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .speechRecognition:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .virtualAudio:
            urlString = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func revealRunningAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func relaunchApplication() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension.lowercased() == "app" else { return }
        // Spawn a short delayed open and terminate first so the current instance
        // cleanly releases port 49280, HID exclusive handles, and audio queues.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.45 && /usr/bin/open -n \"$1\"", "_", appURL.path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

struct RemotePermissionsPage: View {
    @ObservedObject var permissionCenter: RemotePermissionCenter
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager

    let onOpenVoiceDrivers: () -> Void
    let onOpenDualMac: () -> Void

    @State private var filter: RemotePermissionFilter = .all

    private var filteredCore: [RemotePermissionStatusSnapshot] {
        applyFilter(permissionCenter.coreSnapshots)
    }

    private var filteredOptional: [RemotePermissionStatusSnapshot] {
        applyFilter(permissionCenter.optionalSnapshots)
    }

    private func applyFilter(_ items: [RemotePermissionStatusSnapshot]) -> [RemotePermissionStatusSnapshot] {
        switch filter {
        case .all:
            items
        case .missing:
            items.filter { !$0.state.isGranted }
        case .granted:
            items.filter { $0.state.isGranted }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryHeroCard

            if filteredCore.isEmpty && filteredOptional.isEmpty {
                emptyFilterStateCard
            } else {
                if !filteredCore.isEmpty {
                    permissionSectionCard(
                        title: RemotePermissionTier.core.rawValue,
                        subtitle: "保障遥控器识别、快捷键模拟与蓝牙连接最基础的 3 项权限",
                        symbol: "checkmark.shield.fill",
                        items: filteredCore
                    )
                }

                if !filteredOptional.isEmpty {
                    permissionSectionCard(
                        title: RemotePermissionTier.optional.rawValue,
                        subtitle: "用于两台 Mac 局域网自动重连、切换通知横幅与语音输入的扩展能力",
                        symbol: "sparkles.rectangle.stack",
                        items: filteredOptional
                    )
                }
            }

            troubleshootingTipCard
        }
        .onAppear {
            permissionCenter.startLiveMonitoring(bluetooth: bluetooth, lanRelay: lanRelay)
        }
        .onDisappear {
            permissionCenter.stopLiveMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCenter.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
        }
    }

    private var summaryHeroCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: permissionCenter.missingCoreCount == 0 ? "checkmark.shield.fill" : "shield.lefthalf.filled.badge.checkmark")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            permissionCenter.missingCoreCount == 0 ? RemotePalette.positive : RemotePalette.indigo,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(
                                permissionCenter.missingCoreCount == 0
                                    ? "基础核心权限已全部就绪"
                                    : "还有 \(permissionCenter.missingCoreCount) 项基础权限尚未添加"
                            )
                            .font(.system(size: 17, weight: .bold, design: .rounded))

                            RemoteStatusPill(
                                title: "已添加 \(permissionCenter.grantedTotalCount)/\(permissionCenter.snapshots.count)",
                                symbol: permissionCenter.missingCoreCount == 0 ? "checkmark.circle.fill" : "info.circle.fill",
                                tint: permissionCenter.missingCoreCount == 0 ? RemotePalette.positive : RemotePalette.amber
                            )
                        }

                        Text("在这里一页看清哪些系统权限已经开启、哪些还没添加；在系统设置勾选后切回本窗口会自动刷新状态。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            permissionCenter.refresh(bluetooth: bluetooth, lanRelay: lanRelay)
                            hidCapture.tryAutomaticCapture()
                        } label: {
                            Label("刷新检测", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: permissionCenter.missingCoreCount > 0))

                        Button {
                            permissionCenter.relaunchApplication()
                        } label: {
                            Label("重启 MoteFlow", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                    }
                }

                HStack(spacing: 8) {
                    filterTabButton(
                        .all,
                        count: permissionCenter.snapshots.count
                    )
                    filterTabButton(
                        .missing,
                        count: permissionCenter.missingTotalCount
                    )
                    filterTabButton(
                        .granted,
                        count: permissionCenter.grantedTotalCount
                    )
                    Spacer()

                    if permissionCenter.missingCoreCount == 0 {
                        Button {
                            onOpenDualMac()
                        } label: {
                            Label("前往双机互联设置", systemImage: "macbook.and.ipad")
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
    }

    private func filterTabButton(_ item: RemotePermissionFilter, count: Int) -> some View {
        let selected = (filter == item)
        return Button {
            filter = item
        } label: {
            HStack(spacing: 6) {
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? RemotePalette.indigo : Color.primary.opacity(0.045))
            )
        }
        .buttonStyle(.plain)
    }

    private func permissionSectionCard(
        title: String,
        subtitle: String,
        symbol: String,
        items: [RemotePermissionStatusSnapshot]
    ) -> some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                RemoteSectionTitle(title: title, subtitle: subtitle, symbol: symbol)

                VStack(spacing: 10) {
                    ForEach(items) { item in
                        permissionRow(item)
                    }
                }
            }
        }
    }

    private func permissionRow(_ item: RemotePermissionStatusSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(item.state.tint)
                .frame(width: 42, height: 42)
                .background(item.state.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.kind.title)
                        .font(.system(size: 14, weight: .semibold))
                    RemoteStatusPill(
                        title: item.state.badgeTitle,
                        symbol: item.state.badgeSymbol,
                        tint: item.state.tint
                    )
                }

                Text(item.kind.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.statusDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.state.isGranted ? RemotePalette.positive : .primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                if let primary = item.primaryActionTitle {
                    Button(primary) {
                        permissionCenter.performPrimaryAction(
                            for: item.kind,
                            bluetooth: bluetooth,
                            hidCapture: hidCapture,
                            lanRelay: lanRelay,
                            onOpenVoiceDrivers: onOpenVoiceDrivers
                        )
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: !item.state.isGranted))
                }

                if let settingsTitle = item.settingsActionTitle {
                    Button(settingsTitle) {
                        permissionCenter.openSystemSettings(for: item.kind)
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: item.primaryActionTitle == nil && !item.state.isGranted))
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(item.state.isGranted ? RemotePalette.positive.opacity(0.04) : Color.primary.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    item.state.isGranted ? RemotePalette.positive.opacity(0.22) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private var emptyFilterStateCard: some View {
        RemoteCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(RemotePalette.positive)
                VStack(alignment: .leading, spacing: 3) {
                    Text(filter == .missing ? "太棒了！当前筛选下没有待添加的权限" : "当前筛选下暂无条目")
                        .font(.system(size: 14, weight: .semibold))
                    Text("点击上方「全部权限」可随时复查每一项系统权限详情。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看全部权限") { filter = .all }
                    .buttonStyle(RemoteActionButtonStyle())
            }
        }
    }

    private var troubleshootingTipCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(RemotePalette.amber)
                    Text("macOS 权限添加小贴士（两台 Mac 通用）")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text("• **另一台被远程控制的 Mac 需要开哪些权限？** 若遥控器蓝牙只连在主控 Mac 上，另一台受控 Mac 只需开启「辅助功能」和「本地网络」（加「系统通知」看提醒），无需配对蓝牙或开启输入监控。\n• **如果在系统设置里已经勾选了 MoteFlow 但仍提示未开启**：覆盖升级应用后旧记录可能失效，可在系统权限列表选中 MoteFlow 点底部「-」移除，再点击下方「在 Finder 定位当前应用」把图标拖进去并点「重启应用刷新」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        permissionCenter.revealRunningAppInFinder()
                    } label: {
                        Label("在 Finder 定位当前应用（方便拖入系统设置）", systemImage: "folder")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        permissionCenter.relaunchApplication()
                    } label: {
                        Label("重启 MoteFlow 使权限生效", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Spacer()
                }
            }
        }
    }
}
