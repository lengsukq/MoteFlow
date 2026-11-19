import CryptoKit
import Foundation

/// Active destination for physical remote events captured on the host Mac.
enum RemoteControlTarget: String, Codable, CaseIterable, Identifiable {
    case localMac
    case remoteMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localMac: "控制本机 Mac"
        case .remoteMac: "转发至另一台 Mac"
        }
    }

    var shortTitle: String {
        switch self {
        case .localMac: "本机 Mac"
        case .remoteMac: "远端 Mac"
        }
    }

    var symbol: String {
        switch self {
        case .localMac: "desktopcomputer"
        case .remoteMac: "macbook.and.ipad"
        }
    }
}

/// An application whose foreground activation automatically switches remote
/// control focus to the peer Mac (and back to this Mac when leaving).
struct RemoteFocusSwitchApp: Codable, Identifiable, Equatable, Hashable {
    var bundleID: String
    var displayName: String

    var id: String { bundleID }

    static let screenSharing = RemoteFocusSwitchApp(
        bundleID: "com.apple.ScreenSharing",
        displayName: "屏幕共享"
    )

    static let recommendedPresets: [RemoteFocusSwitchApp] = [
        .screenSharing,
        RemoteFocusSwitchApp(bundleID: "com.carriez.flutter_hbb", displayName: "RustDesk"),
        RemoteFocusSwitchApp(bundleID: "tv.parsec.www", displayName: "Parsec"),
        RemoteFocusSwitchApp(bundleID: "com.moonlight-stream.Moonlight", displayName: "Moonlight"),
        RemoteFocusSwitchApp(bundleID: "com.p5sys.jump.mac.viewer", displayName: "Jump Desktop"),
        RemoteFocusSwitchApp(bundleID: "com.teamviewer.TeamViewer", displayName: "TeamViewer")
    ]
}

/// Determines which Mac's button mapping acts as the active standard during a
/// connected Dual-Mac session (without overwriting either Mac's local config).
enum RemoteRelayDispatchMode: String, Codable, CaseIterable, Identifiable {
    /// Both Macs follow the host Mac (holding the physical remote) across all screens.
    case senderMapping
    /// Both Macs follow the peer/receiver Mac via an ephemeral in-memory snapshot (zero overwrite).
    case unifiedReceiverMapping
    /// Each Mac executes its own local mapping when controlled.
    case receiverMapping

    var id: String { rawValue }

    /// Whether the receiving Mac should resolve forwarded keys using its own local store.
    var receiverUsesOwnMapping: Bool {
        self == .receiverMapping || self == .unifiedReceiverMapping
    }

    var title: String {
        switch self {
        case .senderMapping: "统一用主控端方案（双机一致）"
        case .unifiedReceiverMapping: "统一用受控端方案（双机一致 · 内存复用）"
        case .receiverMapping: "各自独立（控哪台用哪台自己的）"
        }
    }

    var detail: String {
        switch self {
        case .senderMapping: "联机期间控两台 Mac 都按主控端配置执行，不改动受控端本地设置。"
        case .unifiedReceiverMapping: "联机期间控两台 Mac 都按受控端配置执行（主控端仅在内存临时复用，断开即恢复）。"
        case .receiverMapping: "只转发遥控器按键与长按信号，控哪台 Mac 就用哪台自己保存的按键映射。"
        }
    }
}

/// User-facing 3-way choice on whichever Mac screen the user is currently operating.
enum RemoteMappingFollowSource: String, Codable, CaseIterable, Identifiable {
    case followLocalMac
    case followRemoteMac
    case independent

    var id: String { rawValue }

    func resolvedDispatchMode(localIsReceiver: Bool) -> RemoteRelayDispatchMode {
        switch (self, localIsReceiver) {
        case (.followLocalMac, false):
            return .senderMapping
        case (.followRemoteMac, false):
            return .unifiedReceiverMapping
        case (.followRemoteMac, true):
            return .senderMapping
        case (.followLocalMac, true):
            return .unifiedReceiverMapping
        case (.independent, _):
            return .receiverMapping
        }
    }

