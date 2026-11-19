import AppKit
import SwiftUI

/// Streamlined Dual-Mac Synergy page:
/// - Clean visual target switcher ("本机" ⇄ "远端 Mac")
/// - App-focus auto target switching (bidirectional across host/receiver)
/// - Compact session mapping scheme & LAN device management
struct RemoteDualMacPage: View {
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    let onOpenRemoteMapping: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenBackupSettings: () -> Void
    let onOpenNetworkLogs: () -> Void

    @State private var manualHostInput = ""
    @State private var portInput = ""
    @State private var showingHotkeyRecorder = false
    @State private var showingSyncSheet = false
    @State private var preselectedSyncStrategy: RemoteConfigSyncStrategy = .merge
    @State private var showManualConnect = false
    @State private var showAdvancedSettings = false
    @State private var copiedIP = false
    @State private var portSaveHint: String?
    @State private var focusAppPickError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let incoming = lanRelay.incomingPairingRequest {
                incomingPairingBanner(incoming)
            }
            if let code = lanRelay.outgoingPairingCode, lanRelay.isPairingInProgress {
                outgoingPairingBanner(code: code)
            }

            targetSwitcherCard
            appFocusAutoSwitchCard
            mappingSchemeCard
            devicesCard
            shortcutAndAdvancedCard
        }
        .onAppear {
            portInput = String(lanRelay.sharedPort)
            lanRelay.refreshLocalIPs()
        }
        .sheet(isPresented: $showingHotkeyRecorder) {
            ShortcutRecorderSheet(
                key: .input,
                gesture: .tap,
                targetDescription: "双机切换快捷键"
            ) { shortcut in
                lanRelay.updateSwitchShortcut(shortcut)
                showingHotkeyRecorder = false
            }
        }
        .sheet(isPresented: $showingSyncSheet) {
            RemoteConfigSyncStrategySheet(
                title: "从远端 Mac 同步配置",
                sourceLabel: "远端 Mac",
                summaryDetail: "同步按键映射、阈值、命名方案与安全动作库",
                preselectedStrategy: preselectedSyncStrategy
            ) { strategy in
                lanRelay.requestPeerConfigSync(strategy: strategy)
            }
        }
    }

    // MARK: - Pairing Banners

    private func incomingPairingBanner(_ request: RemoteIncomingPairingRequest) -> some View {
        RemoteCard(padding: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(RemotePalette.indigo, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("收到「\(request.peerName)」的配对请求")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Text("核对码")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(request.verificationCode)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(RemotePalette.indigo)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                Spacer(minLength: 8)
                Button("拒绝") { lanRelay.rejectIncomingPairing() }
                    .buttonStyle(RemoteActionButtonStyle())
                Button("确认配对") { lanRelay.approveIncomingPairing() }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    private func outgoingPairingBanner(code: String) -> some View {
        RemoteCard(padding: 14) {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("等待对方确认配对…")
                        .font(.system(size: 14, weight: .semibold))
                    Text("请在另一台 Mac 上核对 6 位码并点击确认")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(code)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(RemotePalette.indigo)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                Button("取消") {
                    lanRelay.disconnectCurrentPeer(reason: "已取消配对", pauseSessionAutoConnect: false)
                }
                .buttonStyle(RemoteActionButtonStyle())
            }
        }
    }

    // MARK: - 1. Control Target Switcher

    private var targetSwitcherCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteSectionTitle(
                        title: "当前控制目标",
                        subtitle: "点击卡片或按 \(lanRelay.switchShortcut.display) 切换",
                        symbol: "macbook.and.ipad"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: lanRelay.isConnected
                            ? (lanRelay.latencyMs.map { String(format: "已连通 · %.0f ms", $0) } ?? "已连通")
                            : (lanRelay.isListening ? "待机中" : "已关闭"),
                        symbol: lanRelay.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
                        tint: lanRelay.isConnected ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                HStack(spacing: 12) {
                    topologyNodeCard(
                        name: "本机",
                        roleBadge: lanRelay.localHasPhysicalRemote
                            ? "已连遥控器"
                            : (lanRelay.isControlledByPeer ? "接收远程控制" : "点击切回本机"),
                        isActiveTarget: lanRelay.isLocalMacActiveControlTarget,
                        symbol: "desktopcomputer"
                    ) {
                        lanRelay.switchControlFocus(toLocalMac: true, showHUD: true)
                    }

                    Image(systemName: lanRelay.isForwardingToRemoteMac ? "arrow.right.circle.fill" :
                          (lanRelay.isControlledByPeer ? "arrow.left.circle.fill" : "arrow.left.arrow.right"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(lanRelay.isConnected ? RemotePalette.turquoise : .secondary)
                        .frame(width: 32)

                    topologyNodeCard(
                        name: "远端 Mac",
                        roleBadge: lanRelay.isConnected
                            ? (lanRelay.isRemoteMacActiveControlTarget ? "受控中" : "点击切换过去")
                            : "未连接",
                        isActiveTarget: lanRelay.isRemoteMacActiveControlTarget,
                        symbol: "macbook.and.ipad"
                    ) {
                        lanRelay.switchControlFocus(toLocalMac: false, showHUD: true)
                    }
                }

                if lanRelay.isControlledByPeer {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(RemotePalette.positive)
                        Text("正接收远端转发的按键与语音")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("允许被控", isOn: $lanRelay.allowIncomingControl)
                            .toggleStyle(.switch)
                            .font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RemotePalette.positive.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func topologyNodeCard(
        name: String,
        roleBadge: String,
        isActiveTarget: Bool,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isActiveTarget ? .white : RemotePalette.indigo)
                    .frame(width: 40, height: 40)
                    .background(
                        isActiveTarget ? RemotePalette.indigo : RemotePalette.indigo.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        if isActiveTarget {
                            Text("当前控制")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RemotePalette.positive, in: Capsule())
                        }
                    }
                    Text(roleBadge)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RemoteVisualChoiceStyle(selected: isActiveTarget, radius: 14))
    }

    // MARK: - 2. App-Focus Auto Switching

    private var customFocusSwitchApps: [RemoteFocusSwitchApp] {
        let presetIDs = Set(RemoteFocusSwitchApp.recommendedPresets.map { $0.bundleID.lowercased() })
        return lanRelay.focusSwitchApps.filter { !presetIDs.contains($0.bundleID.lowercased()) }
    }

    private var appFocusAutoSwitchCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteSectionTitle(
                        title: "按应用自动切换",
                        subtitle: "切进勾选的远程桌面 App 时自动控远端，离开后自动回本机",
                        symbol: "macwindow.on.rectangle"
                    )
                    Spacer(minLength: 8)
                    Toggle("开启", isOn: $lanRelay.autoSwitchByAppFocus)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if lanRelay.autoSwitchByAppFocus {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                        ForEach(RemoteFocusSwitchApp.recommendedPresets) { preset in
                            let selected = lanRelay.isFocusSwitchAppSelected(preset.bundleID)
                            Button {
                                lanRelay.toggleFocusSwitchPreset(preset)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(selected ? RemotePalette.indigo : .secondary)
                                    Text(preset.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 31)
                                .background(
                                    selected ? RemotePalette.indigo.opacity(0.10) : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .strokeBorder(selected ? RemotePalette.indigo.opacity(0.45) : .primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(customFocusSwitchApps) { custom in
                            HStack(spacing: 6) {
                                Image(systemName: "app.badge.checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(RemotePalette.indigo)
                                Text(custom.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    lanRelay.removeFocusSwitchApp(bundleID: custom.bundleID)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 31)
                            .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(RemotePalette.indigo.opacity(0.45))
                            )
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            chooseCustomFocusSwitchApp()
                        } label: {
                            Label("添加 App", systemImage: "plus")
                        }
                        .buttonStyle(RemoteActionButtonStyle())

                        Text("已选 \(lanRelay.focusSwitchApps.count) 个 · 手动切换优先")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    if let focusAppPickError {
                        Text(focusAppPickError)
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.amber)
                    }
                }
            }
        }
    }

    private func chooseCustomFocusSwitchApp() {
        focusAppPickError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "选择应用"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else {
                focusAppPickError = "请选择有效的 .app 应用程序。"
                return
            }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                       (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                       url.deletingPathExtension().lastPathComponent
            lanRelay.addFocusSwitchApp(RemoteFocusSwitchApp(bundleID: bundleID, displayName: name))
        }
    }

    // MARK: - 3. Session Mapping Scheme

    private var mappingSchemeCard: some View {
        let followSource = lanRelay.localMappingFollowSource
        return RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteSectionTitle(
                        title: "联机键位方案",
                        subtitle: "仅联机期间临时生效，断开自动恢复各自原配置",
                        symbol: "slider.horizontal.2.square"
                    )
                    Spacer(minLength: 6)

                    Menu {
                        Button {
                            preselectedSyncStrategy = .merge
                            showingSyncSheet = true
                        } label: {
                            Label("合并拉取远端配置", systemImage: "arrow.down.doc")
                        }
                        .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)

                        Button {
                            preselectedSyncStrategy = .overwrite
                            showingSyncSheet = true
                        } label: {
                            Label("完整覆盖同步远端配置", systemImage: "square.stack.3d.down.right")
                        }
                        .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)

                        Divider()

                        Button {
                            onOpenBackupSettings()
                        } label: {
                            Label("导出 / 导入备份文件…", systemImage: "externaldrive.badge.checkmark")
                        }
                    } label: {
                        Label(lanRelay.isSyncingConfig ? "同步中…" : "同步配置", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    RemoteVisualOption(
                        title: "用本机方案",
                        subtitle: "两台都按本机按键",
                        symbol: "desktopcomputer",
                        selected: followSource == .followLocalMac,
                        compact: true,
                        action: { lanRelay.setMappingFollowSource(.followLocalMac) }
                    )
                    RemoteVisualOption(
                        title: "用远端方案",
                        subtitle: "两台都按远端按键",
                        symbol: "macbook.and.ipad",
                        selected: followSource == .followRemoteMac,
                        compact: true,
                        action: { lanRelay.setMappingFollowSource(.followRemoteMac) }
                    )
                    RemoteVisualOption(
                        title: "各自独立",
                        subtitle: "控哪台用哪台",
                        symbol: "rectangle.split.2x1",
                        selected: followSource == .independent,
                        compact: true,
                        action: { lanRelay.setMappingFollowSource(.independent) }
                    )
                }

                if lanRelay.isConnected && !lanRelay.peerSupportsUnifiedPolicy {
                    Label("远端 MoteFlow 版本较旧，请将两台 Mac 更新到同一版本以支持方案同步。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.amber)
                }

                if let syncMsg = lanRelay.lastConfigSyncMessage {
                    Label(syncMsg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.positive)
                }
            }
        }
    }

    // MARK: - 4. LAN Devices

    private var offlineTrustedPeers: [RemoteTrustedPeer] {
        let discoveredIDs = Set(lanRelay.discoveredPeers.map(\.id))
        return lanRelay.trustedPeers.filter { !discoveredIDs.contains($0.id) }
    }

    private var devicesCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteSectionTitle(
                        title: "局域网设备",
                        subtitle: "同 Wi-Fi 自动发现，已配对设备自动重连",
                        symbol: "wifi"
                    )
                    Spacer(minLength: 6)
                    if lanRelay.isConnected {
                        Button("断开连接") { lanRelay.disconnectCurrentPeer() }
                            .buttonStyle(RemoteActionButtonStyle())
                    }
                    Button {
                        lanRelay.refreshDiscovery()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                }

                HStack(spacing: 10) {
                    Toggle("自动重连已配对设备", isOn: $lanRelay.autoConnectTrustedPeer)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if !lanRelay.pausedAutoConnectPeerIDs.isEmpty && !lanRelay.isConnected {
                        Button("恢复自动重连") { lanRelay.resumeAutoConnect() }
                            .buttonStyle(.link)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }

                if lanRelay.discoveredPeers.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(RemotePalette.indigo)
                        Text("正在搜索同 Wi-Fi 下的 Mac，在另一台电脑打开 MoteFlow 即可自动出现。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 11))
                } else {
                    VStack(spacing: 8) {
                        ForEach(lanRelay.discoveredPeers) { peer in
                            discoveredPeerRow(peer)
                        }
                    }
                }

                if !offlineTrustedPeers.isEmpty {
                    Divider().opacity(0.35)
                    ForEach(offlineTrustedPeers) { peer in
                        offlineTrustedPeerRow(peer)
                    }
                }

                DisclosureGroup(isExpanded: $showManualConnect) {
                    HStack(spacing: 9) {
                        TextField("输入局域网 IP（如 192.168.1.25）", text: $manualHostInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { _ = lanRelay.connectToAddress(manualHostInput) }
                        Button("IP 直连") { _ = lanRelay.connectToAddress(manualHostInput) }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(manualHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("手动输入 IP 直连", systemImage: "network")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .tint(RemotePalette.indigo)
            }
        }
    }

    private func discoveredPeerRow(_ peer: RemoteDiscoveredPeer) -> some View {
        let isCurrent = lanRelay.isConnected && lanRelay.connectedPeerID == peer.id
        let isSessionPaused = lanRelay.pausedAutoConnectPeerIDs.contains(peer.id)
        return HStack(spacing: 11) {
            Image(systemName: peer.isTrusted ? "laptopcomputer.and.iphone" : "desktopcomputer")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isCurrent ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 34, height: 34)
                .background(
                    (isCurrent ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 13, weight: .semibold))
                    if peer.isTrusted {
                        Text(isSessionPaused ? "已手动断开" : "已配对")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSessionPaused ? RemotePalette.amber : RemotePalette.positive)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                (isSessionPaused ? RemotePalette.amber : RemotePalette.positive).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
                Text(peer.host.map { "\($0):\(peer.port)" } ?? "局域网发现 · 端口 \(peer.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)

            if isCurrent {
                RemoteStatusPill(title: "已连通", symbol: "checkmark.circle.fill", tint: RemotePalette.positive)
            } else {
                Button(peer.isTrusted ? "连接" : "配对") {
                    lanRelay.connectToDiscoveredPeer(peer)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }

            if peer.isTrusted {
                Button {
                    lanRelay.removeTrustedPeer(peer.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除此设备的配对信任")
            }
        }
        .padding(10)
        .background(.primary.opacity(isCurrent ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 11))
    }

    private func offlineTrustedPeerRow(_ peer: RemoteTrustedPeer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.secondary)
            Text(peer.name).font(.system(size: 12.5, weight: .medium))
            Text(peer.lastHost.map { "\($0):\(peer.lastPort)" } ?? "离线")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let host = peer.lastHost {
                Button("重连") { _ = lanRelay.connectToAddress("\(host):\(peer.lastPort)") }
                    .buttonStyle(RemoteActionButtonStyle())
            }
            Button("移除") { lanRelay.removeTrustedPeer(peer.id) }
                .buttonStyle(RemoteActionButtonStyle())
        }
        .padding(9)
        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 5. Hotkey & Advanced Settings

    private var shortcutAndAdvancedCard: some View {
        RemoteCard(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    Label("切换快捷键：\(lanRelay.switchShortcut.display)", systemImage: "command.square.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                    Button("修改") { showingHotkeyRecorder = true }
                        .buttonStyle(RemoteActionButtonStyle())
                    Button("绑到遥控器", action: onOpenRemoteMapping)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    Spacer()
                    Button(showAdvancedSettings ? "收起高级设置" : "高级设置") {
                        showAdvancedSettings.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }

                if showAdvancedSettings {
                    Divider().opacity(0.35)
                    HStack(spacing: 10) {
                        Text("本机名").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("本机名称", text: $lanRelay.localPeerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        Text("端口").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("49280", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 78)
                            .onSubmit { applyPortUpdate() }
                        Button("应用") { applyPortUpdate() }
                            .buttonStyle(RemoteActionButtonStyle())
                        Spacer()
                        if let firstIP = lanRelay.localIPAddresses.first {
                            Button(copiedIP ? "已复制 IP" : "复制本机 IP (\(firstIP))") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(firstIP):\(lanRelay.sharedPort)", forType: .string)
                                copiedIP = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedIP = false }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                    if let portSaveHint {
                        Text(portSaveHint).font(.system(size: 11)).foregroundStyle(RemotePalette.indigo)
                    }

                    HStack(spacing: 14) {
                        Toggle("全局热键", isOn: $lanRelay.switchHotkeyEnabled).toggleStyle(.switch)
                        Toggle("顶部提示胶囊", isOn: $lanRelay.switchHUDEnabled).toggleStyle(.switch)
                        Toggle("切换音效", isOn: $lanRelay.switchSoundEnabled).toggleStyle(.switch)
                        Button("预览提示") { lanRelay.previewLocalSwitchNotification() }
                            .buttonStyle(.link)
                        Spacer()
                        Button("通信日志 →", action: onOpenNetworkLogs)
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                    }
                    .font(.system(size: 11.5))
                }
            }
        }
    }

    private func applyPortUpdate() {
        guard let parsed = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              lanRelay.updateSharedPort(parsed) else {
            portSaveHint = "请输入 1024 到 65535 之间的有效端口号"
            return
        }
        portSaveHint = "端口已改为 \(lanRelay.sharedPort)，两台 Mac 需保持一致"
    }
}
