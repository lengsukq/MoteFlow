import Foundation

/// How to deliver a configured Doubao shortcut, not how long the physical
/// remote voice button must be pressed. The choice is stored independently.
enum DoubaoShortcutTrigger: String, CaseIterable, Codable, Identifiable {
    case tap
    case hold

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tap: "单击触发"
        case .hold: "按住触发"
        }
    }

    var detail: String {
        switch self {
        case .tap: "语音会话开始时只单击一次快捷键；会话结束时不再发键。适合豆包的单击启动模式。"
        case .hold: "语音会话开始时按下快捷键，ATVV 结束时释放。适合豆包的按住说话模式。"
        }
    }
}

/// Public macOS facilities and Accessibility menu commands, independent of
/// user-customized key equivalents. Raw identifiers remain stable in JSON.
enum RemoteSystemAction: String, Codable, CaseIterable, Identifiable {
    case screenshotArea
    case screenshotFull
    case screenshotToolbar
    case screenshotAreaClipboard
    case screenshotFullClipboard
    case copy
    case paste
    case cut
    case selectAll
    case selectAllAndCopy
    case selectAllAndPaste
    case undo
    case redo
    case switchMacTarget

    var id: String { rawValue }
    /// Composite actions are executed sequentially, never repeated on hold.
    var executionSequence: [RemoteSystemAction] {
        switch self {
        case .selectAllAndCopy: [.selectAll, .copy]
        case .selectAllAndPaste: [.selectAll, .paste]
        default: [self]
        }
    }
    var title: String {
        switch self {
        case .screenshotArea: "区域截图"
        case .screenshotFull: "全屏截图"
        case .screenshotToolbar: "截图与录屏工具栏"
        case .screenshotAreaClipboard: "区域截图到剪贴板"
        case .screenshotFullClipboard: "全屏截图到剪贴板"
        case .copy: "复制"
        case .paste: "粘贴"
        case .cut: "剪切"
        case .selectAll: "全选"
        case .selectAllAndCopy: "全选后复制"
        case .selectAllAndPaste: "全选后粘贴"
        case .undo: "撤销"
        case .redo: "重做"
        case .switchMacTarget: "切换双机目标（本机 ⇄ 另一台 Mac）"
        }
    }

    var usesAccessibilityMenu: Bool {
        switch self {
        case .copy, .paste, .cut, .selectAll, .selectAllAndCopy,
             .selectAllAndPaste, .undo, .redo: true
        default: false
        }
    }

    var menuTitles: [String] {
        switch self {
        case .copy: ["Copy", "复制", "拷贝"]
        case .paste: ["Paste", "粘贴"]
        case .cut: ["Cut", "剪切"]
        case .selectAll: ["Select All", "全选", "全部选择"]
        case .selectAllAndCopy, .selectAllAndPaste: []
        case .undo: ["Undo", "撤销"]
        case .redo: ["Redo", "重做", "恢复"]
        default: []
        }
    }

    /// The system screenshot tool supports these flags without shortcut remaps.
    var screenshotArguments: [String]? {
        switch self {
        case .screenshotArea: ["-i", "-s", "-p"]
        case .screenshotFull: ["-p"]
        case .screenshotToolbar: ["-i", "-U", "-p"]
        case .screenshotAreaClipboard: ["-i", "-s", "-c"]
        case .screenshotFullClipboard: ["-c"]
        default: nil
        }
    }
}

/// Local catalog of standard macOS keyboard shortcuts. Choosing an entry
/// creates a normal editable RemoteShortcut; it never executes an action.
enum MacShortcutCategory: String, CaseIterable, Identifiable {
    case screenshot
    case clipboard
    case editing
    case windows
    case system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .screenshot: "截图与录屏"
        case .clipboard: "剪贴板"
        case .editing: "文本与编辑"
        case .windows: "窗口与 App"
        case .system: "系统功能"
        }
    }
    var symbol: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .editing: "text.cursor"
        case .windows: "macwindow.on.rectangle"
        case .system: "desktopcomputer"
        }
    }
}

