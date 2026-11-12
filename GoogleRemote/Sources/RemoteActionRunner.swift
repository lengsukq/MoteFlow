import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

enum RemoteExecutionError: LocalizedError {
    case nothingConfigured
    case missingKey
    case missingScript
    case invalidScript
    case accessibilityDenied
    case cannotCreateKeyboardEvent
    case scriptExit(Int32)
    case scriptTimedOut
    case missingLibraryAction
    case appNotInstalled(String)
    case appLaunchFailed(String)
    case systemActionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .nothingConfigured: "尚未设置可执行的动作"
        case .missingKey: "尚未录制目标按键"
        case .missingScript: "尚未选择本地脚本"
        case .invalidScript: "脚本文件已不存在，或不是支持的 .sh / .zsh / .command / .py 文件"
        case .accessibilityDenied: "macOS 未授权「辅助功能」，无法模拟键盘输入。已发起系统授权请求。"
        case .cannotCreateKeyboardEvent: "无法生成 macOS 键盘事件"
        case .scriptExit(let status): "脚本结束，退出码 \(status)"
        case .scriptTimedOut: "脚本运行超过 20 秒，已请求终止"
        case .missingLibraryAction: "动作库条目已删除、没有步骤，或其内容无效"
        case .appNotInstalled(let name): "未找到应用：\(name)。请在动作库里重新选择已安装的 .app。"
        case .appLaunchFailed(let detail): "启动应用失败：\(detail)"
        case .systemActionUnavailable(let detail): "系统动作不可用：\(detail)"
        }
    }
}