    static func from(dispatchMode: RemoteRelayDispatchMode, localIsReceiver: Bool) -> RemoteMappingFollowSource {
        switch (dispatchMode, localIsReceiver) {
        case (.senderMapping, false), (.unifiedReceiverMapping, true):
            return .followLocalMac
        case (.unifiedReceiverMapping, false), (.senderMapping, true):
            return .followRemoteMac
        case (.receiverMapping, _):
            return .independent
        }
    }
}

/// Deterministic arbitration when two Macs connect with differing saved mapping
/// rules so both sides converge to the exact same rule without swapping.
enum RemoteMappingPolicyArbitrator {
    static func localIsAuthoritativeOnConnect(
        localPeerID: String,
        remotePeerID: String,
        localHasPhysicalRemote: Bool,
        remoteHasPhysicalRemote: Bool
    ) -> Bool {
        if localHasPhysicalRemote != remoteHasPhysicalRemote {
            return localHasPhysicalRemote
        }
        return localPeerID < remotePeerID
    }
}

/// Strategy when importing a backup file or pulling configuration from a connected Mac.
enum RemoteConfigSyncStrategy: String, Codable, CaseIterable, Identifiable {
    case merge
    case overwrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: "合并补全（保留本机已有设置）"
        case .overwrite: "完整覆盖（与备份/对端完全一致）"
        }
    }

    var shortTitle: String {
        switch self {
        case .merge: "合并导入"
        case .overwrite: "覆盖导入"
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            "只补充当前未配置的空按键、新命名方案与新动作库条目，保留本机已经设好的所有按键绑定。"
        case .overwrite:
            "用导入的配置替换本机按键映射、长按阈值、命名方案和动作库（覆盖前会自动生成一份本机保护备份，随时可撤回）。"
        }
    }
}

/// Sanitized, script-free configuration payload used by both LAN Dual-Mac sync
/// and portable JSON backup export/import (including optional learned HID codes).
struct RemoteSyncConfigSnapshot: Codable, Equatable {
    var sourcePeerName: String
    var exportedAt: Date = Date()
    var activeModel: RemoteDeviceModel
    var modelBindings: [String: [RemoteKey: RemoteBinding]]
    var namedProfiles: [RemoteNamedMappingProfile]
    var libraryActions: [RemoteLibraryAction]
    var learnedHIDProfile: RemoteHIDProfile? = nil

    var totalConfiguredKeyCount: Int {
        modelBindings.values.reduce(0) { partial, dict in
            partial + dict.values.filter(\.isConfigured).count
        }
    }

    func binding(for key: RemoteKey, model: RemoteDeviceModel) -> RemoteBinding {
        modelBindings[model.id]?[key] ?? RemoteBinding()
    }

    func action(for key: RemoteKey, gesture: RemoteGesture, model: RemoteDeviceModel) -> RemoteAction {
        binding(for: key, model: model).action(for: gesture)
    }

    func steps(for remoteAction: RemoteAction) -> [RemoteActionStep]? {
        switch remoteAction.kind {
        case .none, .systemAction:
            return nil
        case .libraryAction:
            guard let id = remoteAction.presetID,
                  let item = libraryActions.first(where: { $0.id == id }) else {
                return nil
            }
            let safeSteps = item.steps.filter { $0.kind != .script }
            return safeSteps.isEmpty ? nil : safeSteps
        case .keyboardShortcut:
            guard let shortcut = remoteAction.shortcut else { return nil }
            return [RemoteActionStep(
                kind: .keyboard,
                shortcut: shortcut,
                holdSeconds: remoteAction.effectiveHoldSeconds
            )]
        }
    }

    func description(for action: RemoteAction) -> String {
        if action.kind == .libraryAction {
            if let id = action.presetID,
               let item = libraryActions.first(where: { $0.id == id }) {
                return item.name
            }
            return "对端动作（未同步）"
        }
        return action.summary
    }