struct MacShortcutPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let category: MacShortcutCategory
    let shortcut: RemoteShortcut

    /// Native actions are identified by intent, not by key combinations.
    /// Remaining catalog entries still behave like editable shortcuts.
    var nativeAction: RemoteSystemAction? {
        switch id {
        case "screenshot.area": .screenshotArea
        case "screenshot.full": .screenshotFull
        case "screenshot.toolbar": .screenshotToolbar
        case "screenshot.area.clipboard": .screenshotAreaClipboard
        case "screenshot.full.clipboard": .screenshotFullClipboard
        case "clipboard.copy": .copy
        case "clipboard.paste": .paste
        case "clipboard.cut": .cut
        case "editing.undo": .undo
        case "editing.redo": .redo
        case "editing.selectall": .selectAll
        default: nil
        }
    }

    private static func preset(_ id: String, _ title: String, _ detail: String,
                               _ symbol: String, _ category: MacShortcutCategory,
                               _ keyCode: UInt16, _ label: String,
                               command: Bool = false, shift: Bool = false,
                               option: Bool = false, control: Bool = false) -> Self {
        .init(id: id, title: title, detail: detail, symbol: symbol, category: category,
              shortcut: RemoteShortcut(keyCode: keyCode, keyLabel: label,
                                       command: command, shift: shift,
                                       option: option, control: control))
    }

    static let all: [Self] = [
        preset("screenshot.area", "区域截图", "框选屏幕的一部分", "camera.viewfinder", .screenshot,
               21, "4", command: true, shift: true),
        preset("screenshot.full", "全屏截图", "捕捉整个屏幕", "display", .screenshot,
               20, "3", command: true, shift: true),
        preset("screenshot.toolbar", "截屏与录屏工具", "打开系统截屏工具栏", "record.circle", .screenshot,
               23, "5", command: true, shift: true),
        preset("screenshot.area.clipboard", "区域截图到剪贴板", "框选后复制到剪贴板", "square.on.square.dashed", .screenshot,
               21, "4", command: true, shift: true, control: true),
        preset("screenshot.full.clipboard", "全屏截图到剪贴板", "将全屏截图复制到剪贴板", "doc.on.clipboard", .screenshot,
               20, "3", command: true, shift: true, control: true),

        preset("clipboard.copy", "复制", "复制选中内容", "doc.on.doc", .clipboard,
               8, "C", command: true),
        preset("clipboard.paste", "粘贴", "粘贴剪贴板内容", "doc.on.clipboard", .clipboard,
               9, "V", command: true),
        preset("clipboard.cut", "剪切", "剪切选中内容", "scissors", .clipboard,
               7, "X", command: true),

        preset("editing.selectall", "全选", "选中当前所有内容", "selection.pin.in.out", .editing,
               0, "A", command: true),
        preset("editing.undo", "撤销", "撤销上一步操作", "arrow.uturn.backward", .editing,
               6, "Z", command: true),
        preset("editing.redo", "重做", "恢复已撤销的操作", "arrow.uturn.forward", .editing,
               6, "Z", command: true, shift: true),
        preset("editing.find", "查找", "查找当前窗口中的内容", "magnifyingglass", .editing,
               3, "F", command: true),
        preset("editing.save", "保存", "保存当前文稿", "square.and.arrow.down", .editing,
               1, "S", command: true),

        preset("windows.new", "新建窗口", "在支持的 App 中新建窗口", "macwindow.badge.plus", .windows,
               45, "N", command: true),
        preset("windows.tab", "新建标签页", "在支持的 App 中新建标签", "plus.rectangle.on.rectangle", .windows,
               17, "T", command: true),
        preset("windows.close", "关闭窗口 / 标签页", "关闭当前窗口或标签页", "xmark.square", .windows,
               13, "W", command: true),
        preset("windows.minimize", "最小化窗口", "将当前窗口最小化", "minus.square", .windows,
               46, "M", command: true),
        preset("windows.hide", "隐藏当前 App", "隐藏当前应用窗口", "eye.slash", .windows,
               4, "H", command: true),
        preset("windows.switch", "切换 App", "切换到上一个使用的 App", "square.on.square", .windows,
               48, "Tab", command: true),

        preset("system.spotlight", "聚焦搜索", "打开 macOS 聚焦", "magnifyingglass.circle", .system,
               49, "Space", command: true),
        preset("system.lock", "锁定屏幕", "锁定当前 Mac", "lock.display", .system,
               12, "Q", command: true, control: true),
        preset("system.quicklook", "快速查看", "Finder 中预览选中的文件", "eye", .system,
               49, "Space")
    ]

    static let popularIDs = [
        "screenshot.area", "screenshot.full", "clipboard.copy",
        "clipboard.paste", "editing.undo", "editing.selectall"
    ]

    static var popular: [Self] {
        popularIDs.compactMap { id in all.first(where: { $0.id == id }) }
    }
}

/// CGEvent keyDown alone does not produce hardware keyboard autorepeat.
/// Repeat plain editing/navigation keys while held, but never automatically
/// re-trigger potentially destructive Command/Option/Control shortcuts.
enum RemoteKeyRepeatPolicy {
    static func shouldRepeat(_ shortcut: RemoteShortcut) -> Bool {
        !shortcut.isModifierOnly && !shortcut.command && !shortcut.option && !shortcut.control
    }

