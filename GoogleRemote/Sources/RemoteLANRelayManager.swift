import AppKit
import Combine
import Foundation
import Network

/// Coordinates Dual-Mac same-port TCP connection, 6-digit click-to-confirm
/// pairing, mutual HMAC-SHA256 trust authentication, automatic reconnection
/// strictly limited to paired trusted peers, bidirectional mapping-follow mode
/// & one-click configuration sync (merge / overwrite), target switching with
/// macOS system notifications, and real-time action/hold/PCM forwarding.
@MainActor
final class RemoteLANRelayManager: ObservableObject {
    @Published var isServiceEnabled: Bool {
        didSet {
            defaults.set(isServiceEnabled, forKey: Self.enabledKey)
            if isServiceEnabled {
                startNetworkServices()
            } else {
                stopNetworkServices(reason: "已关闭双机互联服务")
            }
        }
    }

    @Published private(set) var sharedPort: UInt16
    @Published var allowIncomingControl: Bool {
        didSet { defaults.set(allowIncomingControl, forKey: Self.allowIncomingKey) }
    }
    @Published var autoConnectTrustedPeer: Bool {
        didSet {
            defaults.set(autoConnectTrustedPeer, forKey: Self.autoConnectKey)
            if autoConnectTrustedPeer {
                pausedAutoConnectPeerIDs.removeAll()
                scheduleAutoConnectCheck()
            } else {
                autoConnectDebounceTask?.cancel()
                autoConnectDebounceTask = nil
            }
        }
    }
    @Published var dispatchMode: RemoteRelayDispatchMode {
        didSet {
            defaults.set(dispatchMode.rawValue, forKey: Self.dispatchModeKey)
            if !suppressStateEcho {
                broadcastLocalPeerState()
            }
        }
    }
    @Published var switchHUDEnabled: Bool {
        didSet { defaults.set(switchHUDEnabled, forKey: Self.switchHUDKey) }
    }
    @Published var switchNotificationsEnabled: Bool {
        didSet {
            defaults.set(switchNotificationsEnabled, forKey: Self.switchNotifyKey)
            if switchNotificationsEnabled {
                RemoteSwitchNotificationCenter.shared.requestAuthorizationIfNeeded()
            }
        }
    }
    @Published var switchSoundEnabled: Bool {
        didSet { defaults.set(switchSoundEnabled, forKey: Self.switchSoundKey) }
    }
    @Published var switchHotkeyEnabled: Bool {
        didSet {
            defaults.set(switchHotkeyEnabled, forKey: Self.hotkeyEnabledKey)
            hotkeyMonitor.update(shortcut: switchShortcut, enabled: switchHotkeyEnabled)
        }
    }
    @Published private(set) var switchShortcut: RemoteShortcut

    @Published private(set) var activeTarget: RemoteControlTarget = .localMac
    @Published private(set) var isListening = false
    @Published private(set) var listenerStatus = "双机服务未启动"
    @Published private(set) var connectionStatus = "尚未连接另一台 Mac"
    @Published private(set) var isConnected = false
    @Published private(set) var isPairingInProgress = false
    @Published private(set) var outgoingPairingCode: String?
    @Published private(set) var incomingPairingRequest: RemoteIncomingPairingRequest?
    @Published private(set) var connectedPeerID: String?
    @Published private(set) var connectedPeerName: String?
    @Published private(set) var peerHasPhysicalRemote = false
    @Published private(set) var localHasPhysicalRemote = false
    @Published private(set) var isControlledByPeer = false
    @Published private(set) var controllingPeerName: String?
    @Published private(set) var latencyMs: Double?
    @Published private(set) var forwardedCount = 0
    @Published private(set) var receivedCount = 0
    @Published private(set) var discoveredPeers: [RemoteDiscoveredPeer] = []
    @Published private(set) var trustedPeers: [RemoteTrustedPeer] = []
    @Published private(set) var pausedAutoConnectPeerIDs: Set<String> = []
    @Published private(set) var isSyncingConfig = false
    @Published private(set) var lastConfigSyncMessage: String?
    @Published private(set) var localIPAddresses: [String] = []
    @Published private(set) var logs: [String] = []

    let localPeerID: String
    @Published var localPeerName: String {
        didSet {
            let trimmed = localPeerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            defaults.set(trimmed, forKey: Self.peerNameKey)
            if isServiceEnabled { restartListener() }
        }
    }

    let hotkeyMonitor = RemoteGlobalHotkeyMonitor()
    private let discovery = RemoteLANDiscoveryService()

    // Coordinator callbacks
    var onReleaseLocalHoldsBeforeSwitch: (() -> Void)?
    var onIncomingAction: ((
        RemoteKey,
        RemoteGesture,
        RemoteRelayDispatchMode,
        RemoteDeviceModel,
        RemoteShortcut?,
        Double?,
        RemoteSystemAction?,
        [RemoteLANForwardedStep]?
    ) -> Void)?
    var onIncomingHoldStart: ((RemoteKey, RemoteRelayDispatchMode, RemoteDeviceModel, RemoteShortcut?) -> Void)?
    var onIncomingHoldEnd: ((RemoteKey?) -> Void)?
    var onIncomingVoiceStart: ((Int, RemoteRelayDispatchMode, RemoteShortcut?, DoubaoShortcutTrigger) -> Void)?
    var onIncomingVoicePCM: (([Int16], Int) -> Void)?
    var onIncomingVoiceEnd: (() -> Void)?
    var onExportLocalConfig: (() -> RemoteSyncConfigSnapshot?)?
    var onApplySyncedConfig: ((RemoteSyncConfigSnapshot, RemoteConfigSyncStrategy) -> RemoteConfigSyncResult?)?

    // Optional in-memory transport hook for deterministic unit/integration testing
    var testTransportSender: ((Data) -> Void)?
    var suppressPromptWindowsForTesting = false

    private let defaults: UserDefaults
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var deframer = RemoteLANFrameCodec.StreamDeframer()
    private var isAuthenticatedSession = false
    private var isOutgoingInitiator = false
    private var isAutomaticConnectionAttempt = false
    private var pendingOutgoingPeerID: String?
    private var suppressStateEcho = false

    private var serverNonce: String?
    private var clientNonce: String?
    private var pendingProposedSecretHex: String?
    private var pendingRequestID: UUID?
    private var pendingClientPeerID: String?
    private var pendingClientPeerName: String?
    private var pendingConfigSyncRequestID: UUID?
    private var pendingConfigSyncStrategy: RemoteConfigSyncStrategy?
    private var lastAttemptedHost: String?
    private var lastAttemptedPort: UInt16?
    private var manualForcedPairing = false
    private var lastAutoConnectAttemptByPeer: [String: Date] = [:]

    private var pingTask: Task<Void, Never>?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var configSyncTimeoutTask: Task<Void, Never>?
    private var stalePruneTask: Task<Void, Never>?
    private var autoReconnectLoopTask: Task<Void, Never>?
    private var autoConnectDebounceTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var activeForwardedHolds: Set<RemoteKey> = []
    private var activeForwardedVoice = false

