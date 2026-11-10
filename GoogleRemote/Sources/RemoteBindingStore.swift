import Combine
import Foundation

/// Persistent, local-only mapping configuration. Nothing here installs global
/// event taps or claims that the remote's HID events have been implemented.
@MainActor
final class RemoteBindingStore: ObservableObject {
    @Published private(set) var bindings: [RemoteKey: RemoteBinding] = [:]
    @Published private(set) var activeModel: RemoteDeviceModel = .googleG9N9N
    private let defaults: UserDefaults
    private let storageKey = "GoogleRemote.keyBindings.v1"
    private let modelStorageKey = "MoteFlow.remoteModels.v1"
    private let selectedModelKey = "MoteFlow.selectedRemoteModel.v1"
    private var savedModels: [String: [RemoteKey: RemoteBinding]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        bindings = savedModels[activeModel.id] ?? Self.factoryActionBindings(for: activeModel)
        if savedModels[activeModel.id] == nil { save() }
    }

    /// Model-scoped actions: switching remotes must never overwrite the user's
    /// existing Chromecast mappings. Auto-execution remains a separate opt-in.
    func selectModel(_ model: RemoteDeviceModel) {
        guard model != activeModel else { return }
        savedModels[activeModel.id] = bindings
        activeModel = model
        bindings = savedModels[model.id] ?? Self.factoryActionBindings(for: model)
        defaults.set(model.id, forKey: selectedModelKey)
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

    /// Safe first-run suggestions, not unverified HID report codes.
    /// A new device still needs a real hardware match or learning session.
    static func factoryActionBindings(for model: RemoteDeviceModel) -> [RemoteKey: RemoteBinding] {
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
        // Home opens the same editable action-library ChatGPT preset as the
        // existing MoteFlow workflow. No action runs until users opt in.
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

    /// The caller must explicitly confirm replacing a conflicting mapping.
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
        save()
    }

    private func save() {
        let profile = RemoteProfile(bindings: bindings)
        guard let encoded = try? JSONEncoder().encode(profile) else { return }
        savedModels[activeModel.id] = bindings
        // Only Google maps are written to the legacy key; a Xiaomi selection
        // must not destroy legacy user data.
        if activeModel == .googleG9N9N { defaults.set(encoded, forKey: storageKey) }
        if let all = try? JSONEncoder().encode(savedModels) {
            defaults.set(all, forKey: modelStorageKey)
        }
    }
}