    /// macOS stores keyboard repeat preferences as 60 Hz ticks.
    /// Fallback values apply when the user has not customized these settings.
    static func initialDelay(defaults: UserDefaults = .standard) -> Double {
        guard let ticks = defaults.object(forKey: "InitialKeyRepeat") as? NSNumber else { return 0.40 }
        return min(1.5, max(0.15, ticks.doubleValue / 60))
    }

    static func repeatInterval(defaults: UserDefaults = .standard) -> Double {
        guard let ticks = defaults.object(forKey: "KeyRepeat") as? NSNumber else { return 0.055 }
        return min(0.30, max(0.025, ticks.doubleValue / 60))
    }
}

/// The physical button inventory of the original Chromecast Voice Remote (G9N9N).
/// Buttons are kept distinct from HID usages, which still require hardware verification.
enum RemoteKey: String, CaseIterable, Codable, Identifiable {
    case up, down, left, right, select
    case back, assistant, home, mute
    case youtube, netflix, power, input, menu, tv
    case volumeUp, volumeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: "方向上"
        case .down: "方向下"
        case .left: "方向左"
        case .right: "方向右"
        case .select: "确认 / OK"
        case .back: "返回"
        case .assistant: "语音助手"
        case .home: "主页"
        case .mute: "静音"
        case .youtube: "YouTube"
        case .netflix: "Netflix"
        case .power: "电源"
        case .input: "输入源"
        case .menu: "菜单"
        case .tv: "TV / 自定义"
        case .volumeUp: "上侧键 / 音量+"
        case .volumeDown: "下侧键 / 音量−"
        }
    }

    var symbol: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .select: "circle.inset.filled"
        case .back: "arrow.uturn.backward"
        case .assistant: "mic.fill"
        case .home: "house.fill"
        case .mute: "speaker.slash.fill"
        case .youtube: "play.rectangle.fill"
        case .netflix: "play.fill"
        case .power: "power"
        case .input: "rectangle.on.rectangle"
        case .menu: "line.3.horizontal"
        case .tv: "tv"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        }
    }

    var location: String {
        switch self {
        case .up, .down, .left, .right, .select: "方向控制"
        case .volumeUp, .volumeDown: "侧面音量"
        case .back, .assistant, .home, .mute: "功能控制"
        case .youtube, .netflix: "应用快捷键"
        case .power, .input, .tv: "电视控制"
        case .menu: "功能控制"
        }
    }
}

/// Pure recognizer for future HID key-down/key-up dispatch; maps a key's
/// physical duration to one of the two independently configured actions.
struct RemotePressClassifier {
    static func gesture(duration: TimeInterval, threshold: Double) -> RemoteGesture {
        duration >= min(5, max(0.2, threshold)) ? .longPress : .tap
    }
}

/// The physical location of modifier keys matters to some macOS hotkeys.
/// Nil on a stored shortcut means an older profile with an unspecified side.
enum RemoteModifierSide: String, Codable, Hashable, CaseIterable, Identifiable {
    case left
    case right
    case both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "左侧"
        case .right: "右侧"
        case .both: "左右同时"
        }
    }
}

enum RemoteModifier: String, CaseIterable, Codable {
    case command, shift, option, control

    var leftKeyCode: UInt16 {
        switch self {
        case .command: 55
        case .shift: 56
        case .option: 58
        case .control: 59
        }
    }

    var rightKeyCode: UInt16 {
        switch self {
        case .command: 54
        case .shift: 60
        case .option: 61
        case .control: 62
        }
    }

    static func location(of keyCode: UInt16) -> (modifier: RemoteModifier, side: RemoteModifierSide)? {
        for modifier in allCases {
            if modifier.leftKeyCode == keyCode { return (modifier, .left) }
            if modifier.rightKeyCode == keyCode { return (modifier, .right) }
        }
        return nil
    }

    func keyCodes(for side: RemoteModifierSide?) -> [UInt16] {
        switch side ?? .left {
        case .left: [leftKeyCode]
        case .right: [rightKeyCode]
        case .both: [leftKeyCode, rightKeyCode]
        }
    }
}

/// A lone physical modifier becomes a shortcut when it is released.
/// When another modifier or ordinary key joins, it is a combination instead.
struct RemoteModifierCaptureState {
    private(set) var heldCodes: Set<UInt16> = []
    private var loneCandidate: UInt16?

