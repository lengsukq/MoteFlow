import Combine
import Foundation

enum RemoteScriptLanguage: String, CaseIterable, Codable, Identifiable {
    case bash, zsh, python
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .python: "Python 3"
        }
    }
    var executable: String {
        switch self {
        case .bash: "/bin/bash"
        case .zsh: "/bin/zsh"
        case .python: "/usr/bin/python3"
        }
    }
    var fileExtension: String { self == .python ? "py" : rawValue }
}

/// Both scripts and keyboard shortcuts are just steps inside an action.
enum RemoteActionStepKind: String, Codable, CaseIterable, Identifiable {
    case keyboard
    case script
    case wait
    case openApp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboard: "按键 / 组合键"
        case .script: "本地脚本"
        case .wait: "等待"
        case .openApp: "打开应用"
        }
    }

}

struct RemoteActionStep: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: RemoteActionStepKind
    var shortcut: RemoteShortcut?
    var holdSeconds: Double = 0.08
    var scriptLanguage: RemoteScriptLanguage = .bash
    var scriptSource: String = ""
    var scriptPath: String?
    var waitSeconds: Double = 0.3
    /// Launch Services identity selected from a real .app bundle.
    var applicationBundleID: String?
    var applicationName: String?

    var summary: String {
        switch kind {
        case .keyboard:
            return "\(shortcut?.display ?? "未设置按键") · 按住 \(String(format: "%.2f", holdSeconds)) 秒"
        case .script: return scriptPath.map { URL(fileURLWithPath: $0).lastPathComponent } ??
            "\(scriptLanguage.title) 脚本"
        case .wait: return "等待 \(String(format: "%.2f", waitSeconds)) 秒"
        case .openApp: return "打开 \(applicationName ?? applicationBundleID ?? "尚未选择应用")"
        }
    }
}

struct RemoteLibraryAction: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var steps: [RemoteActionStep] = []
    var modifiedAt: Date = Date()

    var summary: String {
        if steps.isEmpty { return "尚未添加执行步骤" }
        return steps.count == 1 ? steps[0].summary : "\(steps.count) 个执行步骤"
    }
}

private struct RemoteUnifiedLibraryFile: Codable {
    var version: Int = 2
    var actions: [RemoteLibraryAction] = []
}

// Migration only: the previous implementation briefly used two separate arrays.
private struct LegacyScript: Codable {
    var id: UUID
    var name: String
    var language: RemoteScriptLanguage
    var source: String
    var modifiedAt: Date
}
private struct LegacyPreset: Codable {
    var id: UUID
    var name: String
    var action: RemoteAction
    var modifiedAt: Date
}
private struct LegacyLibrary: Codable {
    var version: Int
    var scripts: [LegacyScript]
    var presets: [LegacyPreset]
}

