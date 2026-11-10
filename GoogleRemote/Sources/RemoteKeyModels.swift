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
        case .volumeUp: "音量增加"
        case .volumeDown: "音量减小"
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
    case script
    case libraryAction
    case voiceInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不执行动作"
        case .keyboardShortcut: "按键 / 组合快捷键"
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
                            scriptPath: scriptPath, scriptID: scriptID,
                            presetID: presetID, outputHoldSeconds: outputHoldSeconds,
                            outputHoldMode: outputHoldMode)
    }

    mutating func setAction(_ action: RemoteAction, for gesture: RemoteGesture) {
        if gesture == .tap {
            kind = action.kind
            shortcut = action.shortcut
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