    mutating func flagsChanged(keyCode: UInt16) -> UInt16? {
        guard RemoteModifier.location(of: keyCode) != nil else { return nil }
        if heldCodes.contains(keyCode) {
            heldCodes.remove(keyCode)
            if heldCodes.isEmpty && loneCandidate == keyCode {
                loneCandidate = nil
                return keyCode
            }
        } else {
            heldCodes.insert(keyCode)
            loneCandidate = heldCodes.count == 1 ? keyCode : nil
        }
        return nil
    }

    mutating func ordinaryKeyPressed() {
        loneCandidate = nil
    }
}

/// Persist meaningful modifier states including right-versus-left variants,
/// not NSEvent's device-independent bitmask alone.
struct RemoteShortcut: Codable, Hashable {
    var keyCode: UInt16
    var keyLabel: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var commandSide: RemoteModifierSide? = nil
    var shiftSide: RemoteModifierSide? = nil
    var optionSide: RemoteModifierSide? = nil
    var controlSide: RemoteModifierSide? = nil

    var hasModifier: Bool { command || shift || option || control }

    /// A modifier may be the ONLY key (e.g. left Command for Doubao).
    /// Keep its physical key code instead of inventing a Space main key.
    var standaloneModifier: (modifier: RemoteModifier, side: RemoteModifierSide)? {
        guard !hasModifier else { return nil }
        return RemoteModifier.location(of: keyCode)
    }

    var isModifierOnly: Bool { standaloneModifier != nil }

    var display: String {
        if let standaloneModifier {
            let symbol: String
            switch standaloneModifier.modifier {
            case .command: symbol = "⌘"
            case .shift: symbol = "⇧"
            case .option: symbol = "⌥"
            case .control: symbol = "⌃"
            }
            return symbol + (standaloneModifier.side == .left ? "左" : "右")
        }
        return (command ? Self.modifierLabel("⌘", side: commandSide) : "") +
        (shift ? Self.modifierLabel("⇧", side: shiftSide) : "") +
        (option ? Self.modifierLabel("⌥", side: optionSide) : "") +
        (control ? Self.modifierLabel("⌃", side: controlSide) : "") +
        keyLabel
    }

    private static func modifierLabel(_ symbol: String, side: RemoteModifierSide?) -> String {
        switch side {
        case .none: symbol
        case .left: symbol + "左"
        case .right: symbol + "右"
        case .both: symbol + "双"
        }
    }

    /// Explicit physical modifier key codes for CGEvent synthesis.
    /// Legacy shortcuts with no side use the macOS left-hand default.
    var pressedModifierKeyCodes: [UInt16] {
        var result: [UInt16] = []
        if command { result += RemoteModifier.command.keyCodes(for: commandSide) }
        if shift { result += RemoteModifier.shift.keyCodes(for: shiftSide) }
        if option { result += RemoteModifier.option.keyCodes(for: optionSide) }
        if control { result += RemoteModifier.control.keyCodes(for: controlSide) }
        return result
    }

    func withPhysicalModifierKeys(_ heldKeys: Set<UInt16>) -> RemoteShortcut {
        var updated = self
        func side(for modifier: RemoteModifier) -> RemoteModifierSide? {
            let left = heldKeys.contains(modifier.leftKeyCode)
            let right = heldKeys.contains(modifier.rightKeyCode)
            if left && right { return .both }
            if right { return .right }
            if left { return .left }
            return nil
        }
        if command { updated.commandSide = side(for: .command) }
        if shift { updated.shiftSide = side(for: .shift) }
        if option { updated.optionSide = side(for: .option) }
        if control { updated.controlSide = side(for: .control) }
        return updated
    }

    /// Key codes + modifiers uniquely identify shortcuts across differing keyboard layouts.
    static func == (lhs: RemoteShortcut, rhs: RemoteShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode &&
        lhs.command == rhs.command && lhs.shift == rhs.shift &&
        lhs.option == rhs.option && lhs.control == rhs.control &&
        lhs.commandSide == rhs.commandSide && lhs.shiftSide == rhs.shiftSide &&
        lhs.optionSide == rhs.optionSide && lhs.controlSide == rhs.controlSide
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(command)
        hasher.combine(shift)
        hasher.combine(option)
        hasher.combine(control)
        hasher.combine(commandSide)
        hasher.combine(shiftSide)
        hasher.combine(optionSide)
        hasher.combine(controlSide)
    }
}