    private static let enabledKey = "MoteFlow.lanRelay.enabled.v1"
    private static let portKey = "MoteFlow.lanRelay.port.v1"
    private static let peerIDKey = "MoteFlow.lanRelay.peerID.v1"
    private static let peerNameKey = "MoteFlow.lanRelay.peerName.v1"
    private static let trustedPeersKey = "MoteFlow.lanRelay.trustedPeers.v1"
    private static let allowIncomingKey = "MoteFlow.lanRelay.allowIncoming.v1"
    private static let autoConnectKey = "MoteFlow.lanRelay.autoConnectTrusted.v1"
    private static let dispatchModeKey = "MoteFlow.lanRelay.dispatchMode.v1"
    private static let switchHUDKey = "MoteFlow.lanRelay.switchHUD.v1"
    private static let switchNotifyKey = "MoteFlow.lanRelay.switchNotifications.v1"
    private static let switchSoundKey = "MoteFlow.lanRelay.switchSound.v1"
    private static let hotkeyEnabledKey = "MoteFlow.lanRelay.switchHotkeyEnabled.v1"
    private static let hotkeyDataKey = "MoteFlow.lanRelay.switchHotkey.v1"
    private static let lastConnectedPeerKey = "MoteFlow.lanRelay.lastConnectedPeerID.v1"

    init(defaults: UserDefaults = .standard, startImmediately: Bool = true) {
        self.defaults = defaults
        if let savedID = defaults.string(forKey: Self.peerIDKey), !savedID.isEmpty {
            localPeerID = savedID
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.peerIDKey)
            localPeerID = fresh
        }

        let defaultHostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        localPeerName = defaults.string(forKey: Self.peerNameKey) ?? defaultHostName

        let rawPort = defaults.integer(forKey: Self.portKey)
        sharedPort = RemoteLANPortValidator.validatedPort(rawPort) ?? RemoteLANPortValidator.defaultPort

        allowIncomingControl = defaults.object(forKey: Self.allowIncomingKey) as? Bool ?? true
        autoConnectTrustedPeer = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
        switchHUDEnabled = defaults.object(forKey: Self.switchHUDKey) as? Bool ?? true
        switchNotificationsEnabled = defaults.object(forKey: Self.switchNotifyKey) as? Bool ?? true
        switchSoundEnabled = defaults.object(forKey: Self.switchSoundKey) as? Bool ?? true
        dispatchMode = RemoteRelayDispatchMode(
            rawValue: defaults.string(forKey: Self.dispatchModeKey) ?? ""
        ) ?? .senderMapping

        if let shortcutData = defaults.data(forKey: Self.hotkeyDataKey),
           let decoded = try? JSONDecoder().decode(RemoteShortcut.self, from: shortcutData) {
            switchShortcut = decoded
        } else {
            switchShortcut = RemoteGlobalHotkeyMonitor.defaultSwitchShortcut
        }
        switchHotkeyEnabled = defaults.object(forKey: Self.hotkeyEnabledKey) as? Bool ?? true
        isServiceEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true

        if let data = defaults.data(forKey: Self.trustedPeersKey),
           let saved = try? JSONDecoder().decode([RemoteTrustedPeer].self, from: data) {
            trustedPeers = saved
        }