    func resolveHoldShortcut(for key: RemoteKey, model: RemoteDeviceModel) -> RemoteShortcut? {
        let act = action(for: key, gesture: .longPress, model: model)
        guard act.effectiveHoldMode == .physical else { return nil }
        if act.kind == .keyboardShortcut {
            return act.shortcut
        }
        if act.kind == .libraryAction,
           let resolved = steps(for: act),
           resolved.count == 1,
           resolved[0].kind == .keyboard {
            return resolved[0].shortcut
        }
        return nil
    }

    func resolveVoiceAssistantShortcut(model: RemoteDeviceModel) -> RemoteShortcut? {
        for gesture in [RemoteGesture.longPress, .tap] {
            let act = action(for: .assistant, gesture: gesture, model: model)
            if let resolved = steps(for: act),
               resolved.count == 1,
               let first = resolved.first,
               first.kind == .keyboard,
               let shortcut = first.shortcut {
                return shortcut
            }
        }
        return nil
    }

    func hasSwitchMacTargetBinding(model: RemoteDeviceModel) -> Bool {
        guard let map = modelBindings[model.id] else { return false }
        return map.values.contains { binding in
            RemoteGesture.allCases.contains { gesture in
                let act = binding.action(for: gesture)
                return act.kind == .systemAction && act.systemAction == .switchMacTarget
            }
        }
    }

    /// Strips any raw shell/script execution steps or script file paths so LAN sync
    /// and external backup imports can never silently inject executable shell code.
    func sanitized() -> RemoteSyncConfigSnapshot {
        let unsafeActionIDs = Set(
            libraryActions.filter { item in
                item.steps.allSatisfy { $0.kind == .script }
            }.map(\.id)
        )

        var cleanModels: [String: [RemoteKey: RemoteBinding]] = [:]
        for (modelID, dict) in modelBindings {
            var cleanDict: [RemoteKey: RemoteBinding] = [:]
            for (key, binding) in dict {
                cleanDict[key] = Self.sanitizeBinding(binding, unsafeActionIDs: unsafeActionIDs)
            }
            cleanModels[modelID] = cleanDict
        }

        let cleanProfiles = namedProfiles.map { profile in
            var cleanDict: [RemoteKey: RemoteBinding] = [:]
            for (key, binding) in profile.bindings {
                cleanDict[key] = Self.sanitizeBinding(binding, unsafeActionIDs: unsafeActionIDs)
            }
            return RemoteNamedMappingProfile(
                id: profile.id,
                name: profile.name,
                modelID: profile.modelID,
                bindings: cleanDict
            )
        }

        let cleanLibrary = libraryActions.compactMap { item -> RemoteLibraryAction? in
            let safeSteps = item.steps.filter { $0.kind != .script }
            guard !safeSteps.isEmpty else { return nil }
            return RemoteLibraryAction(
                id: item.id,
                name: item.name,
                steps: safeSteps,
                modifiedAt: item.modifiedAt
            )
        }

        let cleanHID: RemoteHIDProfile?
        if let profile = learnedHIDProfile, (try? profile.validatedCodes()) != nil {
            cleanHID = profile
        } else {
            cleanHID = nil
        }

        return RemoteSyncConfigSnapshot(
            sourcePeerName: sourcePeerName,
            exportedAt: exportedAt,
            activeModel: activeModel,
            modelBindings: cleanModels,
            namedProfiles: cleanProfiles,
            libraryActions: cleanLibrary,
            learnedHIDProfile: cleanHID
        )
    }

    private static func sanitizeBinding(
        _ binding: RemoteBinding,
        unsafeActionIDs: Set<UUID>
    ) -> RemoteBinding {
        var copy = binding
        for gesture in RemoteGesture.allCases {
            let act = copy.action(for: gesture)
            if act.migratedScriptPath != nil {
                copy.setAction(RemoteAction(), for: gesture)
            } else if act.kind == .libraryAction,
                      let id = act.presetID,
                      unsafeActionIDs.contains(id) {
                copy.setAction(RemoteAction(), for: gesture)
            }
        }
        return copy
    }
}

