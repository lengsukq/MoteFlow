import Combine
import Foundation

/// A user-owned snapshot, distinct from immutable factory defaults and the
/// current editable working copy. Scoped to one physical remote model.
struct RemoteNamedMappingProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var modelID: String
    var bindings: [RemoteKey: RemoteBinding]
}

/// Persistent, local-only mapping configuration plus portable backup/export/import
/// and local snapshot history.
@MainActor
final class RemoteBindingStore: ObservableObject {
    @Published private(set) var bindings: [RemoteKey: RemoteBinding] = [:]
    @Published private(set) var activeModel: RemoteDeviceModel = .googleG9N9N
    @Published private(set) var namedProfiles: [RemoteNamedMappingProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var profileError: String?
    @Published private(set) var localBackups: [RemoteLocalBackupRecord] = []

    private let defaults: UserDefaults
    private let backupDirectoryURL: URL
    private let storageKey = "GoogleRemote.keyBindings.v1"
    private let modelStorageKey = "MoteFlow.remoteModels.v1"
    private let selectedModelKey = "MoteFlow.selectedRemoteModel.v1"
    private let googleSideKeyMigrationKey = "MoteFlow.googleSideClipboardMapping.v1"
    private let profilesKey = "MoteFlow.namedMappingProfiles.v1"
    private let activeProfilesKey = "MoteFlow.activeNamedMappingProfiles.v1"
    private static let maxLocalBackups = 12
    private var savedModels: [String: [RemoteKey: RemoteBinding]] = [:]
    private var selectedProfiles: [String: UUID] = [:]

    init(defaults: UserDefaults = .standard, backupDirectoryURL: URL? = nil) {
        self.defaults = defaults
        self.backupDirectoryURL = backupDirectoryURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoogleRemote", isDirectory: true)
            .appendingPathComponent("ConfigBackups", isDirectory: true)

        if let data = defaults.data(forKey: modelStorageKey),
           let saved = try? JSONDecoder().decode([String: [RemoteKey: RemoteBinding]].self, from: data) {
            savedModels = saved
        }
        // Preserve v1 Chromecast bindings for existing installations.
        if savedModels[RemoteDeviceModel.googleG9N9N.id] == nil,
           let data = defaults.data(forKey: storageKey),
           let profile = try? JSONDecoder().decode(RemoteProfile.self, from: data),
           profile.version == 1 {
            savedModels[RemoteDeviceModel.googleG9N9N.id] = profile.bindings
        }
        let preferred = defaults.string(forKey: selectedModelKey)
        activeModel = preferred.flatMap(RemoteDeviceModel.init(rawValue:)) ?? .googleG9N9N
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([RemoteNamedMappingProfile].self, from: data) {
            namedProfiles = profiles
        }
        if let data = defaults.data(forKey: activeProfilesKey),
           let selected = try? JSONDecoder().decode([String: UUID].self, from: data) {
            selectedProfiles = selected
        }
        activeProfileID = selectedProfiles[activeModel.id].flatMap { id in
            namedProfiles.contains(where: { $0.id == id && $0.modelID == activeModel.id }) ? id : nil
        }
        bindings = savedModels[activeModel.id] ?? Self.factoryActionBindings(for: activeModel)
        if savedModels[activeModel.id] == nil { save() }
        migrateGoogleSideKeysIfNeeded()
        loadLocalBackupIndex()
    }

    /// Model-scoped actions: switching remotes must never overwrite the user's
    /// existing Chromecast mappings. Auto-execution remains a separate opt-in.
    func selectModel(_ model: RemoteDeviceModel) {
        guard model != activeModel else { return }
        savedModels[activeModel.id] = bindings
        activeModel = model
        bindings = savedModels[model.id] ?? Self.factoryActionBindings(for: model)
        activeProfileID = selectedProfiles[model.id].flatMap { id in
            namedProfiles.contains(where: { $0.id == id && $0.modelID == model.id }) ? id : nil
        }
        defaults.set(model.id, forKey: selectedModelKey)
        save()
        migrateGoogleSideKeysIfNeeded()
    }

    private func migrateGoogleSideKeysIfNeeded() {
        guard activeModel == .googleG9N9N,
              !defaults.bool(forKey: googleSideKeyMigrationKey) else { return }
        let factory = Self.factoryActionBindings(for: .googleG9N9N)
        var changed = false
        for key in [RemoteKey.volumeUp, .volumeDown] where !binding(for: key).isConfigured {
            if let mapping = factory[key] {
                bindings[key] = mapping
                changed = true
            }
        }
        defaults.set(true, forKey: googleSideKeyMigrationKey)
        if changed { save() }
    }

    @discardableResult
    func applyGoogleSideKeyClipboardPreset() -> Bool {
        guard activeModel == .googleG9N9N else {
            profileError = "此侧键预设仅用于 Google G9N9N 遥控器"
            return false
        }
        let factory = Self.factoryActionBindings(for: .googleG9N9N)
        guard let upper = factory[.volumeUp], let lower = factory[.volumeDown] else {
            profileError = "侧键预设尚未初始化"
            return false
        }
        bindings[.volumeUp] = upper
        bindings[.volumeDown] = lower
        profileError = nil
        save()
        return true
    }

    var profilesForActiveModel: [RemoteNamedMappingProfile] {
        namedProfiles.filter { $0.modelID == activeModel.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var activeNamedProfile: RemoteNamedMappingProfile? {
        guard let activeProfileID else { return nil }
        return namedProfiles.first { $0.id == activeProfileID && $0.modelID == activeModel.id }
    }

    var hasUnsavedNamedChanges: Bool {
        guard let profile = activeNamedProfile else { return false }
        return bindings != profile.bindings
    }

    func applyFactoryMapping() {
        bindings = Self.factoryActionBindings(for: activeModel)
        activeProfileID = nil
        selectedProfiles.removeValue(forKey: activeModel.id)
        profileError = nil
        save()
    }

    @discardableResult
    func applyNamedProfile(_ id: UUID) -> Bool {
        guard let profile = namedProfiles.first(where: {
            $0.id == id && $0.modelID == activeModel.id
        }) else {
            profileError = "该映射方案不存在，或属于其他遥控器型号"
            return false
        }
        bindings = profile.bindings
        activeProfileID = id
        selectedProfiles[activeModel.id] = id
        profileError = nil
        save()
        return true
    }

    private func checkedProfileName(_ raw: String, excluding id: UUID? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 40 else {
            profileError = "名称需要 1–40 个字符"
            return nil
        }
        guard !namedProfiles.contains(where: {
            $0.modelID == activeModel.id && $0.id != id &&
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            profileError = "该遥控器已有同名方案，请换一个名称"
            return nil
        }
        return name
    }

    @discardableResult
    func saveAsNamedProfile(_ rawName: String) -> Bool {
        guard let name = checkedProfileName(rawName) else { return false }
        let profile = RemoteNamedMappingProfile(
            name: name, modelID: activeModel.id, bindings: bindings
        )
        namedProfiles.append(profile)
        activeProfileID = profile.id
        selectedProfiles[activeModel.id] = profile.id
        profileError = nil
        save()
        return true
    }

    @discardableResult
    func updateActiveNamedProfile() -> Bool {
        guard let id = activeProfileID,
              let index = namedProfiles.firstIndex(where: {
                  $0.id == id && $0.modelID == activeModel.id
              }) else {
            profileError = "请先另存为一个命名方案"
            return false
        }
        namedProfiles[index].bindings = bindings
        profileError = nil
        save()
        return true
    }

    @discardableResult
    func renameNamedProfile(_ id: UUID, to rawName: String) -> Bool {
        guard let index = namedProfiles.firstIndex(where: {
            $0.id == id && $0.modelID == activeModel.id
        }) else {
            profileError = "找不到要重命名的方案"
            return false
        }
        guard let name = checkedProfileName(rawName, excluding: id) else { return false }
        namedProfiles[index].name = name
        profileError = nil
        save()
        return true
    }

    @discardableResult
    func deleteNamedProfile(_ id: UUID) -> Bool {
        guard let index = namedProfiles.firstIndex(where: {
            $0.id == id && $0.modelID == activeModel.id
        }) else {
            profileError = "找不到要删除的方案"
            return false
        }
        namedProfiles.remove(at: index)
        if activeProfileID == id {
            activeProfileID = nil
            selectedProfiles.removeValue(forKey: activeModel.id)
        }
        profileError = nil
        save()
        return true
    }

    func setSystemAction(_ systemAction: RemoteSystemAction, for key: RemoteKey,
                         gesture: RemoteGesture) {
        var binding = binding(for: key)
        binding.setAction(RemoteAction(kind: .systemAction, systemAction: systemAction),
                          for: gesture)
        bindings[key] = binding
        save()
    }

    func setOutputHoldMode(_ mode: RemoteOutputHoldMode, for key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        var action = binding.action(for: gesture)
        action.outputHoldMode = mode
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
    }

    // MARK: - Portable JSON Export / Import & Local Snapshot Backups

    func exportBackupDocument(peerName: String, note: String? = nil, library: RemoteLibraryStore) -> RemoteConfigBackupDocument {
        RemoteConfigBackupDocument(
            note: note,
            snapshot: exportSyncSnapshot(peerName: peerName, library: library)
        )
    }

    func exportBackupJSONData(peerName: String, note: String? = nil, library: RemoteLibraryStore) throws -> Data {
        try exportBackupDocument(peerName: peerName, note: note, library: library).exportJSONData()
    }

    @discardableResult
    func createLocalBackup(
        label: String,
        peerName: String,
        library: RemoteLibraryStore,
        isAutomaticSafetyBackup: Bool = false
    ) throws -> RemoteLocalBackupRecord {
        try FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "backup-\(id.uuidString).json"
        let doc = exportBackupDocument(peerName: peerName, note: label, library: library)
        let data = try doc.exportJSONData()
        try data.write(to: backupDirectoryURL.appendingPathComponent(fileName), options: .atomic)

        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = RemoteLocalBackupRecord(
            id: id,
            label: cleanLabel.isEmpty ? "手动配置备份" : String(cleanLabel.prefix(48)),
            createdAt: Date(),
            fileName: fileName,
            configuredKeysCount: doc.snapshot.totalConfiguredKeyCount,
            namedProfilesCount: doc.snapshot.namedProfiles.count,
            libraryActionsCount: doc.snapshot.libraryActions.count,
            isAutomaticSafetyBackup: isAutomaticSafetyBackup
        )
        localBackups.insert(record, at: 0)
        pruneExcessLocalBackups()
        persistLocalBackupIndex()
        return record
    }

    @discardableResult
    func restoreLocalBackup(
        _ id: UUID,
        strategy: RemoteConfigSyncStrategy,
        library: RemoteLibraryStore
    ) throws -> RemoteConfigSyncResult {
        guard let record = localBackups.first(where: { $0.id == id }) else {
            throw RemoteConfigBackupError.corruptedData("本地备份记录不存在或已被清理")
        }
        let fileURL = backupDirectoryURL.appendingPathComponent(record.fileName)
        let data = try Data(contentsOf: fileURL)
        let doc = try RemoteConfigBackupDocument.importJSONData(data)
        var labeledSnapshot = doc.snapshot
        labeledSnapshot.sourcePeerName = record.label
        return applySyncedSnapshot(
            labeledSnapshot,
            strategy: strategy,
            library: library,
            createSafetyBackupOnOverwrite: !record.isAutomaticSafetyBackup
        )
    }

    func deleteLocalBackup(_ id: UUID) {
        guard let idx = localBackups.firstIndex(where: { $0.id == id }) else { return }
        let removed = localBackups.remove(at: idx)
        let fileURL = backupDirectoryURL.appendingPathComponent(removed.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        persistLocalBackupIndex()
    }

    private var backupIndexURL: URL {
        backupDirectoryURL.appendingPathComponent("index.json")
    }

    private func loadLocalBackupIndex() {
        guard FileManager.default.fileExists(atPath: backupIndexURL.path),
              let data = try? Data(contentsOf: backupIndexURL),
              let decoded = try? JSONDecoder().decode([RemoteLocalBackupRecord].self, from: data) else {
            return
        }
        localBackups = decoded.filter {
            FileManager.default.fileExists(atPath: backupDirectoryURL.appendingPathComponent($0.fileName).path)
        }
    }

    private func pruneExcessLocalBackups() {
        while localBackups.count > Self.maxLocalBackups {
            let oldest = localBackups.removeLast()
            try? FileManager.default.removeItem(at: backupDirectoryURL.appendingPathComponent(oldest.fileName))
        }
    }

    private func persistLocalBackupIndex() {
        try? FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(localBackups) {
            try? data.write(to: backupIndexURL, options: .atomic)
        }
    }

    // MARK: - Dual-Mac Configuration Export & Merge / Overwrite Sync

    func exportSyncSnapshot(peerName: String, library: RemoteLibraryStore) -> RemoteSyncConfigSnapshot {
        var allModels = savedModels
        allModels[activeModel.id] = bindings
        for model in RemoteDeviceModel.allCases where allModels[model.id] == nil {
            allModels[model.id] = Self.factoryActionBindings(for: model)
        }
        return RemoteSyncConfigSnapshot(
            sourcePeerName: peerName,
            exportedAt: Date(),
            activeModel: activeModel,
            modelBindings: allModels,
            namedProfiles: namedProfiles,
            libraryActions: library.exportSyncableActions()
        ).sanitized()
    }

    @discardableResult
    func applySyncedSnapshot(
        _ rawSnapshot: RemoteSyncConfigSnapshot,
        strategy: RemoteConfigSyncStrategy,
        library: RemoteLibraryStore,
        createSafetyBackupOnOverwrite: Bool = true
    ) -> RemoteConfigSyncResult {
        let snapshot = rawSnapshot.sanitized()
        savedModels[activeModel.id] = bindings

        var createdSafety = false
        if strategy == .overwrite && createSafetyBackupOnOverwrite {
            let localHost = Host.current().localizedName ?? "本机"
            if (try? createLocalBackup(
                label: "覆盖前自动保护备份",
                peerName: localHost,
                library: library,
                isAutomaticSafetyBackup: true
            )) != nil {
                createdSafety = true
            }
        }

        let syncedLibraryCount = library.applySyncedActions(snapshot.libraryActions, strategy: strategy)
        var updatedGestures = 0

        switch strategy {
        case .merge:
            for (modelID, remoteMap) in snapshot.modelBindings {
                guard RemoteDeviceModel(rawValue: modelID) != nil else { continue }
                var localMap = savedModels[modelID] ?? [:]
                for (key, remoteBinding) in remoteMap {
                    var current = localMap[key] ?? RemoteBinding()
                    var changedKey = false
                    for gesture in RemoteGesture.allCases {
                        let localAction = current.action(for: gesture)
                        let incomingAction = remoteBinding.action(for: gesture)
                        if !Self.isActionConfigured(localAction) && Self.isActionConfigured(incomingAction) {
                            current.setAction(incomingAction, for: gesture)
                            updatedGestures += 1
                            changedKey = true
                        }
                    }
                    if changedKey && current.longPressThreshold == nil,
                       let remoteThreshold = remoteBinding.longPressThreshold {
                        current.longPressThreshold = remoteThreshold
                    }
                    if current.isConfigured || localMap[key] != nil {
                        localMap[key] = current
                    }
                }
                savedModels[modelID] = localMap
            }

        case .overwrite:
            activeModel = snapshot.activeModel
            defaults.set(activeModel.id, forKey: selectedModelKey)
            for (modelID, remoteMap) in snapshot.modelBindings {
                guard RemoteDeviceModel(rawValue: modelID) != nil else { continue }
                var nextMap: [RemoteKey: RemoteBinding] = [:]
                let previousMap = savedModels[modelID] ?? [:]
                let allKeys = Set(previousMap.keys).union(remoteMap.keys)
                for key in allKeys {
                    let prev = previousMap[key] ?? RemoteBinding()
                    var incoming = remoteMap[key] ?? RemoteBinding()
                    for gesture in RemoteGesture.allCases {
                        if prev.action(for: gesture).kind == .script &&
                            !Self.isActionConfigured(incoming.action(for: gesture)) {
                            incoming.setAction(prev.action(for: gesture), for: gesture)
                        } else if prev.action(for: gesture) != incoming.action(for: gesture) {
                            updatedGestures += 1
                        }
                    }
                    if incoming.isConfigured {
                        nextMap[key] = incoming
                    }
                }
                savedModels[modelID] = nextMap
            }
            activeProfileID = nil
            selectedProfiles.removeValue(forKey: activeModel.id)
        }

        // Sync named mapping profiles
        var syncedProfileCount = 0
        for incomingProfile in snapshot.namedProfiles {
            guard RemoteDeviceModel(rawValue: incomingProfile.modelID) != nil else { continue }
            let baseName = String(incomingProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard !baseName.isEmpty else { continue }

            if let idx = namedProfiles.firstIndex(where: { $0.id == incomingProfile.id }) {
                if strategy == .overwrite && namedProfiles[idx] != incomingProfile {
                    namedProfiles[idx] = RemoteNamedMappingProfile(
                        id: incomingProfile.id,
                        name: baseName,
                        modelID: incomingProfile.modelID,
                        bindings: incomingProfile.bindings
                    )
                    syncedProfileCount += 1
                }
            } else {
                var finalName = baseName
                if let nameClashIdx = namedProfiles.firstIndex(where: {
                    $0.modelID == incomingProfile.modelID &&
                    $0.name.localizedCaseInsensitiveCompare(baseName) == .orderedSame
                }) {
                    if strategy == .overwrite {
                        namedProfiles[nameClashIdx] = RemoteNamedMappingProfile(
                            id: incomingProfile.id,
                            name: baseName,
                            modelID: incomingProfile.modelID,
                            bindings: incomingProfile.bindings
                        )
                        syncedProfileCount += 1
                        continue
                    } else {
                        let suffix = "（来自\(snapshot.sourcePeerName.prefix(8))）"
                        finalName = String(baseName.prefix(max(1, 40 - suffix.count))) + suffix
                    }
                }
                if !namedProfiles.contains(where: {
                    $0.modelID == incomingProfile.modelID &&
                    $0.name.localizedCaseInsensitiveCompare(finalName) == .orderedSame
                }) {
                    namedProfiles.append(RemoteNamedMappingProfile(
                        id: incomingProfile.id,
                        name: finalName,
                        modelID: incomingProfile.modelID,
                        bindings: incomingProfile.bindings
                    ))
                    syncedProfileCount += 1
                }
            }
        }

        bindings = savedModels[activeModel.id] ?? Self.factoryActionBindings(for: activeModel)
        profileError = nil
        save()

        return RemoteConfigSyncResult(
            strategy: strategy,
            sourcePeerName: snapshot.sourcePeerName,
            updatedKeyGestureCount: updatedGestures,
            syncedProfileCount: syncedProfileCount,
            syncedLibraryActionCount: syncedLibraryCount,
            createdSafetyBackup: createdSafety
        )
    }

    private static func isActionConfigured(_ action: RemoteAction) -> Bool {
        switch action.kind {
        case .none:
            false
        case .keyboardShortcut:
            action.shortcut != nil
        case .systemAction:
            action.systemAction != nil
        case .libraryAction:
            action.presetID != nil
        case .script:
            action.scriptPath != nil || action.scriptID != nil
        case .voiceInput:
            true
        }
    }

    static func factoryActionBindings(for model: RemoteDeviceModel) -> [RemoteKey: RemoteBinding] {
        if model == .googleG9N9N {
            let directions: [(RemoteKey, UInt16, String)] = [
                (.up, 126, "↑"), (.down, 125, "↓"),
                (.left, 123, "←"), (.right, 124, "→")
            ]
            var mapping: [RemoteKey: RemoteBinding] = [:]
            for (key, code, label) in directions {
                let shortcut = RemoteShortcut(
                    keyCode: code, keyLabel: label,
                    command: false, shift: false, option: false, control: false
                )
                mapping[key] = RemoteBinding(
                    kind: .keyboardShortcut, shortcut: shortcut,
                    longPressAction: RemoteAction(
                        kind: .keyboardShortcut, shortcut: shortcut,
                        outputHoldMode: .physical
                    ),
                    longPressThreshold: 0.35
                )
            }
            for (key, code, label) in [
                (RemoteKey.select, UInt16(36), "Return"),
                (.back, UInt16(53), "Esc")
            ] {
                mapping[key] = RemoteBinding(kind: .keyboardShortcut, shortcut: RemoteShortcut(
                    keyCode: code, keyLabel: label,
                    command: false, shift: false, option: false, control: false
                ))
            }
            mapping[.volumeUp] = RemoteBinding(
                kind: .systemAction, systemAction: .copy,
                longPressAction: RemoteAction(kind: .systemAction,
                                              systemAction: .selectAllAndCopy)
            )
            mapping[.volumeDown] = RemoteBinding(
                kind: .systemAction, systemAction: .paste,
                longPressAction: RemoteAction(kind: .systemAction,
                                              systemAction: .selectAllAndPaste)
            )
            return mapping
        }
        guard model == .xiaomiRemote2 || model == .xiaomiRemote2Pro else { return [:] }
        let defaults: [(RemoteKey, UInt16, String)] = [
            (.up, 126, "↑"), (.down, 125, "↓"),
            (.left, 123, "←"), (.right, 124, "→"),
            (.select, 36, "Return"), (.back, 53, "Esc")
        ]
        var seeded = Dictionary(uniqueKeysWithValues: defaults.map { key, code, label in
            (key, RemoteBinding(kind: .keyboardShortcut, shortcut: RemoteShortcut(
                keyCode: code, keyLabel: label,
                command: false, shift: false, option: false, control: false
            )))
        })
        seeded[.home] = RemoteBinding(
            kind: .libraryAction, presetID: RemoteLibraryStore.chatGPTPresetID
        )
        return seeded
    }

    func binding(for key: RemoteKey) -> RemoteBinding {
        bindings[key] ?? RemoteBinding()
    }

    var configuredCount: Int {
        activeModel.keys.filter { binding(for: $0).isConfigured }.count
    }

    func setKind(_ kind: RemoteBindingKind, for key: RemoteKey) {
        setKind(kind, for: key, gesture: .tap)
    }

    func action(for key: RemoteKey, gesture: RemoteGesture) -> RemoteAction {
        binding(for: key).action(for: gesture)
    }

    func setKind(_ kind: RemoteBindingKind, for key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        var action = binding.action(for: gesture)
        if action.kind != kind {
            action = RemoteAction(kind: kind)
        }
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
    }

    func setLibraryAction(_ id: UUID?, for key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        var action = RemoteAction(kind: .libraryAction)
        action.presetID = id
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
    }

    func conflictingKey(for shortcut: RemoteShortcut, excluding selected: RemoteKey,
                        gesture: RemoteGesture = .tap) -> RemoteKey? {
        RemoteKey.allCases.first {
            $0 != selected &&
            action(for: $0, gesture: gesture).kind == .keyboardShortcut &&
            action(for: $0, gesture: gesture).shortcut == shortcut
        }
    }

    func setShortcut(_ shortcut: RemoteShortcut, for key: RemoteKey,
                     replaceConflict: Bool = false) -> Bool {
        setShortcut(shortcut, for: key, gesture: .tap, replaceConflict: replaceConflict)
    }

    func setShortcut(_ shortcut: RemoteShortcut, for key: RemoteKey,
                     gesture: RemoteGesture, replaceConflict: Bool = false) -> Bool {
        if let conflictingKey = conflictingKey(for: shortcut, excluding: key, gesture: gesture) {
            guard replaceConflict else { return false }
            var other = binding(for: conflictingKey)
            other.setAction(RemoteAction(), for: gesture)
            bindings[conflictingKey] = other
        }
        var binding = binding(for: key)
        var action = binding.action(for: gesture)
        action.kind = .keyboardShortcut
        action.shortcut = shortcut
        action.systemAction = nil
        action.scriptPath = nil
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
        return true
    }

    func setScript(_ path: String, for key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        var action = binding.action(for: gesture)
        action.kind = .script
        action.scriptPath = path
        action.shortcut = nil
        action.systemAction = nil
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
    }

    func setOutputHold(_ seconds: Double, for key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        var action = binding.action(for: gesture)
        action.outputHoldSeconds = min(10, max(0.04, seconds))
        binding.setAction(action, for: gesture)
        bindings[key] = binding
        save()
    }

    func setLongPressThreshold(_ seconds: Double, for key: RemoteKey) {
        var binding = binding(for: key)
        binding.longPressThreshold = min(5, max(0.2, seconds))
        bindings[key] = binding
        save()
    }

    func reset(_ key: RemoteKey, gesture: RemoteGesture) {
        var binding = binding(for: key)
        binding.setAction(RemoteAction(), for: gesture)
        bindings[key] = binding
        save()
    }

    func reset(_ key: RemoteKey) {
        bindings.removeValue(forKey: key)
        save()
    }

    func resetAll() {
        bindings.removeAll()
        activeProfileID = nil
        selectedProfiles.removeValue(forKey: activeModel.id)
        save()
    }

    private func save() {
        let profile = RemoteProfile(bindings: bindings)
        guard let encoded = try? JSONEncoder().encode(profile) else { return }
        savedModels[activeModel.id] = bindings
        if activeModel == .googleG9N9N { defaults.set(encoded, forKey: storageKey) }
        if let all = try? JSONEncoder().encode(savedModels) {
            defaults.set(all, forKey: modelStorageKey)
        }
        if let data = try? JSONEncoder().encode(namedProfiles) {
            defaults.set(data, forKey: profilesKey)
        }
        if let data = try? JSONEncoder().encode(selectedProfiles) {
            defaults.set(data, forKey: activeProfilesKey)
        }
    }
}