        wireDiscoveryCallbacks()
        refreshLocalIPs()
        hotkeyMonitor.onTrigger = { [weak self] in
            self?.toggleTarget(showHUD: true)
        }
        if startImmediately {
            if switchNotificationsEnabled {
                RemoteSwitchNotificationCenter.shared.requestAuthorizationIfNeeded()
            }
            hotkeyMonitor.update(shortcut: switchShortcut, enabled: switchHotkeyEnabled)
            installWakeObserver()
            if isServiceEnabled {
                startNetworkServices()
            }
        }
    }

    var isForwardingToRemoteMac: Bool {
        activeTarget == .remoteMac && isConnected && isAuthenticatedSession
    }

    /// True when this Mac is acting as the remote-controlled receiver (either actively
    /// controlled by the peer, or the peer holds the physical remote while this Mac does not).
    var isActingAsReceiverMac: Bool {
        if isControlledByPeer { return true }
        if localHasPhysicalRemote || activeTarget == .remoteMac { return false }
        if peerHasPhysicalRemote { return true }
        return false
    }

    /// Current mapping follow choice from the perspective of this Mac's screen.
    var localMappingFollowSource: RemoteMappingFollowSource {
        RemoteMappingFollowSource.from(
            dispatchMode: dispatchMode,
            localIsReceiver: isActingAsReceiverMac
        )
    }

    func setMappingFollowSource(_ choice: RemoteMappingFollowSource) {
        let resolved = choice.resolvedDispatchMode(localIsReceiver: isActingAsReceiverMac)
        dispatchMode = resolved
        let modeDesc = choice == .followLocalMac
            ? "跟随本机（\(localPeerName)）的遥控器配置"
            : "跟随远程（\(connectedPeerName ?? "另一台 Mac")）的遥控器配置"
        log("远程映射策略已切换为：\(modeDesc)")
    }

    func updateLocalHardwarePresence(_ hasPhysicalRemote: Bool) {
        guard localHasPhysicalRemote != hasPhysicalRemote else { return }
        localHasPhysicalRemote = hasPhysicalRemote
        broadcastLocalPeerState()
    }

    private func broadcastLocalPeerState() {
        guard isConnected && isAuthenticatedSession else { return }
        sendWireMessage(
            .peerStateSync(dispatchMode: dispatchMode, hasPhysicalRemote: localHasPhysicalRemote)
        )
    }

    // MARK: - One-Click Configuration Sync (Merge / Overwrite)

    func requestPeerConfigSync(strategy: RemoteConfigSyncStrategy) {
        guard isConnected && isAuthenticatedSession else {
            lastConfigSyncMessage = "尚未连接另一台已配对的 Mac，请先连接后再同步配置。"
            return
        }
        let reqID = UUID()
        pendingConfigSyncRequestID = reqID
        pendingConfigSyncStrategy = strategy
        isSyncingConfig = true
        lastConfigSyncMessage = "正在从「\(connectedPeerName ?? "对端 Mac")」拉取配置（\(strategy.shortTitle)）…"
        sendWireMessage(.requestConfigSnapshot(requestID: reqID))

        configSyncTimeoutTask?.cancel()
        configSyncTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self,
                  self.pendingConfigSyncRequestID == reqID else { return }
            self.isSyncingConfig = false
            self.pendingConfigSyncRequestID = nil
            self.pendingConfigSyncStrategy = nil
            self.lastConfigSyncMessage = "同步超时：请确认另一台 Mac 上的 MoteFlow 已升级到最新版本。"
        }
    }

    // MARK: - Settings & Notifications

    @discardableResult
    func updateSharedPort(_ portNumber: Int) -> Bool {
        guard let valid = RemoteLANPortValidator.validatedPort(portNumber) else {
            log("端口号无效：请输入 1024–65535 之间的端口")
            return false
        }
        guard valid != sharedPort else { return true }
        sharedPort = valid
        defaults.set(Int(valid), forKey: Self.portKey)
        log("共享端口已更新为 \(valid)")
        if isServiceEnabled {
            disconnectCurrentPeer(reason: "端口已更改", pauseSessionAutoConnect: false)
            startNetworkServices()
        }
        return true
    }

    func updateSwitchShortcut(_ shortcut: RemoteShortcut) {
        switchShortcut = shortcut
        if let encoded = try? JSONEncoder().encode(shortcut) {
            defaults.set(encoded, forKey: Self.hotkeyDataKey)
        }
        hotkeyMonitor.update(shortcut: shortcut, enabled: switchHotkeyEnabled)
        log("双机切换快捷键已设为 \(shortcut.display)")
    }

    func previewLocalSwitchNotification() {
        RemoteSwitchNotificationCenter.shared.notifySwitchedToThisMac(
            thisMacName: localPeerName,
            detail: "通知预览 · 按当前「悬浮提示 / 系统通知 / 提示音」设置展示",
            hudEnabled: switchHUDEnabled,
            systemNotificationEnabled: switchNotificationsEnabled,
            soundEnabled: switchSoundEnabled
        )
    }

    func refreshLocalIPs() {
        localIPAddresses = RemoteLANDiscoveryService.currentLANIPv4Addresses()
    }

    // MARK: - Target Switching (Local Mac <-> Remote Mac)

    func toggleTarget(showHUD: Bool = true) {
        setTarget(activeTarget == .remoteMac ? .localMac : .remoteMac, showHUD: showHUD)
    }

    func setTarget(_ target: RemoteControlTarget, showHUD: Bool = true) {
        let shouldShowHUD = showHUD && switchHUDEnabled
        if target == .remoteMac {
            guard isConnected && isAuthenticatedSession else {
                activeTarget = .localMac
                if let candidate = selectPreferredTrustedDiscoveredPeer(ignoreSessionPause: true) {
                    connectToDiscoveredPeer(candidate)
                    if showHUD {
                        RemoteSwitchNotificationCenter.shared.notifyWarning(
                            title: "正在自动连接已配对的「\(candidate.name)」…",
                            detail: "连通后再次按 \(switchShortcut.display) 即可切换",
                            hudEnabled: shouldShowHUD,
                            soundEnabled: switchSoundEnabled
                        )
                    }
                } else if showHUD {
                    RemoteSwitchNotificationCenter.shared.notifyWarning(
                        title: "尚未连接另一台 Mac · 当前仍在「\(localPeerName)」",
                        detail: "请先在「双机互联」页面点击另一台 Mac 完成配对连接",
                        hudEnabled: shouldShowHUD,
                        soundEnabled: switchSoundEnabled
                    )
                }
                return
            }
            onReleaseLocalHoldsBeforeSwitch?()
            activeTarget = .remoteMac
            let peerTitle = connectedPeerName ?? "另一台 Mac"
            sendWireMessage(.focusChanged(controllingReceiver: true, controllerName: localPeerName))
            log("切换控制目标 → 远端 Mac「\(peerTitle)」")
            if showHUD {
                RemoteSwitchNotificationCenter.shared.notifySwitchedToOtherMac(
                    otherMacName: peerTitle,
                    detail: "遥控器已转发至「\(peerTitle)」· 按 \(switchShortcut.display) 切回本机",
                    hudEnabled: shouldShowHUD,
                    systemNotificationEnabled: switchNotificationsEnabled,
                    soundEnabled: switchSoundEnabled
                )
            }
        } else {
            let wasRemote = (activeTarget == .remoteMac)
            if wasRemote {
                flushForwardedHoldsAndVoice()
                sendWireMessage(.focusChanged(controllingReceiver: false, controllerName: localPeerName))
            }
            activeTarget = .localMac
            log("切换控制目标 → 本机「\(localPeerName)」")
            if showHUD {
                RemoteSwitchNotificationCenter.shared.notifySwitchedToThisMac(
                    thisMacName: localPeerName,
                    detail: "遥控器现在直接控制这台 Mac（\(localPeerName)）",
                    hudEnabled: shouldShowHUD,
                    systemNotificationEnabled: switchNotificationsEnabled,
                    soundEnabled: switchSoundEnabled
                )
            }
        }
    }

    // MARK: - Discovery, TCP Listener & Auto-Connect (Strictly Paired Trusted Peers Only)

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isServiceEnabled else { return }
                self.log("检测到 Mac 唤醒，正在刷新局域网并尝试自动重连已配对设备…")
                self.refreshLocalIPs()
                self.startNetworkServices()
            }
        }
    }

    private func wireDiscoveryCallbacks() {
        discovery.onPeerDiscovered = { [weak self] id, name, host, port, viaBonjour in
            guard let self else { return }
            self.upsertDiscoveredPeer(id: id, name: name, host: host, port: port, viaBonjour: viaBonjour)
            self.scheduleAutoConnectCheck()
        }
        discovery.onBonjourPeersSnapshot = { [weak self] activeIDs in
            guard let self else { return }
            self.discoveredPeers.removeAll { peer in
                peer.viaBonjour && peer.host == nil && !activeIDs.contains(peer.id)
            }
        }
        discovery.onLog = { [weak self] msg in self?.log(msg) }
    }

    func startNetworkServices() {
        stopListenerAndDiscoveryOnly()
        refreshLocalIPs()
        startTCPListener()
        discovery.start(
            localPeerID: localPeerID,
            localPeerName: localPeerName,
            port: sharedPort,
            localIPsProvider: { [weak self] in self?.localIPAddresses ?? [] }
        )
        stalePruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let now = Date()
                self.discoveredPeers.removeAll {
                    !$0.viaBonjour && now.timeIntervalSince($0.lastSeen) > 14
                }
            }
        }
        autoReconnectLoopTask = Task { [weak self] in
            // Initial grace scan for cached subnet peers if UDP broadcast is filtered
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                guard let self else { return }
                if self.isServiceEnabled && self.autoConnectTrustedPeer &&
                    !self.isConnected && !self.isPairingInProgress && self.activeConnection == nil {
                    self.attemptAutoConnectNow(allowCachedSubnetFallback: true)
                }
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func stopNetworkServices(reason: String) {
        disconnectCurrentPeer(reason: reason, pauseSessionAutoConnect: false)
        stopListenerAndDiscoveryOnly()
        isListening = false
        listenerStatus = reason
    }

    func refreshDiscovery() {
        refreshLocalIPs()
        guard isServiceEnabled else {
            isServiceEnabled = true
            return
        }
        discovery.triggerImmediateScan(
            localPeerID: localPeerID,
            localPeerName: localPeerName,
            port: sharedPort,
            localIPs: localIPAddresses
        )
        scheduleAutoConnectCheck()
        log("已刷新局域网设备扫描（端口 \(sharedPort)）")
    }

    func resumeAutoConnect() {
        pausedAutoConnectPeerIDs.removeAll()
        lastAutoConnectAttemptByPeer.removeAll()
        if !autoConnectTrustedPeer {
            autoConnectTrustedPeer = true
        } else {
            attemptAutoConnectNow(allowCachedSubnetFallback: true)
        }
    }

    private func restartListener() {
        stopListenerAndDiscoveryOnly()
        startNetworkServices()
    }

    private func stopListenerAndDiscoveryOnly() {
        listener?.cancel()
        listener = nil
        stalePruneTask?.cancel()
        stalePruneTask = nil
        autoReconnectLoopTask?.cancel()
        autoReconnectLoopTask = nil
        autoConnectDebounceTask?.cancel()
        autoConnectDebounceTask = nil
        discovery.stop()
    }

    private func makeTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    private func startTCPListener() {
        guard let nwPort = NWEndpoint.Port(rawValue: sharedPort) else { return }
        do {
            let tcpListener = try NWListener(using: makeTCPParameters(), on: nwPort)
            var txt = NWTXTRecord()
            txt["peerID"] = localPeerID
            txt["name"] = localPeerName
            txt["port"] = String(sharedPort)
            tcpListener.service = NWListener.Service(
                name: "\(localPeerName)-\(localPeerID.prefix(6))",
                type: RemoteLANPortValidator.bonjourServiceType,
                txtRecord: txt
            )
            tcpListener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.listenerStatus = "正在监听局域网端口 \(self.sharedPort) · 自动发现已开启"
                    case .failed(let error):
                        self.isListening = false
                        self.listenerStatus = "端口 \(self.sharedPort) 监听失败：\(error.localizedDescription)"
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }
            tcpListener.newConnectionHandler = { [weak self] incoming in
                MainActor.assumeIsolated {
                    self?.acceptIncomingConnection(incoming)
                }
            }
            tcpListener.start(queue: .main)
            listener = tcpListener
        } catch {
            isListening = false
            listenerStatus = "无法绑定端口 \(sharedPort)：\(error.localizedDescription)"
        }
    }

    func upsertDiscoveredPeerForTesting(
        id: String,
        name: String,
        host: String?,
        port: UInt16 = RemoteLANPortValidator.defaultPort
    ) {
        upsertDiscoveredPeer(id: id, name: name, host: host, port: port, viaBonjour: false)
    }

    private func upsertDiscoveredPeer(
        id: String,
        name: String,
        host: String?,
        port: UInt16,
        viaBonjour: Bool
    ) {
        let trusted = trustedPeers.contains(where: { $0.id == id })
        if let idx = discoveredPeers.firstIndex(where: { $0.id == id }) {
            let existing = discoveredPeers[idx]
            discoveredPeers[idx] = RemoteDiscoveredPeer(
                id: id,
                name: name,
                host: host ?? existing.host,
                port: port,
                viaBonjour: viaBonjour || existing.viaBonjour,
                isTrusted: trusted,
                lastSeen: Date()
            )
        } else {
            discoveredPeers.append(RemoteDiscoveredPeer(
                id: id,
                name: name,
                host: host,
                port: port,
                viaBonjour: viaBonjour,
                isTrusted: trusted,
                lastSeen: Date()
            ))
            log("自动发现局域网 Mac：\(name)\(host.map { " (\($0):\(port))" } ?? "")")
        }
    }

    /// Selects the highest-priority discovered peer that is ALREADY in `trustedPeers`.
    /// Unpaired peers are strictly excluded from automatic connection.
    func selectPreferredTrustedDiscoveredPeer(ignoreSessionPause: Bool = false) -> RemoteDiscoveredPeer? {
        let eligible = discoveredPeers.filter { peer in
            trustedPeers.contains(where: { $0.id == peer.id }) &&
            (ignoreSessionPause || !pausedAutoConnectPeerIDs.contains(peer.id))
        }
        guard !eligible.isEmpty else { return nil }
        if let lastID = defaults.string(forKey: Self.lastConnectedPeerKey),
           let preferred = eligible.first(where: { $0.id == lastID }) {
            return preferred
        }
        // Otherwise pick the most recently paired trusted peer among discovered candidates
        return eligible.max { lhs, rhs in
            let lDate = trustedPeers.first(where: { $0.id == lhs.id })?.pairedAt ?? .distantPast
            let rDate = trustedPeers.first(where: { $0.id == rhs.id })?.pairedAt ?? .distantPast
            return lDate < rDate
        }
    }

    private func scheduleAutoConnectCheck() {
        guard isServiceEnabled, autoConnectTrustedPeer,
              activeConnection == nil, !isConnected, !isPairingInProgress,
              let candidate = selectPreferredTrustedDiscoveredPeer() else { return }

        let delay = RemoteLANAuth.autoConnectDelaySeconds(
            localPeerID: localPeerID,
            remotePeerID: candidate.id
        )
        autoConnectDebounceTask?.cancel()
        autoConnectDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.attemptAutoConnectNow(allowCachedSubnetFallback: false)
        }
    }

    private func attemptAutoConnectNow(allowCachedSubnetFallback: Bool) {
        guard isServiceEnabled, autoConnectTrustedPeer,
              activeConnection == nil, !isConnected, !isPairingInProgress else { return }
        let now = Date()

        if let candidate = selectPreferredTrustedDiscoveredPeer() {
            if let lastTry = lastAutoConnectAttemptByPeer[candidate.id],
               now.timeIntervalSince(lastTry) < 5.0 {
                return
            }
            lastAutoConnectAttemptByPeer[candidate.id] = now
            log("检测到已配对设备「\(candidate.name)」在线，正在自动发起安全连接…")
            connectToDiscoveredPeer(candidate, isAutomatic: true)
            return
        }

        // Fallback: if router filters broadcast/Bonjour, try a paired peer's last known IP
        // on the same /24 IPv4 subnet. Handshake still strictly verifies `trustedPeers`.
        guard allowCachedSubnetFallback, !localIPAddresses.isEmpty else { return }
        let orderedTrusted = trustedPeers
            .filter { !pausedAutoConnectPeerIDs.contains($0.id) }
            .sorted { $0.pairedAt > $1.pairedAt }

        for trusted in orderedTrusted {
            guard let host = trusted.lastHost,
                  localIPAddresses.contains(where: { RemoteLANPortValidator.sameIPv4Subnet($0, host) }) else {
                continue
            }
            if let lastTry = lastAutoConnectAttemptByPeer[trusted.id],
               now.timeIntervalSince(lastTry) < 12.0 {
                continue
            }
            lastAutoConnectAttemptByPeer[trusted.id] = now
            let port = trusted.lastPort > 0 ? trusted.lastPort : sharedPort
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            lastAttemptedHost = host
            lastAttemptedPort = port
            openOutgoingConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                displayTarget: "\(trusted.name) (\(host):\(port))",
                targetPeerID: trusted.id,
                isAutomatic: true
            )
            return
        }
    }

    // MARK: - Connecting & Pairing

    func connectToDiscoveredPeer(
        _ peer: RemoteDiscoveredPeer,
        forceRepair: Bool = false,
        isAutomatic: Bool = false
    ) {
        if isAutomatic {
            // Hard security invariant: auto-connect NEVER runs for unpaired devices.
            guard trustedPeers.contains(where: { $0.id == peer.id }) else { return }
        } else {
            pausedAutoConnectPeerIDs.remove(peer.id)
        }
        if !isServiceEnabled { isServiceEnabled = true }
        manualForcedPairing = isAutomatic ? false : forceRepair
        if let host = peer.host, !host.isEmpty,
           let nwPort = NWEndpoint.Port(rawValue: peer.port) {
            lastAttemptedHost = host
            lastAttemptedPort = peer.port
            openOutgoingConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                displayTarget: "\(peer.name) (\(host):\(peer.port))",
                targetPeerID: peer.id,
                isAutomatic: isAutomatic
            )
        } else if let serviceEndpoint = discovery.bonjourEndpoints[peer.id] {
            lastAttemptedHost = nil
            lastAttemptedPort = peer.port
            openOutgoingConnection(
                to: serviceEndpoint,
                displayTarget: peer.name,
                targetPeerID: peer.id,
                isAutomatic: isAutomatic
            )
        }
    }

    @discardableResult
    func connectToAddress(_ rawInput: String, forcePairing: Bool = false) -> Bool {
        guard let parsed = RemoteLANPortValidator.parseEndpoint(rawInput, fallbackPort: sharedPort),
              let nwPort = NWEndpoint.Port(rawValue: parsed.port) else {
            connectionStatus = "地址格式无效：请输入局域网 IP（默认共用端口 \(sharedPort)）"
            return false
        }
        if !isServiceEnabled { isServiceEnabled = true }
        pausedAutoConnectPeerIDs.removeAll()
        manualForcedPairing = forcePairing
        lastAttemptedHost = parsed.host
        lastAttemptedPort = parsed.port
        openOutgoingConnection(
            to: .hostPort(host: NWEndpoint.Host(parsed.host), port: nwPort),
            displayTarget: "\(parsed.host):\(parsed.port)",
            targetPeerID: nil,
            isAutomatic: false
        )
        return true
    }

    /// Deterministic in-memory peer pipe used by automated tests without opening OS sockets.
    static func connectInMemoryPairForTesting(
        client: RemoteLANRelayManager,
        server: RemoteLANRelayManager,
        isAutomatic: Bool = false
    ) {
        client.suppressPromptWindowsForTesting = true
        server.suppressPromptWindowsForTesting = true
        client.disconnectCurrentPeer(reason: "测试重置", pauseSessionAutoConnect: false)
        server.disconnectCurrentPeer(reason: "测试重置", pauseSessionAutoConnect: false)
        client.isOutgoingInitiator = true
        client.isAutomaticConnectionAttempt = isAutomatic
        client.pendingOutgoingPeerID = server.localPeerID
        server.isOutgoingInitiator = false
        server.isAutomaticConnectionAttempt = false
        client.testTransportSender = { [weak server] data in
            server?.receiveChunkData(data)
        }
        server.testTransportSender = { [weak client] data in
            client?.receiveChunkData(data)
        }
        let nonce = RemoteLANAuth.randomHex(byteCount: 16)
        server.serverNonce = nonce
        server.sendWireMessage(
            .serverChallenge(peerID: server.localPeerID, peerName: server.localPeerName, serverNonce: nonce),
            requireAuth: false
        )
    }

    private func openOutgoingConnection(
        to endpoint: NWEndpoint,
        displayTarget: String,
        targetPeerID: String?,
        isAutomatic: Bool
    ) {
        autoConnectDebounceTask?.cancel()
        autoConnectDebounceTask = nil
        disconnectCurrentPeer(reason: "切换连接目标", pauseSessionAutoConnect: false)
        let conn = NWConnection(to: endpoint, using: makeTCPParameters())
        isOutgoingInitiator = true
        isAutomaticConnectionAttempt = isAutomatic
        pendingOutgoingPeerID = targetPeerID
        isAuthenticatedSession = false
        deframer.reset()
        activeConnection = conn
        connectionStatus = isAutomatic ? "正在自动重连已配对设备 \(displayTarget)…" : "正在连接 \(displayTarget)…"
        log("\(isAutomatic ? "自动重连" : "发起连接") → \(displayTarget)")
        configureConnectionCallbacks(conn)
        conn.start(queue: .main)
    }

    private func acceptIncomingConnection(_ incoming: NWConnection) {
        if isConnected && isAuthenticatedSession {
            incoming.cancel()
            return
        }
        // Glare arbitration: if we are mid-flight opening an automatic outgoing socket
        // to a peer whose ID is larger than ours, keep our primary outgoing attempt.
        if activeConnection != nil,
           isOutgoingInitiator,
           let targetID = pendingOutgoingPeerID,
           localPeerID < targetID {
            incoming.cancel()
            return
        }
        autoConnectDebounceTask?.cancel()
        autoConnectDebounceTask = nil
        disconnectCurrentPeer(reason: "接收对端连接请求", pauseSessionAutoConnect: false)
        isOutgoingInitiator = false
        isAutomaticConnectionAttempt = false
        pendingOutgoingPeerID = nil
        isAuthenticatedSession = false
        deframer.reset()
        activeConnection = incoming
        connectionStatus = "收到局域网连接握手…"
        configureConnectionCallbacks(incoming)
        incoming.start(queue: .main)
    }

    private func configureConnectionCallbacks(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            MainActor.assumeIsolated {
                guard let self, let conn, self.activeConnection === conn else { return }
                switch state {
                case .ready:
                    self.receiveNextChunk(on: conn)
                    if !self.isOutgoingInitiator {
                        let nonce = RemoteLANAuth.randomHex(byteCount: 16)
                        self.serverNonce = nonce
                        self.sendWireMessage(
                            .serverChallenge(
                                peerID: self.localPeerID,
                                peerName: self.localPeerName,
                                serverNonce: nonce
                            ),
                            requireAuth: false
                        )
                    }
                case .failed(let error):
                    self.handleConnectionClosed(reason: "连接中断：\(error.localizedDescription)")
                case .cancelled:
                    if self.isConnected || self.isPairingInProgress {
                        self.handleConnectionClosed(reason: "连接已关闭")
                    }
                default:
                    break
                }
            }
        }
    }

    private func receiveNextChunk(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self, weak conn] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let conn, self.activeConnection === conn else { return }
                if let content, !content.isEmpty {
                    guard self.receiveChunkData(content) else { return }
                }
                if let error {
                    self.handleConnectionClosed(reason: "网络读取结束：\(error.localizedDescription)")
                    return
                }
                if isComplete {
                    self.handleConnectionClosed(reason: "对端已断开连接")
                    return
                }
                self.receiveNextChunk(on: conn)
            }
        }
    }

    @discardableResult
    private func receiveChunkData(_ content: Data) -> Bool {
        do {
            let frames = try deframer.append(content)
            for frame in frames {
                handleIncomingFrame(frame)
            }
            return true
        } catch {
            log("协议帧解析异常：\(error.localizedDescription)")
            disconnectCurrentPeer(reason: "收到无效数据帧，已安全断开", pauseSessionAutoConnect: false)
            return false
        }
    }

    // MARK: - Handshake, Pairing, State Sync & Config Sync State Machine

    private func handleIncomingFrame(_ message: RemoteLANWireMessage) {
        if !isAuthenticatedSession {
            handleUnauthenticatedFrame(message)
            return
        }
        switch message {
        case .ping(let sentAtMs):
            sendWireMessage(.pong(sentAtMs: sentAtMs))
        case .pong(let sentAtMs):
            latencyMs = max(0.1, Date().timeIntervalSince1970 * 1000 - sentAtMs)
        case .peerStateSync(let remoteDispatchMode, let remoteHasPhysicalRemote):
            peerHasPhysicalRemote = remoteHasPhysicalRemote
            if dispatchMode != remoteDispatchMode {
                suppressStateEcho = true
                dispatchMode = remoteDispatchMode
                suppressStateEcho = false
                log("已同步对端远程映射模式：\(remoteDispatchMode.title)")
            }
        case .requestConfigSnapshot(let requestID):
            guard let snapshot = onExportLocalConfig?() else { return }
            sendWireMessage(.configSnapshotResponse(requestID: requestID, snapshot: snapshot))
            log("已响应「\(connectedPeerName ?? "对端 Mac")」的配置同步拉取请求")
        case .configSnapshotResponse(let requestID, let snapshot):
            guard requestID == pendingConfigSyncRequestID,
                  let strategy = pendingConfigSyncStrategy else { return }
            configSyncTimeoutTask?.cancel()
            configSyncTimeoutTask = nil
            pendingConfigSyncRequestID = nil
            pendingConfigSyncStrategy = nil
            isSyncingConfig = false
            if let result = onApplySyncedConfig?(snapshot, strategy) {
                lastConfigSyncMessage = result.summaryMessage
                log(result.summaryMessage)
            } else {
                lastConfigSyncMessage = "已完成来自「\(snapshot.sourcePeerName)」的配置同步。"
            }
        case .focusChanged(let controllingReceiver, let controllerName):
            isControlledByPeer = controllingReceiver
            controllingPeerName = controllingReceiver ? controllerName : nil
            if !controllingReceiver {
                onIncomingHoldEnd?(nil)
                onIncomingVoiceEnd?()
                if !suppressPromptWindowsForTesting {
                    RemoteSwitchNotificationCenter.shared.notifySwitchedToOtherMac(
                        otherMacName: controllerName,
                        detail: "遥控器已切回主控端「\(controllerName)」",
                        hudEnabled: switchHUDEnabled,
                        systemNotificationEnabled: switchNotificationsEnabled,
                        soundEnabled: switchSoundEnabled
                    )
                }
            } else if !suppressPromptWindowsForTesting {
                RemoteSwitchNotificationCenter.shared.notifySwitchedToThisMac(
                    thisMacName: localPeerName,
                    detail: "来自「\(controllerName)」的遥控器转发已切入这台 Mac",
                    hudEnabled: switchHUDEnabled,
                    systemNotificationEnabled: switchNotificationsEnabled,
                    soundEnabled: switchSoundEnabled
                )
            }
        case .forwardedAction(let key, let gesture, let mode, let senderModel, let shortcut, let holdSeconds, let systemAction, let librarySteps):
            guard allowIncomingControl else { return }
            receivedCount += 1
            onIncomingAction?(key, gesture, mode, senderModel, shortcut, holdSeconds, systemAction, librarySteps)
        case .holdStart(let key, let mode, let senderModel, let shortcut):
            guard allowIncomingControl else { return }
            receivedCount += 1
            onIncomingHoldStart?(key, mode, senderModel, shortcut)
        case .holdEnd(let key):
            onIncomingHoldEnd?(key)
        case .voiceStart(let sampleRate, let mode, let shortcut, let trigger):
            guard allowIncomingControl else { return }
            receivedCount += 1
            onIncomingVoiceStart?(sampleRate, mode, shortcut, trigger)
        case .voicePCM(let samplesLE, let sampleRate):
            guard allowIncomingControl else { return }
            let samples = RemoteLANPCMCodec.decodeSamples(samplesLE)
            if !samples.isEmpty {
                onIncomingVoicePCM?(samples, sampleRate)
            }
        case .voiceEnd:
            onIncomingVoiceEnd?()
        case .disconnect(let reason):
            handleConnectionClosed(reason: "对端断开：\(reason)")
        default:
            break
        }
    }

    private func handleUnauthenticatedFrame(_ message: RemoteLANWireMessage) {
        switch message {
        case .serverChallenge(let remotePeerID, let remotePeerName, let remoteServerNonce):
            guard isOutgoingInitiator, remotePeerID != localPeerID else {
                disconnectCurrentPeer(reason: "不能连接本机自身实例", pauseSessionAutoConnect: false)
                return
            }
            serverNonce = remoteServerNonce
            connectedPeerID = remotePeerID
            connectedPeerName = remotePeerName

            if !manualForcedPairing,
               let trusted = trustedPeers.first(where: { $0.id == remotePeerID }) {
                let cNonce = RemoteLANAuth.randomHex(byteCount: 16)
                clientNonce = cNonce
                if let hmac = RemoteLANAuth.computeHMAC(
                    secretHex: trusted.sharedSecretHex,
                    role: "CLIENT",
                    clientID: localPeerID,
                    serverID: remotePeerID,
                    clientNonce: cNonce,
                    serverNonce: remoteServerNonce
                ) {
                    connectionStatus = "正在验证已配对设备「\(remotePeerName)」…"
                    sendWireMessage(
                        .authenticate(peerID: localPeerID, peerName: localPeerName, clientNonce: cNonce, hmacHex: hmac),
                        requireAuth: false
                    )
                    return
                }
            }

            // Strictly enforce: automatic reconnect NEVER triggers pairing popups for unpaired peers!
            if isAutomaticConnectionAttempt {
                pausedAutoConnectPeerIDs.insert(remotePeerID)
                disconnectCurrentPeer(
                    reason: "跳过自动连接：「\(remotePeerName)」尚未完成配对信任",
                    pauseSessionAutoConnect: false
                )
                return
            }
            beginOutgoingPairingRequest(serverID: remotePeerID, serverName: remotePeerName, serverNonce: remoteServerNonce)

        case .pairingRequired:
            guard isOutgoingInitiator,
                  let remoteID = connectedPeerID,
                  let remoteName = connectedPeerName,
                  let sNonce = serverNonce else { return }
            if isAutomaticConnectionAttempt {
                pausedAutoConnectPeerIDs.insert(remoteID)
                disconnectCurrentPeer(
                    reason: "「\(remoteName)」已解除旧配对，请手动点击「请求配对」重新确认",
                    pauseSessionAutoConnect: false
                )
                return
            }
            beginOutgoingPairingRequest(serverID: remoteID, serverName: remoteName, serverNonce: sNonce)

        case .authAccepted(let remoteID, let remoteName, let serverHmacHex):
            guard isOutgoingInitiator,
                  let cNonce = clientNonce,
                  let sNonce = serverNonce,
                  let trusted = trustedPeers.first(where: { $0.id == remoteID }),
                  let expected = RemoteLANAuth.computeHMAC(
                    secretHex: trusted.sharedSecretHex,
                    role: "SERVER",
                    clientID: localPeerID,
                    serverID: remoteID,
                    clientNonce: cNonce,
                    serverNonce: sNonce
                  ),
                  RemoteLANAuth.constantTimeEquals(expected, serverHmacHex) else {
                disconnectCurrentPeer(reason: "双向身份校验未通过", pauseSessionAutoConnect: false)
                return
            }
            rememberTrustedPeer(
                id: remoteID,
                name: remoteName,
                secretHex: trusted.sharedSecretHex,
                host: lastAttemptedHost ?? trusted.lastHost,
                port: lastAttemptedPort ?? sharedPort
            )
            promoteToAuthenticatedSession(peerID: remoteID, peerName: remoteName)

        case .authenticate(let clientID, let clientName, let cNonce, let clientHmac):
            guard !isOutgoingInitiator, let sNonce = serverNonce, clientID != localPeerID else {
                disconnectCurrentPeer(reason: "拒绝连接本机自身", pauseSessionAutoConnect: false)
                return
            }
            guard let trusted = trustedPeers.first(where: { $0.id == clientID }),
                  let expectedClient = RemoteLANAuth.computeHMAC(
                    secretHex: trusted.sharedSecretHex,
                    role: "CLIENT",
                    clientID: clientID,
                    serverID: localPeerID,
                    clientNonce: cNonce,
                    serverNonce: sNonce
                  ),
                  RemoteLANAuth.constantTimeEquals(expectedClient, clientHmac),
                  let serverProof = RemoteLANAuth.computeHMAC(
                    secretHex: trusted.sharedSecretHex,
                    role: "SERVER",
                    clientID: clientID,
                    serverID: localPeerID,
                    clientNonce: cNonce,
                    serverNonce: sNonce
                  ) else {
                sendWireMessage(.pairingRequired(reason: "需要重新点击确认配对"), requireAuth: false)
                return
            }
            let discoveredHost = discoveredPeers.first(where: { $0.id == clientID })?.host ?? trusted.lastHost
            rememberTrustedPeer(id: clientID, name: clientName, secretHex: trusted.sharedSecretHex, host: discoveredHost, port: sharedPort)
            sendWireMessage(.authAccepted(peerID: localPeerID, peerName: localPeerName, serverHmacHex: serverProof), requireAuth: false)
            promoteToAuthenticatedSession(peerID: clientID, peerName: clientName)

        case .pairRequest(let requestID, let clientID, let clientName, let cNonce, let proposedSecretHex):
            guard !isOutgoingInitiator,
                  let sNonce = serverNonce,
                  RemoteLANAuth.dataFromHex(proposedSecretHex) != nil else { return }
            let code = RemoteLANAuth.verificationCode(
                clientID: clientID,
                serverID: localPeerID,
                clientNonce: cNonce,
                serverNonce: sNonce,
                secretHex: proposedSecretHex
            )
            pendingRequestID = requestID
            pendingClientPeerID = clientID
            pendingClientPeerName = clientName
            clientNonce = cNonce
            pendingProposedSecretHex = proposedSecretHex
            isPairingInProgress = true

            let incoming = RemoteIncomingPairingRequest(
                id: requestID,
                peerID: clientID,
                peerName: clientName,
                verificationCode: code,
                receivedAt: Date()
            )
            incomingPairingRequest = incoming
            connectionStatus = "等待确认来自「\(clientName)」的配对请求（核对码 \(code)）"
            log("收到来自「\(clientName)」的配对请求 · 核对码 \(code)")

            if !suppressPromptWindowsForTesting {
                RemotePairingPromptWindowController.shared.present(
                    request: incoming,
                    port: sharedPort,
                    onApprove: { [weak self] in self?.approveIncomingPairing() },
                    onReject: { [weak self] in self?.rejectIncomingPairing() }
                )
            }
            schedulePairingTimeout()

        case .pairDecision(let requestID, let accepted, let remoteID, let remoteName, let serverHmacHex, let messageText):
            guard isOutgoingInitiator,
                  requestID == pendingRequestID,
                  let cNonce = clientNonce,
                  let sNonce = serverNonce,
                  let secretHex = pendingProposedSecretHex else { return }
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            isPairingInProgress = false
            outgoingPairingCode = nil

            guard accepted,
                  let serverHmacHex,
                  let expectedServer = RemoteLANAuth.computeHMAC(
                    secretHex: secretHex,
                    role: "SERVER",
                    clientID: localPeerID,
                    serverID: remoteID,
                    clientNonce: cNonce,
                    serverNonce: sNonce
                  ),
                  RemoteLANAuth.constantTimeEquals(expectedServer, serverHmacHex) else {
                disconnectCurrentPeer(reason: accepted ? "配对校验不一致" : "对方拒绝了配对：\(messageText)", pauseSessionAutoConnect: false)
                return
            }
            rememberTrustedPeer(id: remoteID, name: remoteName, secretHex: secretHex, host: lastAttemptedHost, port: lastAttemptedPort ?? sharedPort)
            promoteToAuthenticatedSession(peerID: remoteID, peerName: remoteName)

        default:
            break
        }
    }

    private func beginOutgoingPairingRequest(serverID: String, serverName: String, serverNonce: String) {
        let reqID = UUID()
        let cNonce = RemoteLANAuth.randomHex(byteCount: 16)
        let secret = RemoteLANAuth.randomHex(byteCount: 32)
        let code = RemoteLANAuth.verificationCode(
            clientID: localPeerID,
            serverID: serverID,
            clientNonce: cNonce,
            serverNonce: serverNonce,
            secretHex: secret
        )
        pendingRequestID = reqID
        clientNonce = cNonce
        pendingProposedSecretHex = secret
        outgoingPairingCode = code
        isPairingInProgress = true
        connectionStatus = "请在「\(serverName)」上点击确认配对（核对码：\(code)）"
        log("已向「\(serverName)」发起配对请求 · 核对码 \(code)")

        sendWireMessage(
            .pairRequest(
                requestID: reqID,
                peerID: localPeerID,
                peerName: localPeerName,
                clientNonce: cNonce,
                proposedSecretHex: secret
            ),
            requireAuth: false
        )
        schedulePairingTimeout()
    }

    func approveIncomingPairing() {
        RemotePairingPromptWindowController.shared.dismiss()
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        guard let reqID = pendingRequestID,
              let clientID = pendingClientPeerID,
              let clientName = pendingClientPeerName,
              let cNonce = clientNonce,
              let sNonce = serverNonce,
              let secretHex = pendingProposedSecretHex,
              let serverProof = RemoteLANAuth.computeHMAC(
                secretHex: secretHex,
                role: "SERVER",
                clientID: clientID,
                serverID: localPeerID,
                clientNonce: cNonce,
                serverNonce: sNonce
              ) else {
            incomingPairingRequest = nil
            isPairingInProgress = false
            return
        }
        incomingPairingRequest = nil
        isPairingInProgress = false
        let knownHost = discoveredPeers.first(where: { $0.id == clientID })?.host
        rememberTrustedPeer(id: clientID, name: clientName, secretHex: secretHex, host: knownHost, port: sharedPort)
        sendWireMessage(
            .pairDecision(requestID: reqID, accepted: true, peerID: localPeerID, peerName: localPeerName, serverHmacHex: serverProof, message: "已确认配对"),
            requireAuth: false
        )
        promoteToAuthenticatedSession(peerID: clientID, peerName: clientName)
    }

    func rejectIncomingPairing() {
        RemotePairingPromptWindowController.shared.dismiss()
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        if let reqID = pendingRequestID {
            sendWireMessage(
                .pairDecision(requestID: reqID, accepted: false, peerID: localPeerID, peerName: localPeerName, serverHmacHex: nil, message: "用户拒绝配对"),
                requireAuth: false
            )
        }
        incomingPairingRequest = nil
        isPairingInProgress = false
        disconnectCurrentPeer(reason: "已拒绝来自对端的配对请求", pauseSessionAutoConnect: false)
    }

    private func schedulePairingTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.isPairingInProgress else { return }
            RemotePairingPromptWindowController.shared.dismiss()
            self.incomingPairingRequest = nil
            self.outgoingPairingCode = nil
            self.isPairingInProgress = false
            self.disconnectCurrentPeer(reason: "配对确认超时（45 秒），请重试", pauseSessionAutoConnect: false)
        }
    }

    private func promoteToAuthenticatedSession(peerID: String, peerName: String) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        autoConnectDebounceTask?.cancel()
        autoConnectDebounceTask = nil
        manualForcedPairing = false
        isAutomaticConnectionAttempt = false
        pendingOutgoingPeerID = nil
        pausedAutoConnectPeerIDs.remove(peerID)
        isPairingInProgress = false
        outgoingPairingCode = nil
        incomingPairingRequest = nil
        isAuthenticatedSession = true
        isConnected = true
        connectedPeerID = peerID
        connectedPeerName = peerName
        defaults.set(peerID, forKey: Self.lastConnectedPeerKey)
        connectionStatus = "已连接「\(peerName)」· 共享端口 \(sharedPort)"
        log("双机认证连接已建立：\(peerName)")
        refreshDiscoveredTrustFlags()
        broadcastLocalPeerState()
        startPingLoop()
    }

    private func startPingLoop() {
        pingTask?.cancel()
        guard testTransportSender == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected, self.isAuthenticatedSession else { return }
                self.sendWireMessage(.ping(sentAtMs: Date().timeIntervalSince1970 * 1000))
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Trust Persistence

    func addTrustedPeerForTesting(_ peer: RemoteTrustedPeer) {
        rememberTrustedPeer(
            id: peer.id,
            name: peer.name,
            secretHex: peer.sharedSecretHex,
            host: peer.lastHost,
            port: peer.lastPort
        )
    }

    private func rememberTrustedPeer(id: String, name: String, secretHex: String, host: String?, port: UInt16) {
        let existingDate = trustedPeers.first(where: { $0.id == id })?.pairedAt ?? Date()
        let peer = RemoteTrustedPeer(id: id, name: name, sharedSecretHex: secretHex, lastHost: host, lastPort: port, pairedAt: existingDate)
        if let idx = trustedPeers.firstIndex(where: { $0.id == id }) {
            trustedPeers[idx] = peer
        } else {
            trustedPeers.append(peer)
        }
        if let data = try? JSONEncoder().encode(trustedPeers) {
            defaults.set(data, forKey: Self.trustedPeersKey)
        }
        refreshDiscoveredTrustFlags()
    }

    func removeTrustedPeer(_ id: String) {
        trustedPeers.removeAll { $0.id == id }
        pausedAutoConnectPeerIDs.remove(id)
        if defaults.string(forKey: Self.lastConnectedPeerKey) == id {
            defaults.removeObject(forKey: Self.lastConnectedPeerKey)
        }
        if let data = try? JSONEncoder().encode(trustedPeers) {
            defaults.set(data, forKey: Self.trustedPeersKey)
        }
        refreshDiscoveredTrustFlags()
        if connectedPeerID == id {
            disconnectCurrentPeer(reason: "已解除设备信任配对", pauseSessionAutoConnect: false)
        }
    }

    private func refreshDiscoveredTrustFlags() {
        for index in discoveredPeers.indices {
            let id = discoveredPeers[index].id
            discoveredPeers[index].isTrusted = trustedPeers.contains(where: { $0.id == id })
        }
    }

    // MARK: - Event Forwarding

    func forwardMappedAction(
        key: RemoteKey,
        gesture: RemoteGesture,
        action: RemoteAction,
        senderModel: RemoteDeviceModel,
        library: RemoteLibraryStore
    ) {
        guard isForwardingToRemoteMac else { return }
        forwardedCount += 1
        let safeSteps = action.kind == .libraryAction
            ? RemoteLANForwardedStep.sanitizedSteps(from: library.steps(for: action))
            : nil
        sendWireMessage(
            .forwardedAction(
                key: key,
                gesture: gesture,
                mode: dispatchMode,
                senderModel: senderModel,
                shortcut: action.shortcut,
                holdSeconds: action.effectiveHoldSeconds,
                systemAction: action.systemAction,
                librarySteps: safeSteps
            )
        )
    }

    @discardableResult
    func forwardHoldStart(key: RemoteKey, senderModel: RemoteDeviceModel, shortcut: RemoteShortcut?) -> Bool {
        guard isForwardingToRemoteMac else { return false }
        activeForwardedHolds.insert(key)
        forwardedCount += 1
        sendWireMessage(.holdStart(key: key, mode: dispatchMode, senderModel: senderModel, shortcut: shortcut))
        return true
    }

    func forwardHoldEnd(key: RemoteKey) {
        guard activeForwardedHolds.remove(key) != nil else { return }
        sendWireMessage(.holdEnd(key: key))
    }

    func forwardVoiceStart(sampleRate: Int, shortcut: RemoteShortcut?, trigger: DoubaoShortcutTrigger) {
        guard isForwardingToRemoteMac, !activeForwardedVoice else { return }
        activeForwardedVoice = true
        forwardedCount += 1
        sendWireMessage(.voiceStart(sampleRate: sampleRate, mode: dispatchMode, shortcut: shortcut, trigger: trigger))
    }

    func forwardVoicePCM(samples: [Int16], sampleRate: Int) {
        guard isForwardingToRemoteMac, activeForwardedVoice, !samples.isEmpty else { return }
        sendWireMessage(.voicePCM(samplesLE: RemoteLANPCMCodec.encodeSamples(samples), sampleRate: sampleRate))
    }

    func forwardVoiceEnd() {
        guard activeForwardedVoice else { return }
        activeForwardedVoice = false
        sendWireMessage(.voiceEnd)
    }

    private func flushForwardedHoldsAndVoice() {
        let held = activeForwardedHolds
        activeForwardedHolds.removeAll()
        for key in held { sendWireMessage(.holdEnd(key: key)) }
        if activeForwardedVoice {
            activeForwardedVoice = false
            sendWireMessage(.voiceEnd)
        }
    }

    // MARK: - Disconnection & Transport

    func disconnectCurrentPeer(
        reason: String = "已手动断开连接",
        pauseSessionAutoConnect: Bool = true
    ) {
        if pauseSessionAutoConnect, let currentID = connectedPeerID ?? pendingOutgoingPeerID {
            pausedAutoConnectPeerIDs.insert(currentID)
        }
        if isConnected && isAuthenticatedSession {
            flushForwardedHoldsAndVoice()
            sendWireMessage(.disconnect(reason: reason))
        }
        activeConnection?.cancel()
        activeConnection = nil
        testTransportSender = nil
        handleConnectionClosed(reason: reason)
    }

    private func handleConnectionClosed(reason: String) {
        RemotePairingPromptWindowController.shared.dismiss()
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        configSyncTimeoutTask?.cancel()
        configSyncTimeoutTask = nil
        pingTask?.cancel()
        pingTask = nil
        if isControlledByPeer {
            onIncomingHoldEnd?(nil)
            onIncomingVoiceEnd?()
        }
        if activeTarget == .remoteMac {
            activeTarget = .localMac
            if !suppressPromptWindowsForTesting {
                RemoteSwitchNotificationCenter.shared.notifySwitchedToThisMac(
                    thisMacName: localPeerName,
                    detail: "远端连接中断（\(reason)），遥控器已自动切回本机",
                    hudEnabled: switchHUDEnabled,
                    systemNotificationEnabled: switchNotificationsEnabled,
                    soundEnabled: switchSoundEnabled
                )
            }
        }
        activeConnection = nil
        deframer.reset()
        isAuthenticatedSession = false
        isAutomaticConnectionAttempt = false
        pendingOutgoingPeerID = nil
        isConnected = false
        isPairingInProgress = false
        isSyncingConfig = false
        pendingConfigSyncRequestID = nil
        pendingConfigSyncStrategy = nil
        outgoingPairingCode = nil
        incomingPairingRequest = nil
        connectedPeerID = nil
        connectedPeerName = nil
        peerHasPhysicalRemote = false
        isControlledByPeer = false
        controllingPeerName = nil
        latencyMs = nil
        activeForwardedHolds.removeAll()
        activeForwardedVoice = false
        serverNonce = nil
        clientNonce = nil
        pendingProposedSecretHex = nil
        pendingRequestID = nil
        pendingClientPeerID = nil
        pendingClientPeerName = nil
        connectionStatus = reason
    }

    private func sendWireMessage(_ message: RemoteLANWireMessage, requireAuth: Bool = true) {
        if requireAuth && !isAuthenticatedSession { return }
        guard let data = try? RemoteLANFrameCodec.encode(message) else { return }
        if let testTransportSender {
            testTransportSender(data)
            return
        }
        activeConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func clearLogs() { logs.removeAll() }

    private func log(_ entry: String) {
        logs.append("[\(Date().formatted(date: .omitted, time: .standard))] \(entry)")
        if logs.count > 180 { logs.removeFirst(logs.count - 180) }
    }
}