enum RemoteConfigBackupError: LocalizedError, Equatable {
    case fileTooLarge(Int)
    case unsupportedFormat
    case corruptedData(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            "备份文件过大（\(bytes) 字节），请选择不超过 1 MB 的 MoteFlow 配置备份文件。"
        case .unsupportedFormat:
            "无法识别该 JSON 文件格式：请选择由 MoteFlow 导出的配置备份文件。"
        case .corruptedData(let detail):
            "备份文件解析失败：\(detail)"
        }
    }
}

/// Unified, versioned JSON backup envelope for full MoteFlow configuration export & import
/// (mappings, named schemes, action library, AND custom learned HID codes).
/// Also transparently upgrades legacy standalone `RemoteHIDProfile` JSON files.
struct RemoteConfigBackupDocument: Codable, Equatable {
    static let currentFormat = "moteflow.config.backup"
    static let maxImportBytes = 1_048_576

    var format: String = Self.currentFormat
    var version: Int = 1
    var note: String?
    var snapshot: RemoteSyncConfigSnapshot

    func exportJSONData() throws -> Data {
        let clean = RemoteConfigBackupDocument(
            format: Self.currentFormat,
            version: 1,
            note: note,
            snapshot: snapshot.sanitized()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(clean)
    }

    static func importJSONData(_ data: Data) throws -> RemoteConfigBackupDocument {
        guard data.count <= maxImportBytes else {
            throw RemoteConfigBackupError.fileTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let doc = try? decoder.decode(RemoteConfigBackupDocument.self, from: data),
           doc.format == currentFormat, doc.version == 1 {
            return RemoteConfigBackupDocument(
                format: doc.format,
                version: doc.version,
                note: doc.note,
                snapshot: doc.snapshot.sanitized()
            )
        }
        if let fallback = try? JSONDecoder().decode(RemoteConfigBackupDocument.self, from: data),
           fallback.format == currentFormat, fallback.version == 1 {
            return RemoteConfigBackupDocument(
                format: fallback.format,
                version: fallback.version,
                note: fallback.note,
                snapshot: fallback.snapshot.sanitized()
            )
        }
        // Seamless backward compatibility: also accept legacy standalone HID JSON files!
        if let legacyHID = try? RemoteHIDProfile.importData(data) {
            let model = RemoteDeviceProfileRegistry.identify(
                vendorID: legacyHID.device.vendorID,
                productID: legacyHID.device.productID,
                productName: legacyHID.device.productName
            ) ?? .googleG9N9N
            let wrapped = RemoteSyncConfigSnapshot(
                sourcePeerName: "\(legacyHID.device.productName) 硬件码备份",
                exportedAt: legacyHID.createdAt,
                activeModel: model,
                modelBindings: [:],
                namedProfiles: [],
                libraryActions: [],
                learnedHIDProfile: legacyHID
            )
            return RemoteConfigBackupDocument(
                format: currentFormat,
                version: 1,
                note: "从旧版硬件码文件升级导入",
                snapshot: wrapped
            )
        }
        throw RemoteConfigBackupError.unsupportedFormat
    }
}

/// Metadata entry for one-click local snapshot backups stored in Application Support.
struct RemoteLocalBackupRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var createdAt: Date = Date()
    var fileName: String
    var configuredKeysCount: Int
    var namedProfilesCount: Int
    var libraryActionsCount: Int
    var learnedHIDKeysCount: Int = 0
    var isAutomaticSafetyBackup: Bool = false
}

struct RemoteConfigSyncResult: Equatable {
    let strategy: RemoteConfigSyncStrategy
    let sourcePeerName: String
    let updatedKeyGestureCount: Int
    let syncedProfileCount: Int
    let syncedLibraryActionCount: Int
    let restoredHIDKeyCount: Int
    let createdSafetyBackup: Bool