@MainActor
private enum RemoteSystemActionExecutor {
    /// Screenshots are handled by macOS itself. No CGEvent shortcuts are
    /// generated, so the user may remap screenshot shortcuts freely.
    static func executeSystemAction(_ action: RemoteSystemAction) async throws {
        for (index, step) in action.executionSequence.enumerated() {
            try executeSingleAction(step)
            // Give the frontmost app a chance to apply Select All before Copy
            // or Paste, especially in web-based text editors.
            if index + 1 < action.executionSequence.count {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func executeSingleAction(_ action: RemoteSystemAction) throws {
        if let args = action.screenshotArguments {
            let command = URL(fileURLWithPath: "/usr/sbin/screencapture")
            guard FileManager.default.isExecutableFile(atPath: command.path) else {
                throw RemoteExecutionError.systemActionUnavailable("当前 macOS 未提供 screencapture")
            }
            let process = Process()
            process.executableURL = command
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            try process.run()
            return
        }
        try performFrontmostMenuAction(action)
    }

    /// There is no public cross-application Copy/Paste command. Query the
    /// frontmost app's accessible Edit menu *without opening it* and directly
    /// invoke the matching menu item. Never AXPress the parent menu-bar item:
    /// doing so visibly drops down the menu on every remote click.
    /// Unsupported menu trees fail without flashing a menu or guessing keys.
    private static func performFrontmostMenuAction(_ action: RemoteSystemAction) throws {
        guard action.usesAccessibilityMenu,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw RemoteExecutionError.systemActionUnavailable(
                "先切换到需要操作的应用；不能在 MoteFlow 配置窗口中调用其他应用的编辑菜单"
            )
        }
        guard AXIsProcessTrusted() else {
            throw RemoteExecutionError.systemActionUnavailable(
                "请在「系统设置 → 隐私与安全性 → 辅助功能」授权 MoteFlow"
            )
        }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2.0)
        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let barValue else {
            throw RemoteExecutionError.systemActionUnavailable("当前应用没有可访问的菜单栏")
        }
        let menuBar = barValue as! AXUIElement
        let editTitles = ["Edit", "编辑"]
        guard let edit = Self.axChildren(menuBar).first(where: {
            editTitles.contains(Self.axTitle($0))
        }) else {
            throw RemoteExecutionError.systemActionUnavailable("当前应用未提供可访问的「编辑」菜单")
        }
        // A closed menu's children are generally exposed through AX even when
        // the menu is not on screen. Opening the "Edit" menu here would cause
        // an ugly visual flash for every Copy/Paste or composite long-press.
        let children = Self.axChildren(edit).flatMap { Self.axChildren($0) }
        let direct = Self.axChildren(edit)
        let items = children.isEmpty ? direct : children
        guard let item = items.first(where: { candidate in
            let title = Self.axTitle(candidate)
            return action.menuTitles.contains { label in
                title == label ||
                ((action == .undo || action == .redo) && title.hasPrefix(label + " "))
            }
        }) else {
            throw RemoteExecutionError.systemActionUnavailable(
                "无法静默读取当前应用的「\(action.title)」菜单命令；该应用可能不支持在菜单关闭时读取"
            )
        }
        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           let enabled = enabledValue as? Bool, !enabled {
            throw RemoteExecutionError.systemActionUnavailable("当前应用的「\(action.title)」暂不可用")
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw RemoteExecutionError.systemActionUnavailable(
                "当前应用拒绝执行「\(action.title)」菜单命令"
            )
        }
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXTitleAttribute as CFString, &value
        ) == .success else { return "" }
        return (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Executes only after explicit user confirmation. Real remote dispatch
/// remains disabled until the HID press/release protocol is actually verified.
@MainActor
final class RemoteActionRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var result = "尚未试运行"
    @Published private(set) var voiceShortcutHeld = false
    var onSwitchMacTarget: (() -> Void)?
    private var voiceKeyUp: CGEvent?
    private var heldVoiceShortcut: RemoteShortcut?
    private var mappedHold: (id: UUID, key: RemoteKey, shortcut: RemoteShortcut, keyUp: CGEvent)?
    private var mappedHoldWatchdog: Task<Void, Never>?
    private var mappedRepeatTask: Task<Void, Never>?
    private var pendingMappedActions: [(action: RemoteAction, label: String, library: RemoteLibraryStore, inlineSteps: [RemoteActionStep]?)] = []

    private static func flags(for shortcut: RemoteShortcut) -> CGEventFlags {
        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.shift { flags.insert(.maskShift) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }
        return flags
    }

    /// A standalone Command/Option/Control/Shift must be emitted as a
    /// flagsChanged transition; keyDown on virtual key 55 is not a genuine
    /// left-Command press as far as many global-hotkey listeners are concerned.
    private static func configureMainKeyEvents(
        _ down: CGEvent, _ up: CGEvent, shortcut: RemoteShortcut
    ) {
        if shortcut.isModifierOnly {
            down.type = .flagsChanged
            up.type = .flagsChanged
            down.flags = flagsForPhysicalModifierCodes([shortcut.keyCode])
            up.flags = []
        } else {
            let flags = flags(for: shortcut)
            down.flags = flags
            up.flags = flags
        }
    }

    private static func flagsForPhysicalModifierCodes(_ codes: Set<UInt16>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for code in codes {
            guard let modifier = RemoteModifier.location(of: code)?.modifier else { continue }
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        return flags
    }

    /// Physical modifier events are necessary: setting .maskAlternate alone
    /// does not identify left vs right Option for system-wide hotkeys.
    private static func postPhysicalModifiers(_ shortcut: RemoteShortcut, pressing: Bool) {
        let codes = shortcut.pressedModifierKeyCodes
        var down: Set<UInt16> = pressing ? [] : Set(codes)
        for code in pressing ? codes : Array(codes.reversed()) {
            if pressing { down.insert(code) }
            else { down.remove(code) }
            guard let event = CGEvent(
                keyboardEventSource: nil, virtualKey: code, keyDown: pressing
            ) else { continue }
            event.type = .flagsChanged
            event.flags = flagsForPhysicalModifierCodes(down)
            event.post(tap: .cghidEventTap)
        }
    }

    private func launchApplication(_ step: RemoteActionStep) async throws {
        guard let bundleID = step.applicationBundleID else {
            throw RemoteExecutionError.appNotInstalled(step.applicationName ?? "未选择")
        }
        let workspace = NSWorkspace.shared
        var target = workspace.urlForApplication(withBundleIdentifier: bundleID)
        if bundleID == "com.openai.chat",
           let unified = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex"),
           unified.lastPathComponent.lowercased() == "chatgpt.app" {
            target = unified
        }
        guard let target else {
            throw RemoteExecutionError.appNotInstalled(step.applicationName ?? bundleID)
        }
        let running = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            workspace.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: RemoteExecutionError.appLaunchFailed("系统没有返回进程")) }
            }
        }
        _ = running.activate()
    }

    /// Doubao's configurable hold-to-dictate hotkey. This controls Doubao
    /// reading its OWN selected macOS microphone; it does not route ATVV PCM.
    func beginVoiceShortcutHold(_ shortcut: RemoteShortcut) {
        guard !voiceShortcutHeld && !running && mappedHold == nil else { return }
        guard CGPreflightPostEventAccess() else {
            result = "无法按住豆包快捷键：请先授予辅助功能权限。"
            return
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false)
        else {
            result = "无法生成豆包输入法快捷键事件"
            return
        }
        Self.configureMainKeyEvents(down, up, shortcut: shortcut)
        voiceKeyUp = up
        heldVoiceShortcut = shortcut
        voiceShortcutHeld = true
        result = "正在按住豆包快捷键 \(shortcut.display)；将随 ATVV 会话结束释放，而非固定秒数"
        Self.postPhysicalModifiers(shortcut, pressing: true)
        down.post(tap: .cghidEventTap)
    }

    func endVoiceShortcutHold() {
        guard voiceShortcutHeld else { return }
        voiceKeyUp?.post(tap: .cghidEventTap)
        if let heldVoiceShortcut {
            Self.postPhysicalModifiers(heldVoiceShortcut, pressing: false)
        }
        voiceKeyUp = nil
        heldVoiceShortcut = nil
        voiceShortcutHeld = false
        result = "豆包快捷键已释放；等待豆包完成听写并输入到当前文本框"
    }

    /// This is an actual key-down/key-up pair, not a timer-based key press.
    /// HID key-up (or capture shutdown) is responsible for releasing it.
    @discardableResult
    func beginMappedShortcutHold(_ shortcut: RemoteShortcut, for key: RemoteKey) -> Bool {
        guard mappedHold == nil, !running, !voiceShortcutHeld else {
            result = "已有按键动作执行中，无法开始新的实体长按"
            return false
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            result = "实时长按需要 macOS「辅助功能」权限"
            return false
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false)
        else {
            result = "无法生成实时长按的键盘事件"
            return false
        }
        Self.configureMainKeyEvents(down, up, shortcut: shortcut)
        let holdID = UUID()
        mappedHold = (holdID, key, shortcut, up)
        Self.postPhysicalModifiers(shortcut, pressing: true)
        down.post(tap: .cghidEventTap)
        result = "实体「\(key.title)」正在按住 \(shortcut.display)，松开遥控器即释放"
        startMappedKeyRepeat(shortcut, for: holdID)
        // Failsafe only: if the remote never reports key-up, do not leave a
        // key logically down forever. Ordinary releases have no fixed duration.
        mappedHoldWatchdog?.cancel()
        mappedHoldWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.endMappedShortcutHold(for: key)
        }
        return true
    }

    func endMappedShortcutHold(for key: RemoteKey? = nil) {
        guard let held = mappedHold, key == nil || held.key == key else { return }
        // Cancel before keyUp so no repeat can be emitted after release.
        mappedRepeatTask?.cancel()
        mappedRepeatTask = nil
        mappedHoldWatchdog?.cancel()
        mappedHoldWatchdog = nil
        mappedHold = nil
        held.keyUp.post(tap: .cghidEventTap)
        Self.postPhysicalModifiers(held.shortcut, pressing: false)
        result = "已随实体「\(held.key.title)」松开而释放 \(held.shortcut.display)"
        drainMappedActions()
    }

    /// Synthetic CGEvent keyDown is not auto-repeated by macOS. Post explicit
    /// keyDown events marked as repeats, using the user's keyboard repeat
    /// preferences, until the physical remote sends key-up.
    private func startMappedKeyRepeat(_ shortcut: RemoteShortcut, for holdID: UUID) {
        mappedRepeatTask?.cancel()
        mappedRepeatTask = nil
        guard RemoteKeyRepeatPolicy.shouldRepeat(shortcut) else { return }
        let initialDelay = RemoteKeyRepeatPolicy.initialDelay()
        let interval = RemoteKeyRepeatPolicy.repeatInterval()
        mappedRepeatTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(initialDelay)) }
            catch { return }
            while !Task.isCancelled {
                guard let self, let held = self.mappedHold, held.id == holdID else { return }
                if let repeatedDown = CGEvent(
                    keyboardEventSource: nil, virtualKey: held.shortcut.keyCode, keyDown: true
                ) {
                    repeatedDown.flags = Self.flags(for: held.shortcut)
                    repeatedDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                    repeatedDown.post(tap: .cghidEventTap)
                }
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }

    /// HID releases can arrive much faster than the macOS key-up timer.
    /// Never discard a short tap because a previous mapped action is running.
    func enqueueMappedAction(_ action: RemoteAction, label: String, library: RemoteLibraryStore) {
        guard pendingMappedActions.count < 24 else {
            result = "连续按键过多，已限制待执行动作队列"
            return
        }
        pendingMappedActions.append((action, label, library, nil))
        drainMappedActions()
    }

    func enqueueForwardedSteps(_ steps: [RemoteActionStep], label: String, library: RemoteLibraryStore) {
        guard !steps.isEmpty, pendingMappedActions.count < 24 else { return }
        pendingMappedActions.append((RemoteAction(kind: .libraryAction), label, library, steps))
        drainMappedActions()
    }

    func cancelPendingMappedActions() {
        pendingMappedActions.removeAll()
    }

    private func drainMappedActions() {
        guard !running && !voiceShortcutHeld && mappedHold == nil,
              !pendingMappedActions.isEmpty else { return }
        let next = pendingMappedActions.removeFirst()
        test(action: next.action, label: next.label, library: next.library, inlineSteps: next.inlineSteps)
    }

    /// One short key down/up pair. No held state remains after the tap.
    func tapVoiceShortcut(_ shortcut: RemoteShortcut) {
        guard !running && !voiceShortcutHeld && mappedHold == nil else { return }
        Task {
            do {
                try await emitKeyboard(shortcut, holdSeconds: 0.08)
                result = "已单击豆包快捷键 \(shortcut.display)；录音是否开始由豆包的单击模式决定"
            } catch {
                result = "豆包快捷键单击失败：\(error.localizedDescription)"
            }
        }
    }

    /// Inserts offline-transcribed speech text at the current cursor when the
    /// receiving Mac does not have BlackHole 2ch installed, preserving clipboard text.
    func insertRecognizedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        let previousText = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(trimmed, forType: .string)

        guard AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
            result = "已识别语音并复制到剪贴板（授权辅助功能后可自动输入）：\(trimmed)"
            return
        }

        let pasteShortcut = RemoteShortcut(
            keyCode: 9, // 'V'
            keyLabel: "V",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        Task {
            do {
                try await emitKeyboard(pasteShortcut, holdSeconds: 0.06)
                result = "已自动输入远端语音识别文字：\(trimmed)"
                try? await Task.sleep(for: .milliseconds(320))
                if pb.string(forType: .string) == trimmed {
                    pb.clearContents()
                    if let previousText {
                        pb.setString(previousText, forType: .string)
                    }
                }
            } catch {
                result = "语音文字已复制到剪贴板，自动粘贴失败：\(error.localizedDescription)"
            }
        }
    }

    func test(action: RemoteAction, label: String, library: RemoteLibraryStore, inlineSteps: [RemoteActionStep]? = nil) {
        guard !running && !voiceShortcutHeld && mappedHold == nil else { return }
        running = true
        result = "正在执行：\(label)"

        Task {
            do {
                if action.kind == .voiceInput {
                    result = "语音动作尚需实体遥控器 ATVV 验证，未执行"
                } else if action.kind == .systemAction {
                    guard let native = action.systemAction else {
                        throw RemoteExecutionError.systemActionUnavailable("未选择系统动作")
                    }
                    if native == .switchMacTarget {
                        onSwitchMacTarget?()
                        result = "已触发双机控制目标切换"
                    } else {
                        try await RemoteSystemActionExecutor.executeSystemAction(native)
                        result = "已请求系统动作：\(native.title)"
                    }
                } else {
                    let resolvedSteps = inlineSteps ?? library.steps(for: action)
                    guard let steps = resolvedSteps, !steps.isEmpty
                    else { throw RemoteExecutionError.missingLibraryAction }
                    for (index, step) in steps.enumerated() {
                        switch step.kind {
                        case .keyboard:
                            guard let shortcut = step.shortcut else { throw RemoteExecutionError.missingKey }
                            try await emitKeyboard(shortcut, holdSeconds: min(10, max(0.04, step.holdSeconds)))
                        case .script:
                            try await runScript(step)
                        case .wait:
                            try await Task.sleep(nanoseconds: UInt64(min(30, max(0, step.waitSeconds)) * 1_000_000_000))
                        case .openApp:
                            try await launchApplication(step)
                        }
                        result = "已完成步骤 \(index + 1)/\(steps.count)：\(step.summary)"
                    }
                    result = "执行完成：\(label) · 共 \(steps.count) 个步骤"
                }
            } catch {
                result = "试运行失败：\(error.localizedDescription)"
            }
            running = false
            drainMappedActions()
        }
    }

    private func emitKeyboard(_ shortcut: RemoteShortcut, holdSeconds: Double) async throws {
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            throw RemoteExecutionError.accessibilityDenied
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false)
        else { throw RemoteExecutionError.cannotCreateKeyboardEvent }

        Self.configureMainKeyEvents(down, up, shortcut: shortcut)
        Self.postPhysicalModifiers(shortcut, pressing: true)
        down.post(tap: .cghidEventTap)
        // Always release both main key and physical modifiers on cancellation.
        defer {
            up.post(tap: .cghidEventTap)
            Self.postPhysicalModifiers(shortcut, pressing: false)
        }
        try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
    }

    private func runScript(_ step: RemoteActionStep) async throws {
        let path: String
        var temporary: URL?
        if let externalPath = step.scriptPath {
            guard FileManager.default.fileExists(atPath: externalPath) else {
                throw RemoteExecutionError.invalidScript
            }
            path = externalPath
        } else {
            guard !step.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  step.scriptSource.utf8.count <= 200_000
            else { throw RemoteExecutionError.invalidScript }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("google-remote-\(UUID().uuidString).\(step.scriptLanguage.fileExtension)")
            try step.scriptSource.write(to: file, atomically: true, encoding: .utf8)
            temporary = file
            path = file.path
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let url = URL(fileURLWithPath: path)
        let language: RemoteScriptLanguage
        if step.scriptPath != nil {
            switch url.pathExtension.lowercased() {
            case "sh": language = .bash
            case "zsh", "command": language = .zsh
            case "py": language = .python
            default: throw RemoteExecutionError.invalidScript
            }
        } else {
            language = step.scriptLanguage
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: language.executable)
        // Script path is a single argv value; never interpolate it into a shell command.
        process.arguments = [path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled && process.isRunning { process.terminate() }
        }
        let exitCode = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        watchdog.cancel()
        if process.terminationReason == .uncaughtSignal && exitCode == SIGTERM {
            throw RemoteExecutionError.scriptTimedOut
        }
        if exitCode != 0 { throw RemoteExecutionError.scriptExit(exitCode) }
    }
}