enum RemoteBindingKind: String, Codable, CaseIterable, Identifiable {
    case none
    case keyboardShortcut
    case systemAction
    case script
    case libraryAction
    case voiceInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不执行动作"
        case .keyboardShortcut: "按键 / 组合快捷键"
        case .systemAction: "macOS 原生系统动作"
        case .script: "执行本地脚本"
        case .libraryAction: "引用动作库"
        case .voiceInput: "遥控器语音输入（待接入）"
        }
    }
}

enum RemoteGesture: String, CaseIterable, Codable, Identifiable {
    case tap
    case longPress

    var id: String { rawValue }
    var title: String { self == .tap ? "单击" : "长按" }
}

enum RemoteOutputHoldMode: String, Codable, CaseIterable, Identifiable {
    case timed
    case physical

    var id: String { rawValue }
    var title: String { self == .timed ? "固定时长" : "跟随实体按住" }
}

struct RemoteAction: Codable, Equatable {
    var kind: RemoteBindingKind = .none
    var shortcut: RemoteShortcut?
    var systemAction: RemoteSystemAction?
    /// An explicitly selected local script file. Do not resolve untrusted remote content here.
    var scriptPath: String?
    var scriptID: UUID?
    var presetID: UUID?
    /// How long to hold the target keyboard key down (seconds).
    /// Nil preserves legacy profiles' short keystroke behavior.
    var outputHoldSeconds: Double?
    /// Nil keeps existing saved actions in fixed-duration mode.
    var outputHoldMode: RemoteOutputHoldMode?

    var effectiveHoldMode: RemoteOutputHoldMode { outputHoldMode ?? .timed }

    var effectiveHoldSeconds: Double {
        min(10, max(0.04, outputHoldSeconds ?? 0.08))
    }

    var summary: String {
        switch kind {
        case .none: return "未配置"
        case .keyboardShortcut:
            guard let shortcut else { return "等待录制" }
            if effectiveHoldMode == .physical { return "\(shortcut.display) · 跟随实体按住" }
            return effectiveHoldSeconds > 0.15
                ? "\(shortcut.display) · 按住 \(String(format: "%.2f", effectiveHoldSeconds)) 秒"
                : shortcut.display
        case .systemAction:
            return systemAction.map { "\($0.title) · 系统调用" } ?? "选择系统动作"
        case .script:
            return scriptPath.map { URL(fileURLWithPath: $0).lastPathComponent } ??
                   (scriptID != nil ? "脚本库 · 已关联" : "等待选择脚本")
        case .libraryAction: return "动作库 · 已关联"
        case .voiceInput: return "语音输入 · 待接入"
        }
    }
}

struct RemoteBinding: Codable, Equatable {
    /// Tap action fields retained to decode users' saved v1 mappings without migration loss.
    var kind: RemoteBindingKind = .none
    var shortcut: RemoteShortcut?
    var systemAction: RemoteSystemAction?
    var scriptPath: String?
    var scriptID: UUID?
    var presetID: UUID?
    var outputHoldSeconds: Double?
    var outputHoldMode: RemoteOutputHoldMode?
    var longPressAction: RemoteAction?
    /// Duration the *physical* remote key must remain depressed to count as a long press.
    var longPressThreshold: Double?

    var effectiveThreshold: Double {
        min(5, max(0.2, longPressThreshold ?? 0.65))
    }

    func action(for gesture: RemoteGesture) -> RemoteAction {
        if gesture == .longPress { return longPressAction ?? RemoteAction() }
        return RemoteAction(kind: kind, shortcut: shortcut,
                            systemAction: systemAction,
                            scriptPath: scriptPath, scriptID: scriptID,
                            presetID: presetID, outputHoldSeconds: outputHoldSeconds,
                            outputHoldMode: outputHoldMode)
    }

    mutating func setAction(_ action: RemoteAction, for gesture: RemoteGesture) {
        if gesture == .tap {
            kind = action.kind
            shortcut = action.shortcut
            systemAction = action.systemAction
            scriptPath = action.scriptPath
            scriptID = action.scriptID
            presetID = action.presetID
            outputHoldSeconds = action.outputHoldSeconds
            outputHoldMode = action.outputHoldMode
        } else {
            longPressAction = action
        }
    }

    var isConfigured: Bool {
        kind != .none || (longPressAction?.kind ?? .none) != .none
    }

    var summary: String {
        let tap = action(for: .tap).summary
        let long = action(for: .longPress)
        if long.kind == .none { return tap }
        return kind == .none ? "长按：\(long.summary)" : "\(tap) / 长按：\(long.summary)"
    }
}

struct RemoteProfile: Codable {
    var version: Int = 1
    var bindings: [RemoteKey: RemoteBinding] = [:]
}