    init(
        strategy: RemoteConfigSyncStrategy,
        sourcePeerName: String,
        updatedKeyGestureCount: Int,
        syncedProfileCount: Int,
        syncedLibraryActionCount: Int,
        restoredHIDKeyCount: Int = 0,
        createdSafetyBackup: Bool = false
    ) {
        self.strategy = strategy
        self.sourcePeerName = sourcePeerName
        self.updatedKeyGestureCount = updatedKeyGestureCount
        self.syncedProfileCount = syncedProfileCount
        self.syncedLibraryActionCount = syncedLibraryActionCount
        self.restoredHIDKeyCount = restoredHIDKeyCount
        self.createdSafetyBackup = createdSafetyBackup
    }

    var summaryMessage: String {
        let hidHint = restoredHIDKeyCount > 0 ? "、恢复 \(restoredHIDKeyCount) 个自定义硬件码" : ""
        switch strategy {
        case .merge:
            return "已从「\(sourcePeerName)」合并配置：补全 \(updatedKeyGestureCount) 项按键动作、新增 \(syncedProfileCount) 个方案、\(syncedLibraryActionCount) 个动作库条目\(hidHint)"
        case .overwrite:
            let safetyHint = createdSafetyBackup ? "（已自动保存覆盖前备份）" : ""
            return "已用「\(sourcePeerName)」覆盖配置：更新 \(updatedKeyGestureCount) 项按键动作、同步 \(syncedProfileCount) 个方案、\(syncedLibraryActionCount) 个动作库条目\(hidHint)\(safetyHint)"
        }
    }
}

struct RemoteTrustedPeer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var sharedSecretHex: String
    var lastHost: String?
    var lastPort: UInt16
    var pairedAt: Date = Date()
}

struct RemoteDiscoveredPeer: Identifiable, Equatable {
    var id: String
    var name: String
    var host: String?
    var port: UInt16
    var viaBonjour: Bool
    var isTrusted: Bool
    var lastSeen: Date
}

struct RemoteIncomingPairingRequest: Identifiable, Equatable {
    let id: UUID
    let peerID: String
    let peerName: String
    let verificationCode: String
    let receivedAt: Date
}

enum RemoteLANPortValidator {
    static let defaultPort: UInt16 = 49_280
    static let bonjourServiceType = "_moteflow._tcp"

    static func validatedPort(_ raw: Int) -> UInt16? {
        guard (1024...65535).contains(raw) else { return nil }
        return UInt16(raw)
    }

    static func parseEndpoint(_ rawInput: String, fallbackPort: UInt16) -> (host: String, port: UInt16)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let ipv6Host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard !ipv6Host.isEmpty else { return nil }
            let remainder = trimmed[trimmed.index(after: closing)...]
            if remainder.isEmpty {
                return (ipv6Host, fallbackPort)
            }
            if remainder.first == ":",
               let portVal = Int(remainder.dropFirst()),
               let port = validatedPort(portVal) {
                return (ipv6Host, port)
            }
            return nil
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 {
            let host = String(parts[0])
            guard !host.contains(" ") else { return nil }
            return (host, fallbackPort)
        }
        if parts.count == 2 {
            let host = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !host.contains(" "),
                  let portInt = Int(parts[1]),
                  let port = validatedPort(portInt) else { return nil }
            return (host, port)
        }
        return nil
    }

    static func sameIPv4Subnet(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.split(separator: ".")
        let b = rhs.split(separator: ".")
        guard a.count == 4, b.count == 4 else { return false }
        return a[0] == b[0] && a[1] == b[1] && a[2] == b[2]
    }
}

