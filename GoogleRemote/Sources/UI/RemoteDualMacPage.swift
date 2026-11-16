import AppKit
import SwiftUI

/// Redesigned Dual-Mac Synergy page:
/// - Visual live topology strip clearly illustrating who holds the remote vs. which screen is controlled
/// - Concrete real-Mac-name scheme selector ("套用 MacBook Pro 的键位方案" vs. "套用 Mac mini 的键位方案")
/// - Clean top-HUD + audio switch feedback (no redundant system notification banners or duplicate log box)
struct RemoteDualMacPage: View {
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var showShortcutAndPortDetails = false
    @State private var copiedIP = false
    @State private var portSaveHint: String?

    private var remoteDisplayName: String {
        lanRelay.connectedPeerName ?? lanRelay.controllingPeerName ?? "另一台 Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let incoming = lanRelay.incomingPairingRequest {
                incomingPairingBanner(incoming)
            }
            if let code = lanRelay.outgoingPairingCode, lanRelay.isPairingInProgress {
                outgoingPairingBanner(code: code)
            }

            topologyAndTargetHeroCard

            realDeviceSchemeAndSyncCard

            discoveryAndTrustedDevicesCard

            shortcutAndPortCard
        }
        .onAppear {
            portInput = String(lanRelay.sharedPort)
            lanRelay.refreshLocalIPs()
        }
        .sheet(isPresented: $showingHotkeyRecorder) {
            ShortcutRecorderSheet(
                key: .input,
                gesture: .tap,
                targetDescription: "双机控制目标全局切换快捷键"
            ) { shortcut in
                lanRelay.updateSwitchShortcut(shortcut)
                showingHotkeyRecorder = false
            }
        }
        .sheet(isPresented: $showingSyncSheet) {
            RemoteConfigSyncStrategySheet(
                title: "从「\(remoteDisplayName)」同步遥控器配置",
                sourceLabel: remoteDisplayName,
                summaryDetail: "同步按键映射、长按阈值、命名方案与安全动作库条目",
                preselectedStrategy: preselectedSyncStrategy
            ) { strategy in
                lanRelay.requestPeerConfigSync(strategy: strategy)
            }
        }
    }

    // MARK: - Pairing Banners

    private func incomingPairingBanner(_ request: RemoteIncomingPairingRequest) -> some View {
        RemoteCard {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(RemotePalette.indigo, in: RoundedRectangle(cornerRadius: 15))

                VStack(alignment: .leading, spacing: 5) {
                    Text("「\(request.peerName)」请求局域网双机配对")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Text("核对码：")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(request.verificationCode)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(RemotePalette.indigo)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Spacer(minLength: 8)
                Button("拒绝") { lanRelay.rejectIncomingPairing() }
                    .buttonStyle(RemoteActionButtonStyle())
                Button {
                    lanRelay.approveIncomingPairing()
                } label: {
                    Label("确认配对", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    private func outgoingPairingBanner(code: String) -> some View {
        RemoteCard {
            HStack(spacing: 15) {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("等待对方点击「确认配对」…")
                        .font(.system(size: 15, weight: .semibold))
                    Text("请在另一台 Mac 弹出的配对窗口中核对下方 6 位数字并点击确认：")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(RemotePalette.indigo)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                Button("取消") {
                    lanRelay.disconnectCurrentPeer(reason: "已取消配对请求", pauseSessionAutoConnect: false)
                }
                .buttonStyle(RemoteActionButtonStyle())
            }
        }
    }

    // MARK: - Live Visual Topology & Target Switcher

    private var topologyAndTargetHeroCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    RemoteSectionTitle(
                        title: "一个遥控器，自由穿梭两台 Mac",
                        subtitle: "蓝牙只需连在一台电脑上；配对一次后同一 Wi-Fi 自动重连，按 \(lanRelay.switchShortcut.display) 随时切换屏幕",
                        symbol: "macbook.and.ipad"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: lanRelay.isConnected
                            ? (lanRelay.latencyMs.map { String(format: "已连通 · %.1f ms", $0) } ?? "双机已连通")
                            : (lanRelay.isListening ? "端口 \(lanRelay.sharedPort) 待命" : "服务已关闭"),
                        symbol: lanRelay.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
                        tint: lanRelay.isConnected ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                HStack(spacing: 12) {
                    topologyNodeCard(
                        name: lanRelay.localPeerName,
                        roleBadge: lanRelay.localHasPhysicalRemote ? "握持实体遥控器" : "本机屏幕",
                        isActiveTarget: !lanRelay.isForwardingToRemoteMac && !lanRelay.isControlledByPeer,
                        symbol: "desktopcomputer"
                    ) {
                        lanRelay.setTarget(.localMac, showHUD: true)
                    }

                    VStack(spacing: 4) {
                        Image(systemName: lanRelay.isForwardingToRemoteMac ? "arrow.right.circle.fill" :
                              (lanRelay.isControlledByPeer ? "arrow.left.circle.fill" : "arrow.left.arrow.right"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(lanRelay.isConnected ? RemotePalette.turquoise : .secondary)
                        Text(lanRelay.isForwardingToRemoteMac ? "转发中" : (lanRelay.isConnected ? "点击切换" : "未连接"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(lanRelay.isForwardingToRemoteMac ? RemotePalette.turquoise : .secondary)
                    }
                    .frame(width: 62)

                    topologyNodeCard(
                        name: remoteDisplayName,
                        roleBadge: lanRelay.isConnected
                            ? (lanRelay.isForwardingToRemoteMac ? "当前受控屏幕" : "在线待命 · 点击切过去")
                            : "请在下方点击设备配对",
                        isActiveTarget: lanRelay.isForwardingToRemoteMac || lanRelay.isControlledByPeer,
                        symbol: "macbook.and.ipad"
                    ) {
                        lanRelay.setTarget(.remoteMac, showHUD: true)
                    }
                }

                if lanRelay.isControlledByPeer {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(RemotePalette.positive)
                        Text("当前正在接收来自「\(lanRelay.controllingPeerName ?? "主控 Mac")」转发的遥控器按键与语音。")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Toggle("允许远端控制本机", isOn: $lanRelay.allowIncomingControl)
                            .toggleStyle(.switch)
                            .font(.system(size: 11))
                    }
                    .padding(11)
                    .background(RemotePalette.positive.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
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
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isActiveTarget ? .white : RemotePalette.indigo)
                    .frame(width: 44, height: 44)
                    .background(
                        isActiveTarget ? RemotePalette.indigo : RemotePalette.indigo.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
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
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RemoteVisualChoiceStyle(selected: isActiveTarget, radius: 15))
    }

    // MARK: - Zero-Ambiguity Real-Mac-Name Mapping Scheme + Config Sync Menu

    private var realDeviceSchemeAndSyncCard: some View {
        let isReceiver = lanRelay.isActingAsReceiverMac
        let followSource = lanRelay.localMappingFollowSource
        return RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "远程控制时套用哪台电脑的键位方案？",
                        subtitle: "直接点选真实电脑名称即可，两台 Mac 双向实时同步，无需烧脑换算“本机 / 远程”",
                        symbol: "slider.horizontal.2.square"
                    )
                    Spacer(minLength: 6)

                    Menu {
                        Button {
                            preselectedSyncStrategy = .merge
                            showingSyncSheet = true
                        } label: {
                            Label("合并拉取「\(remoteDisplayName)」的配置（保留本机已有）", systemImage: "arrow.down.doc")
                        }
                        .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)

                        Button {
                            preselectedSyncStrategy = .overwrite
                            showingSyncSheet = true
                        } label: {
                            Label("完整覆盖同步「\(remoteDisplayName)」的配置", systemImage: "square.stack.3d.down.right")
                        }
                        .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)

                        Divider()

                        Button {
                            onOpenBackupSettings()
                        } label: {
                            Label("导出 / 导入 JSON 备份文件…", systemImage: "externaldrive.badge.checkmark")
                        }
                    } label: {
                        Label(lanRelay.isSyncingConfig ? "正在同步…" : "一键同步两机配置", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) { schemeButtons(isReceiver: isReceiver, followSource: followSource) }

                if let syncMsg = lanRelay.lastConfigSyncMessage {
                    Label(syncMsg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.positive)
                }
            }
        }
    }

    @ViewBuilder
    private func schemeButtons(isReceiver: Bool, followSource: RemoteMappingFollowSource) -> some View {
        RemoteVisualOption(
            title: "套用「\(lanRelay.localPeerName)」的键位方案",
            subtitle: isReceiver
                ? "收到远程按键时，按这台「\(lanRelay.localPeerName)」自己保存的按键映射执行"
                : "直接把这台「\(lanRelay.localPeerName)」配好的快捷键与长按动作发给对端执行",
            symbol: "desktopcomputer",
            selected: followSource == .followLocalMac,
            compact: true,
            action: { lanRelay.setMappingFollowSource(.followLocalMac) }
        )

        RemoteVisualOption(
            title: "套用「\(remoteDisplayName)」的键位方案",
            subtitle: isReceiver
                ? "直接沿用主控机「\(remoteDisplayName)」设好的动作，这台电脑无需再配一遍"
                : "只把原始按键发给「\(remoteDisplayName)」，由对端按它自己的按键表执行",
            symbol: "macbook.and.ipad",
            selected: followSource == .followRemoteMac,
            compact: true,
            action: { lanRelay.setMappingFollowSource(.followRemoteMac) }
        )
    }

    // MARK: - Discovery & Trusted Devices

    private var discoveryAndTrustedDevicesCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "局域网设备发现与自动连接",
                        subtitle: "仅已配对信任的 Mac 会自动静默重连；新设备首次需点击「请求配对」确认 6 位码",
                        symbol: "wifi"
                    )
                    Spacer(minLength: 6)
                    Button {
                        lanRelay.refreshDiscovery()
                    } label: {
                        Label("刷新扫描", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                }

                HStack(spacing: 10) {
                    Toggle("自动连接已配对过的 Mac（唤醒后自动恢复）", isOn: $lanRelay.autoConnectTrustedPeer)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if !lanRelay.pausedAutoConnectPeerIDs.isEmpty && !lanRelay.isConnected {
                        Button("恢复本次自动重连") { lanRelay.resumeAutoConnect() }
                            .buttonStyle(.link)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    if lanRelay.isConnected {
                        Button("断开当前连接") { lanRelay.disconnectCurrentPeer() }
                            .buttonStyle(RemoteActionButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))

                if lanRelay.discoveredPeers.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 17))
                            .foregroundStyle(RemotePalette.indigo)
                        Text("正在搜索同一 Wi-Fi 下的其他 Mac（端口 \(lanRelay.sharedPort)）… 在另一台电脑打开 MoteFlow 即可自动出现。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 8) {
                        ForEach(lanRelay.discoveredPeers) { peer in
                            discoveredPeerRow(peer)
                        }
                    }
                }

                if !lanRelay.trustedPeers.isEmpty {
                    Divider().opacity(0.4)
                    Text("已信任白名单（\(lanRelay.trustedPeers.count) 台）")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(lanRelay.trustedPeers) { peer in
                        trustedPeerCompactRow(peer)
                    }
                }

                DisclosureGroup(isExpanded: $showManualConnect) {
                    HStack(spacing: 9) {
                        TextField("输入对端局域网 IP（如 192.168.1.25）", text: $manualHostInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { _ = lanRelay.connectToAddress(manualHostInput) }
                        Button("IP 直连配对") { _ = lanRelay.connectToAddress(manualHostInput) }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(manualHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("路由器隔离未自动发现？手动输入 IP 直连", systemImage: "network")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .tint(RemotePalette.indigo)
            }
        }
    }

    private func discoveredPeerRow(_ peer: RemoteDiscoveredPeer) -> some View {
        let isCurrent = lanRelay.isConnected && lanRelay.connectedPeerID == peer.id
        let isSessionPaused = lanRelay.pausedAutoConnectPeerIDs.contains(peer.id)
        return HStack(spacing: 12) {
            Image(systemName: peer.isTrusted ? "laptopcomputer.and.iphone" : "desktopcomputer")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isCurrent ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 38, height: 38)
                .background(
                    (isCurrent ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 13, weight: .semibold))
                    if peer.isTrusted {
                        Text(isSessionPaused ? "本次已手动断开" : "已配对信任")
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
                Text("\(peer.host ?? "Bonjour 局域网发现") · 端口 \(peer.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)

            if isCurrent {
                RemoteStatusPill(title: "已连通", symbol: "checkmark.circle.fill", tint: RemotePalette.positive)
            } else {
                Button(peer.isTrusted ? "立即连接" : "请求配对") {
                    lanRelay.connectToDiscoveredPeer(peer)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(11)
        .background(.primary.opacity(isCurrent ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private func trustedPeerCompactRow(_ peer: RemoteTrustedPeer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(RemotePalette.positive)
            Text(peer.name).font(.system(size: 12.5, weight: .semibold))
            Text(peer.lastHost.map { "\($0):\(peer.lastPort)" } ?? "已保存共享密钥")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if lanRelay.connectedPeerID != peer.id, let host = peer.lastHost {
                Button("按上次 IP 重连") { _ = lanRelay.connectToAddress("\(host):\(peer.lastPort)") }
                    .buttonStyle(RemoteActionButtonStyle())
            }
            Button("移除信任") { lanRelay.removeTrustedPeer(peer.id) }
                .buttonStyle(RemoteActionButtonStyle())
        }
        .padding(9)
        .background(.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Collapsible Hotkey & Port Settings

    private var shortcutAndPortCard: some View {
        RemoteCard(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("双机切换热键：\(lanRelay.switchShortcut.display)", systemImage: "command.square.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Button("修改热键") { showingHotkeyRecorder = true }
                        .buttonStyle(RemoteActionButtonStyle())
                    Button("绑定到遥控器按键", action: onOpenRemoteMapping)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    Spacer()
                    Button(showShortcutAndPortDetails ? "收起端口与反馈设置" : "端口与切换反馈设置") {
                        showShortcutAndPortDetails.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }

                if showShortcutAndPortDetails {
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        Text("本机显示名：").font(.system(size: 12))
                        TextField("本机名称", text: $lanRelay.localPeerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                        Text("共享端口：").font(.system(size: 12))
                        TextField("49280", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 84)
                            .onSubmit { applyPortUpdate() }
                        Button("应用端口") { applyPortUpdate() }
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

                    HStack(spacing: 16) {
                        Toggle("启用全局切换热键", isOn: $lanRelay.switchHotkeyEnabled).toggleStyle(.switch)
                        Toggle("屏幕顶部灵动胶囊", isOn: $lanRelay.switchHUDEnabled).toggleStyle(.switch)
                        Toggle("切换轻音效", isOn: $lanRelay.switchSoundEnabled).toggleStyle(.switch)
                        Button("预览提示") { lanRelay.previewLocalSwitchNotification() }
                            .buttonStyle(.link)
                        Spacer()
                        Button("查看双机通信日志 →", action: onOpenNetworkLogs)
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
        portSaveHint = "已切换至端口 \(lanRelay.sharedPort)，请确保另一台 Mac 也使用相同端口"
    }
}
