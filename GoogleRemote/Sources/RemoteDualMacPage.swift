import AppKit
import SwiftUI

struct RemoteDualMacPage: View {
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    let onOpenRemoteMapping: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenBackupSettings: () -> Void

    @State private var manualHostInput = ""
    @State private var portInput = ""
    @State private var showingHotkeyRecorder = false
    @State private var showManualConnect = false
    @State private var showNetworkLogs = false
    @State private var copiedIP = false
    @State private var portSaveHint: String?
    @State private var pendingSyncStrategy: RemoteConfigSyncStrategy?

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

            targetSwitchHeroCard

            remoteMappingAndConfigSyncRow

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    discoveryAndPairingCard
                        .frame(minWidth: 380, maxWidth: .infinity)
                    shortcutAndPortCard
                        .frame(minWidth: 340, maxWidth: 440)
                }
                VStack(spacing: 16) {
                    discoveryAndPairingCard
                    shortcutAndPortCard
                }
            }

            if !lanRelay.trustedPeers.isEmpty {
                trustedPeersCard
            }

            advancedDiagnosticsCard
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
        .confirmationDialog(
            pendingSyncStrategy == .overwrite
                ? "确认用「\(remoteDisplayName)」的配置完整覆盖本机？"
                : "从「\(remoteDisplayName)」合并补全配置到本机？",
            isPresented: Binding(
                get: { pendingSyncStrategy != nil },
                set: { if !$0 { pendingSyncStrategy = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let strategy = pendingSyncStrategy {
                Button(
                    strategy == .overwrite ? "确认完整覆盖本机配置" : "确认合并补全（保留已有按键）",
                    role: strategy == .overwrite ? .destructive : nil
                ) {
                    lanRelay.requestPeerConfigSync(strategy: strategy)
                    pendingSyncStrategy = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingSyncStrategy = nil
            }
        } message: {
            Text(pendingSyncStrategy?.explanation ?? "")
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
                    Text("「\(request.peerName)」请求局域网配对连接")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Text("请核对配对码一致：")
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
                HStack(spacing: 10) {
                    Button("拒绝") {
                        lanRelay.rejectIncomingPairing()
                    }
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

    // MARK: - Hero Target Switcher

    private var targetSwitchHeroCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    RemoteSectionTitle(
                        title: "一个遥控器，无缝控制两台 Mac",
                        subtitle: "遥控器蓝牙只需连接主机；已配对过的 Mac 在同一局域网打开即自动连接，按快捷键随时切换",
                        symbol: "macbook.and.ipad"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: lanRelay.isConnected
                            ? (lanRelay.latencyMs.map { String(format: "已连通 · %.1f ms", $0) } ?? "已连通")
                            : (lanRelay.isListening ? "同端口 \(lanRelay.sharedPort) 待命" : "服务已关闭"),
                        symbol: lanRelay.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right",
                        tint: lanRelay.isConnected ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                HStack(spacing: 12) {
                    RemoteVisualOption(
                        title: "控制本机 Mac",
                        subtitle: "本机：\(lanRelay.localPeerName) · 遥控器操作直接在本机生效",
                        symbol: "desktopcomputer",
                        selected: lanRelay.activeTarget == .localMac,
                        action: { lanRelay.setTarget(.localMac, showHUD: true) }
                    )

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)

                    RemoteVisualOption(
                        title: lanRelay.connectedPeerName.map { "转发至「\($0)」" } ?? "转发至另一台 Mac",
                        subtitle: lanRelay.isConnected
                            ? "按 \(lanRelay.switchShortcut.display) 或点击此处立即切过去"
                            : "已配对设备上线后会自动连接，首次使用请在下方点击配对",
                        symbol: "macbook.and.ipad",
                        selected: lanRelay.activeTarget == .remoteMac,
                        action: { lanRelay.setTarget(.remoteMac, showHUD: true) }
                    )
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

    // MARK: - Remote Mapping Follow Policy + One-Click Configuration Sync

    private var remoteMappingAndConfigSyncRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                remoteMappingFollowCard
                    .frame(minWidth: 380, maxWidth: .infinity)
                configSyncCard
                    .frame(minWidth: 340, maxWidth: 460)
            }
            VStack(spacing: 16) {
                remoteMappingFollowCard
                configSyncCard
            }
        }
    }

    private var remoteMappingFollowCard: some View {
        let isReceiver = lanRelay.isActingAsReceiverMac
        let followSource = lanRelay.localMappingFollowSource
        return RemoteCard {
            VStack(alignment: .leading, spacing: 13) {
                RemoteSectionTitle(
                    title: "远程控制时的遥控器设置跟随方式",
                    subtitle: isReceiver
                        ? "当前这台 Mac 被远程控制时，选择使用远程主控端的按键设置还是本机设置"
                        : "转发遥控器到远程 Mac 时，选择跟随远程 Mac 的设置还是跟随本机设置",
                    symbol: "slider.horizontal.2.square"
                )

                VStack(spacing: 9) {
                    RemoteVisualOption(
                        title: "跟随远程的遥控器设置",
                        subtitle: isReceiver
                            ? "直接沿用远程主控「\(remoteDisplayName)」设好的快捷键、系统动作与长按，本机无需再配一遍"
                            : "只把按键与长按信号发给「\(remoteDisplayName)」，由远程 Mac 按它自己保存的按键配置执行",
                        symbol: "macbook.and.ipad",
                        selected: followSource == .followRemoteMac,
                        compact: true,
                        action: { lanRelay.setMappingFollowSource(.followRemoteMac) }
                    )

                    RemoteVisualOption(
                        title: "跟随本机的遥控器设置",
                        subtitle: isReceiver
                            ? "收到远程按键时，按本机「\(lanRelay.localPeerName)」自己保存的遥控器映射方案执行"
                            : "直接把本机「\(lanRelay.localPeerName)」设好的快捷键、系统动作与长按发给对方执行",
                        symbol: "desktopcomputer",
                        selected: followSource == .followLocalMac,
                        compact: true,
                        action: { lanRelay.setMappingFollowSource(.followLocalMac) }
                    )
                }
            }
        }
    }

    private var configSyncCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 8) {
                    RemoteSectionTitle(
                        title: "一键同步已连接 Mac 的配置",
                        subtitle: "把对端「\(remoteDisplayName)」的按键映射、命名方案与动作库拉取到本机",
                        symbol: "arrow.triangle.2.circlepath.circle"
                    )
                    Spacer(minLength: 4)
                    if lanRelay.isSyncingConfig {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("• **合并补全**：只补充本机未配置的空按键与新方案，保留本机已有按键绑定。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("• **完整覆盖**：用已连接 Mac 的配置替换本机按键方案，让两台电脑完全一致。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        pendingSyncStrategy = .merge
                    } label: {
                        Label("合并同步（保留已有）", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)

                    Button {
                        pendingSyncStrategy = .overwrite
                    } label: {
                        Label("覆盖同步（完全一致）", systemImage: "square.stack.3d.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!lanRelay.isConnected || lanRelay.isSyncingConfig)
                }

                if let syncMsg = lanRelay.lastConfigSyncMessage {
                    Label(syncMsg, systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !lanRelay.isConnected {
                    HStack(spacing: 6) {
                        Text("未连局域网时也可通过 JSON 备份文件迁移配置。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("备份 / 导出导入文件") {
                            onOpenBackupSettings()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("管理本地备份与导出导入 JSON") {
                            onOpenBackupSettings()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    // MARK: - Discovery & One-Click Pairing Card

    private var discoveryAndPairingCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "局域网自动发现与自动连接",
                        subtitle: "已配对过的 Mac 在线时自动静默重连；新设备需点击并发起 6 位配对确认",
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
                    Toggle("自动连接已配对过的 Mac（未配对设备绝不自动连接）", isOn: $lanRelay.autoConnectTrustedPeer)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    if !lanRelay.pausedAutoConnectPeerIDs.isEmpty && !lanRelay.isConnected {
                        Button("恢复本次自动连接") {
                            lanRelay.resumeAutoConnect()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))

                if lanRelay.isConnected, let name = lanRelay.connectedPeerName {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(RemotePalette.positive)
                            .frame(width: 40, height: 40)
                            .background(RemotePalette.positive.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已连接：\(name)")
                                .font(.system(size: 13, weight: .semibold))
                            Text("共享端口 \(lanRelay.sharedPort) · 已转发 \(lanRelay.forwardedCount) 次 / 接收 \(lanRelay.receivedCount) 次")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("断开连接") {
                            lanRelay.disconnectCurrentPeer()
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                    }
                    .padding(12)
                    .background(RemotePalette.positive.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                }

                if lanRelay.discoveredPeers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 18))
                                .foregroundStyle(RemotePalette.indigo)
                            Text("正在自动搜索同一局域网下的其他 Mac（端口 \(lanRelay.sharedPort)）…")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("只需在另一台 Mac 上打开 MoteFlow 并确保两台电脑连在同一个 Wi-Fi / 路由器下；若曾配对过将自动完成加密连接。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 13))
                } else {
                    VStack(spacing: 9) {
                        ForEach(lanRelay.discoveredPeers) { peer in
                            discoveredPeerRow(peer)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showManualConnect) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("如果路由器开启了 AP 隔离导致未能自动发现，可直接输入另一台 Mac 的局域网 IP 连接同一端口（\(lanRelay.sharedPort)）：")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 9) {
                            TextField("输入对端 IP（如 192.168.1.25）", text: $manualHostInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onSubmit { _ = lanRelay.connectToAddress(manualHostInput) }
                            Button("发起配对连接") {
                                _ = lanRelay.connectToAddress(manualHostInput)
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(manualHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("手动输入局域网 IP 直连", systemImage: "network")
                        .font(.system(size: 12, weight: .medium))
                }
                .tint(RemotePalette.indigo)

                HStack {
                    Text(lanRelay.connectionStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("检查本地网络与通知权限") {
                        onOpenPermissions()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
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
                .frame(width: 40, height: 40)
                .background(
                    (isCurrent ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(peer.name)
                        .font(.system(size: 13, weight: .semibold))
                    if peer.isTrusted {
                        Text(isSessionPaused ? "已配对 · 本次已手动断开" : "已配对 · 支持自动连接")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSessionPaused ? RemotePalette.amber : RemotePalette.positive)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (isSessionPaused ? RemotePalette.amber : RemotePalette.positive).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
                Text("\(peer.host ?? "Bonjour 自动发现") · 端口 \(peer.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)

            if isCurrent {
                RemoteStatusPill(title: "已连接", symbol: "checkmark.circle.fill", tint: RemotePalette.positive)
            } else {
                Button(peer.isTrusted ? "立即连接" : "请求配对") {
                    lanRelay.connectToDiscoveredPeer(peer)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(12)
        .background(.primary.opacity(isCurrent ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 13))
    }

    // MARK: - Shortcut & Same-Port Card

    private var shortcutAndPortCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                RemoteSectionTitle(
                    title: "切换快捷键、端口与通知提醒",
                    subtitle: "随时一键切换控制哪台电脑，切回本机时弹出通知提示",
                    symbol: "command.square"
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("全局切换快捷键")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle("启用", isOn: $lanRelay.switchHotkeyEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 11))
                    }
                    HStack(spacing: 10) {
                        RemoteShortcutVisual(shortcut: lanRelay.switchShortcut)
                        Spacer(minLength: 4)
                        Button("修改快捷键") {
                            showingHotkeyRecorder = true
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                    Text(lanRelay.hotkeyMonitor.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(RemotePalette.amber)
                            .font(.system(size: 11))
                        Text("你还可以把遥控器上的「输入源」或「TV」键设为切换双机目标。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("去绑定") {
                            onOpenRemoteMapping()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
                .padding(12)
                .background(RemotePalette.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 9) {
                    Text("双机共用端口号")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField("49280", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 96)
                            .onSubmit { applyPortUpdate() }
                        Button("应用端口") {
                            applyPortUpdate()
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        if lanRelay.sharedPort != RemoteLANPortValidator.defaultPort {
                            Button("恢复默认") {
                                portInput = String(RemoteLANPortValidator.defaultPort)
                                applyPortUpdate()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                        Spacer(minLength: 0)
                    }
                    if let portSaveHint {
                        Text(portSaveHint)
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.indigo)
                    }
                    HStack(spacing: 8) {
                        Text("本机局域网 IP：\(lanRelay.localIPAddresses.isEmpty ? "检测中" : lanRelay.localIPAddresses.joined(separator: " / "))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let firstIP = lanRelay.localIPAddresses.first {
                            Button(copiedIP ? "已复制" : "复制 IP") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(firstIP):\(lanRelay.sharedPort)", forType: .string)
                                copiedIP = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedIP = false }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                }

                Divider().opacity(0.45)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启动双机局域网服务（监听与自动发现）", isOn: $lanRelay.isServiceEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    Toggle("允许已配对的 Mac 向本机发送遥控指令", isOn: $lanRelay.allowIncomingControl)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))

                    Divider().opacity(0.35)

                    Toggle("切换时显示屏幕顶部悬浮提示", isOn: $lanRelay.switchHUDEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    Toggle("切换时弹出 macOS 系统通知", isOn: $lanRelay.switchNotificationsEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    HStack {
                        Toggle("切换时播放提示音", isOn: $lanRelay.switchSoundEnabled)
                            .toggleStyle(.switch)
                            .font(.system(size: 12))
                        Spacer()
                        Button("预览切换效果") {
                            lanRelay.previewLocalSwitchNotification()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    if !lanRelay.switchHUDEnabled && !lanRelay.switchNotificationsEnabled && !lanRelay.switchSoundEnabled {
                        Text("当前已设为完全静默切换（不弹窗、不通知、无提示音）。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Trusted Devices & Logs

    private var trustedPeersCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                RemoteSectionTitle(
                    title: "已配对信任的 Mac（自动连接白名单）",
                    subtitle: "仅下方已配对过的设备会在同一局域网自动静默重连；解除配对后将不再自动连接",
                    symbol: "checkmark.shield"
                )
                ForEach(lanRelay.trustedPeers) { peer in
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(RemotePalette.positive)
                            .frame(width: 32, height: 32)
                            .background(RemotePalette.positive.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(peer.lastHost.map { "\($0):\(peer.lastPort) · " } ?? "")配对于 \(peer.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if lanRelay.connectedPeerID == peer.id {
                            RemoteStatusPill(title: "当前已连", symbol: "checkmark.circle.fill", tint: RemotePalette.positive)
                        } else if let discovered = lanRelay.discoveredPeers.first(where: { $0.id == peer.id }) {
                            Button("立即连接") {
                                lanRelay.connectToDiscoveredPeer(discovered)
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        } else if let host = peer.lastHost {
                            Button("按上次 IP 重连") {
                                _ = lanRelay.connectToAddress("\(host):\(peer.lastPort)")
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                        }
                        Button("解除配对") {
                            lanRelay.removeTrustedPeer(peer.id)
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                    }
                    .padding(10)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }
    }

    private var advancedDiagnosticsCard: some View {
        RemoteCard {
            DisclosureGroup(isExpanded: $showNetworkLogs) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("本机显示名：")
                            .font(.system(size: 12, weight: .medium))
                        TextField("本机名称", text: $lanRelay.localPeerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                        Spacer()
                        Button("清空日志") { lanRelay.clearLogs() }
                            .buttonStyle(RemoteActionButtonStyle())
                            .disabled(lanRelay.logs.isEmpty)
                    }
                    if lanRelay.logs.isEmpty {
                        Text("暂无局域网连接日志。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(lanRelay.logs.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 150)
                        .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Label("本机显示名称与网络通信日志", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(lanRelay.listenerStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .tint(RemotePalette.indigo)
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