enum RemoteLANAuth {
    static func randomHex(byteCount: Int = 32) -> String {
        let key = SymmetricKey(size: .init(bitCount: max(16, byteCount) * 8))
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 32, clean.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func computeHMAC(
        secretHex: String,
        role: String,
        clientID: String,
        serverID: String,
        clientNonce: String,
        serverNonce: String
    ) -> String? {
        guard let keyData = dataFromHex(secretHex) else { return nil }
        let key = SymmetricKey(data: keyData)
        let message = "MOTEFLOW_V1|\(role)|\(clientID)|\(serverID)|\(clientNonce)|\(serverNonce)"
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.lowercased().utf8)
        let b = Array(rhs.lowercased().utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for index in a.indices {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }

    static func verificationCode(
        clientID: String,
        serverID: String,
        clientNonce: String,
        serverNonce: String,
        secretHex: String
    ) -> String {
        let material = "MOTEFLOW_PAIR_CODE|\(clientID)|\(serverID)|\(clientNonce)|\(serverNonce)|\(secretHex.lowercased())"
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        let raw = (UInt32(digest[0]) << 24) |
                  (UInt32(digest[1]) << 16) |
                  (UInt32(digest[2]) << 8) |
                  UInt32(digest[3])
        let sixDigits = Int(raw % 1_000_000)
        let formatted = String(format: "%06d", sixDigits)
        return "\(formatted.prefix(3)) \(formatted.suffix(3))"
    }

    static func autoConnectDelaySeconds(localPeerID: String, remotePeerID: String) -> Double {
        localPeerID < remotePeerID ? 0.35 : 2.25
    }
}

/// Safe subset of multi-step library actions allowed to cross LAN in senderMapping mode.
struct RemoteLANForwardedStep: Codable, Equatable {
    var kind: RemoteActionStepKind
    var shortcut: RemoteShortcut?
    var holdSeconds: Double
    var waitSeconds: Double
    var applicationBundleID: String?
    var applicationName: String?

    static func sanitizedSteps(from steps: [RemoteActionStep]?) -> [RemoteLANForwardedStep]? {
        guard let steps, !steps.isEmpty else { return nil }
        let safe = steps.compactMap { step -> RemoteLANForwardedStep? in
            switch step.kind {
            case .keyboard:
                guard step.shortcut != nil else { return nil }
                return RemoteLANForwardedStep(
                    kind: .keyboard, shortcut: step.shortcut,
                    holdSeconds: step.holdSeconds, waitSeconds: 0,
                    applicationBundleID: nil, applicationName: nil
                )
            case .wait:
                return RemoteLANForwardedStep(
                    kind: .wait, shortcut: nil,
                    holdSeconds: 0.08, waitSeconds: step.waitSeconds,
                    applicationBundleID: nil, applicationName: nil
                )
            case .openApp:
                guard let bundleID = step.applicationBundleID, !bundleID.isEmpty else { return nil }
                return RemoteLANForwardedStep(
                    kind: .openApp, shortcut: nil,
                    holdSeconds: 0.08, waitSeconds: 0,
                    applicationBundleID: bundleID, applicationName: step.applicationName
                )
            case .script:
                return nil
            }
        }
        return safe.isEmpty ? nil : safe
    }

    func toActionStep() -> RemoteActionStep {
        RemoteActionStep(
            kind: kind,
            shortcut: shortcut,
            holdSeconds: holdSeconds,
            waitSeconds: waitSeconds,
            applicationBundleID: applicationBundleID,
            applicationName: applicationName
        )
    }
}

struct RemoteLANBeaconPayload: Codable, Equatable {
    static let currentMagic = "MOTEFLOW_BEACON_V1"
    var magic: String = Self.currentMagic
    var peerID: String
    var peerName: String
    var tcpPort: UInt16
    var sentAtMs: Double
}

enum RemoteLANWireMessage: Codable, Equatable {
    case serverChallenge(peerID: String, peerName: String, serverNonce: String)
    case authenticate(peerID: String, peerName: String, clientNonce: String, hmacHex: String)
    case authAccepted(peerID: String, peerName: String, serverHmacHex: String)
    case pairingRequired(reason: String)
    case pairRequest(
        requestID: UUID,
        peerID: String,
        peerName: String,
        clientNonce: String,
        proposedSecretHex: String
    )
    case pairDecision(
        requestID: UUID,
        accepted: Bool,
        peerID: String,
        peerName: String,
        serverHmacHex: String?,
        message: String
    )
    case ping(sentAtMs: Double)
    case pong(sentAtMs: Double)
    case focusChanged(controllingReceiver: Bool, controllerName: String)
    case requestTargetSwitch(controlRequester: Bool, requesterName: String, triggerAppName: String?)
    case peerStateSync(dispatchMode: RemoteRelayDispatchMode, hasPhysicalRemote: Bool)
    case mappingPolicySync(
        standardPeerID: String?,
        independent: Bool,
        revision: UInt64,
        hasPhysicalRemote: Bool
    )
    case liveMappingSnapshot(snapshot: RemoteSyncConfigSnapshot)
    case requestConfigSnapshot(requestID: UUID)
    case configSnapshotResponse(requestID: UUID, snapshot: RemoteSyncConfigSnapshot)
    case forwardedAction(
        key: RemoteKey,
        gesture: RemoteGesture,
        mode: RemoteRelayDispatchMode,
        senderModel: RemoteDeviceModel,
        shortcut: RemoteShortcut?,
        holdSeconds: Double?,
        systemAction: RemoteSystemAction?,
        librarySteps: [RemoteLANForwardedStep]?
    )
    case holdStart(
        key: RemoteKey,
        mode: RemoteRelayDispatchMode,
        senderModel: RemoteDeviceModel,
        shortcut: RemoteShortcut?
    )
    case holdEnd(key: RemoteKey)
    case voiceStart(
        sampleRate: Int,
        mode: RemoteRelayDispatchMode,
        shortcut: RemoteShortcut?,
        trigger: DoubaoShortcutTrigger
    )
    case voicePCM(samplesLE: Data, sampleRate: Int)
    case voiceEnd
    case disconnect(reason: String)
}

enum RemoteLANFrameError: LocalizedError, Equatable {
    case frameTooLarge(Int)
    case emptyFrame

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size):
            "局域网数据包超出安全上限（\(size) 字节）"
        case .emptyFrame:
            "收到空的局域网数据帧"
        }
    }
}