/// One persistent action library: a saved action may be one key, one script,
/// or a sequence of keys/scripts/delays. Mappings reference IDs, not copies.
@MainActor
final class RemoteLibraryStore: ObservableObject {
    static let chatGPTPresetID = UUID(uuidString: "9EB1438B-CA34-4AF7-82AF-2D9CE44AD8BC")!
    @Published private(set) var actions: [RemoteLibraryAction] = []
    @Published private(set) var error: String?
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoogleRemote", isDirectory: true)
            .appendingPathComponent("ActionLibrary.json")
        load()
        installStarterActions()
    }

    func action(_ id: UUID?) -> RemoteLibraryAction? {
        guard let id else { return nil }
        return actions.first { $0.id == id }
    }

    @discardableResult
    func save(_ item: RemoteLibraryAction) -> Bool {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "动作名称不能为空"; return false }
        guard !item.steps.isEmpty, item.steps.count <= 30 else {
            error = "每个动作需要 1–30 个执行步骤"; return false
        }
        guard item.steps.allSatisfy({ step in
            switch step.kind {
            case .keyboard: return step.shortcut != nil && (0.04...10).contains(step.holdSeconds)
            case .script:
                return ((step.scriptPath != nil) || !step.scriptSource.isEmpty) &&
                       step.scriptSource.utf8.count <= 200_000
            case .wait: return (0...30).contains(step.waitSeconds)
            case .openApp:
                let id = step.applicationBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !id.isEmpty && id.count < 240 && !id.contains("/") && !id.contains(" ")
            }
        }) else {
            error = "检查步骤：按键必须录制，脚本不能为空，时间参数须在允许范围内"; return false
        }
        var updated = item
        updated.name = name
        updated.modifiedAt = Date()
        if let index = actions.firstIndex(where: { $0.id == item.id }) {
            actions[index] = updated
        } else {
            actions.append(updated)
        }
        persist()
        return error == nil
    }

    func delete(_ id: UUID) {
        actions.removeAll { $0.id == id }
        persist()
    }

    func description(for action: RemoteAction) -> String {
        if action.kind == .libraryAction {
            return self.action(action.presetID)?.name ?? "动作已删除，请重新选择"
        }
        return action.summary
    }

    /// Missing references must fail closed. No recursive references allowed.
    func steps(for remoteAction: RemoteAction) -> [RemoteActionStep]? {
        switch remoteAction.kind {
        case .none, .voiceInput: return nil
        case .libraryAction: return action(remoteAction.presetID)?.steps
        case .keyboardShortcut:
            guard let shortcut = remoteAction.shortcut else { return nil }
            return [RemoteActionStep(kind: .keyboard, shortcut: shortcut,
                                     holdSeconds: remoteAction.effectiveHoldSeconds)]
        case .script:
            if let path = remoteAction.scriptPath {
                return [RemoteActionStep(kind: .script, scriptPath: path)]
            }
            // Backwards compatibility for previous library script-only refs.
            return action(remoteAction.scriptID)?.steps
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            if let file = try? JSONDecoder().decode(RemoteUnifiedLibraryFile.self, from: data),
               file.version == 2 {
                actions = file.actions
                error = nil
                return
            }
            let old = try JSONDecoder().decode(LegacyLibrary.self, from: data)
            guard old.version == 1 else { error = "动作库数据版本不支持"; return }
            let importedScripts = old.scripts.map { old in
                RemoteLibraryAction(
                    id: old.id, name: old.name,
                    steps: [RemoteActionStep(kind: .script,
                        scriptLanguage: old.language, scriptSource: old.source)],
                    modifiedAt: old.modifiedAt
                )
            }
            let importedPresets = old.presets.compactMap { old -> RemoteLibraryAction? in
                guard let steps = stepsForLegacy(old.action, scripts: importedScripts) else { return nil }
                return RemoteLibraryAction(id: old.id, name: old.name,
                                           steps: steps, modifiedAt: old.modifiedAt)
            }
            actions = importedScripts + importedPresets
            persist()
        } catch {
            self.error = "读取动作库失败：\(error.localizedDescription)"
        }
    }

    private func stepsForLegacy(_ action: RemoteAction,
                                scripts: [RemoteLibraryAction]) -> [RemoteActionStep]? {
        if action.kind == .script, let scriptID = action.scriptID {
            return scripts.first(where: { $0.id == scriptID })?.steps
        }
        return steps(for: action)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(RemoteUnifiedLibraryFile(actions: actions))
                .write(to: storageURL, options: .atomic)
            error = nil
        } catch {
            self.error = "保存动作库失败：\(error.localizedDescription)"
        }
    }

    /// Editable built-in action; users' customized copies are never overwritten.
    private func installStarterActions() {
        let starterID = Self.chatGPTPresetID
        guard !actions.contains(where: { $0.id == starterID }) else { return }
        let launcher = RemoteActionStep(kind: .openApp,
                                        applicationBundleID: "com.openai.chat",
                                        applicationName: "ChatGPT")
        let focusShortcut = RemoteShortcut(keyCode: 49, keyLabel: "Space",
                                           command: false, shift: false,
                                           option: true, control: false)
        actions.append(RemoteLibraryAction(
            id: starterID, name: "ChatGPT · 打开并聚焦输入栏",
            steps: [launcher,
                    RemoteActionStep(kind: .wait, waitSeconds: 0.5),
                    RemoteActionStep(kind: .keyboard, shortcut: focusShortcut,
                                     holdSeconds: 0.08)]
        ))
        persist()
    }
}