enum RemoteLANFrameCodec {
    static let maxFrameBytes = 524_288

    static func encode(_ message: RemoteLANWireMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty else { throw RemoteLANFrameError.emptyFrame }
        guard payload.count <= maxFrameBytes else {
            throw RemoteLANFrameError.frameTooLarge(payload.count)
        }
        var lengthBE = UInt32(payload.count).bigEndian
        var framed = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &lengthBE) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    struct StreamDeframer {
        private var buffer = Data()

        mutating func reset() {
            buffer.removeAll(keepingCapacity: false)
        }

        mutating func append(_ chunk: Data) throws -> [RemoteLANWireMessage] {
            guard !chunk.isEmpty else { return [] }
            buffer.append(chunk)
            var decoded: [RemoteLANWireMessage] = []
            let decoder = JSONDecoder()

            while buffer.count >= 4 {
                let b0 = UInt32(buffer[buffer.startIndex])
                let b1 = UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 1)])
                let b2 = UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 2)])
                let b3 = UInt32(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
                let length = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

                if length <= 0 {
                    buffer.removeAll()
                    throw RemoteLANFrameError.emptyFrame
                }
                if length > RemoteLANFrameCodec.maxFrameBytes {
                    buffer.removeAll()
                    throw RemoteLANFrameError.frameTooLarge(length)
                }
                guard buffer.count >= 4 + length else { break }

                let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
                let payloadEnd = buffer.index(payloadStart, offsetBy: length)
                let payload = Data(buffer[payloadStart..<payloadEnd])
                buffer.removeSubrange(buffer.startIndex..<payloadEnd)
                if let msg = try? decoder.decode(RemoteLANWireMessage.self, from: payload) {
                    decoded.append(msg)
                } else {
                    _ = try JSONSerialization.jsonObject(with: payload)
                }
            }
            return decoded
        }
    }
}

enum RemoteLANPCMCodec {
    static func encodeSamples(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decodeSamples(_ data: Data) -> [Int16] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var result: [Int16] = []
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for idx in 0..<count {
                let lo = UInt16(raw[idx * 2])
                let hi = UInt16(raw[idx * 2 + 1]) << 8
                result.append(Int16(bitPattern: lo | hi))
            }
        }
        return result
    }
}
