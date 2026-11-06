import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// A short-lived intercepting event tap is active ONLY while the recording
/// sheet is visible. The matching keyDown is consumed before it reaches
/// competing app hotkeys (e.g. Doubao). Manual entry works without the tap.
@MainActor
private final class ShortcutGlobalCapture: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var feedback = ""
    var onRecorded: ((RemoteShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var modifierState = RemoteModifierCaptureState()
    private var captured = false

    func start() {
        stop()
        modifierState = RemoteModifierCaptureState()
        captured = false
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                   (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ShortcutGlobalCapture>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.feedback = "系统暂停了按键拦截，请重试或使用手动设置。"
                        owner.stop()
                        return Unmanaged.passUnretained(event)
                    }
                    if type == .flagsChanged {
                        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                        if RemoteModifier.location(of: code) != nil {
                            if let loneCode = owner.modifierState.flagsChanged(keyCode: code),
                               !owner.captured {
                                owner.captured = true
                                owner.onRecorded?(ShortcutKeyCatalog.makeShortcut(
                                    keyCode: loneCode, command: false, shift: false,
                                    option: false, control: false
                                ))
                            }
                            // Suppress the entire modifier gesture while recording.
                            // Otherwise Doubao may trigger before the key is saved.
                            return nil
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    guard type == .keyDown, !owner.captured else {
                        return Unmanaged.passUnretained(event)
                    }
                    owner.captured = true
                    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags
                    let held = owner.modifierState.heldCodes
                    owner.modifierState.ordinaryKeyPressed()
                    if code == 53 {
                        owner.onCancel?()
                    } else {
                        owner.onRecorded?(ShortcutKeyCatalog.makeShortcut(
                            keyCode: code,
                            command: flags.contains(.maskCommand) || held.contains(55) || held.contains(54),
                            shift: flags.contains(.maskShift) || held.contains(56) || held.contains(60),
                            option: flags.contains(.maskAlternate) || held.contains(58) || held.contains(61),
                            control: flags.contains(.maskControl) || held.contains(59) || held.contains(62)
                        ).withPhysicalModifierKeys(held))
                    }
                    // Consume only the captured keyDown. The tap is removed
                    // when the recording sheet dismisses; all other input passes.
                    return nil
                }
            }, userInfo: pointer
        ) else {
            feedback = "系统级录制不可用（可能缺少输入监控或辅助功能权限）。请使用「手动设置」。"
            return
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = runLoopSource
        running = true
        feedback = "正在拦截下一次快捷键；录制期间不会将该键转交给豆包。"
    }

    func stop() {
        running = false
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        modifierState = RemoteModifierCaptureState()
    }

    deinit {
        // The recording sheet always calls stop on disappear. Do not retain
        // this object after the event tap's userInfo pointer becomes invalid.
    }
}

private struct ShortcutKeyOption: Identifiable {
    let label: String
    let keyCode: UInt16
    var id: UInt16 { keyCode }
}

private enum ShortcutKeyCatalog {
    static let keys: [ShortcutKeyOption] = [
        .init(label: "⌘ 左 Command（单键）", keyCode: 55),
        .init(label: "⌘ 右 Command（单键）", keyCode: 54),
        .init(label: "⌥ 左 Option（单键）", keyCode: 58),
        .init(label: "⌥ 右 Option（单键）", keyCode: 61),
        .init(label: "⌃ 左 Control（单键）", keyCode: 59),
        .init(label: "⌃ 右 Control（单键）", keyCode: 62),
        .init(label: "⇧ 左 Shift（单键）", keyCode: 56),
        .init(label: "⇧ 右 Shift（单键）", keyCode: 60),
        .init(label: "Space", keyCode: 49), .init(label: "↩ Return", keyCode: 36),
        .init(label: "⇥ Tab", keyCode: 48), .init(label: "Esc", keyCode: 53),
        .init(label: "⌫ Delete", keyCode: 51),
        .init(label: "←", keyCode: 123), .init(label: "→", keyCode: 124),
        .init(label: "↓", keyCode: 125), .init(label: "↑", keyCode: 126),
        .init(label: "A", keyCode: 0), .init(label: "B", keyCode: 11),
        .init(label: "C", keyCode: 8), .init(label: "D", keyCode: 2),
        .init(label: "E", keyCode: 14), .init(label: "F", keyCode: 3),
        .init(label: "G", keyCode: 5), .init(label: "H", keyCode: 4),
        .init(label: "I", keyCode: 34), .init(label: "J", keyCode: 38),
        .init(label: "K", keyCode: 40), .init(label: "L", keyCode: 37),
        .init(label: "M", keyCode: 46), .init(label: "N", keyCode: 45),
        .init(label: "O", keyCode: 31), .init(label: "P", keyCode: 35),
        .init(label: "Q", keyCode: 12), .init(label: "R", keyCode: 15),
        .init(label: "S", keyCode: 1), .init(label: "T", keyCode: 17),
        .init(label: "U", keyCode: 32), .init(label: "V", keyCode: 9),
        .init(label: "W", keyCode: 13), .init(label: "X", keyCode: 7),
        .init(label: "Y", keyCode: 16), .init(label: "Z", keyCode: 6),
        .init(label: "0", keyCode: 29), .init(label: "1", keyCode: 18),
        .init(label: "2", keyCode: 19), .init(label: "3", keyCode: 20),
        .init(label: "4", keyCode: 21), .init(label: "5", keyCode: 23),
        .init(label: "6", keyCode: 22), .init(label: "7", keyCode: 26),
        .init(label: "8", keyCode: 28), .init(label: "9", keyCode: 25),
        .init(label: "F1", keyCode: 122), .init(label: "F2", keyCode: 120),
        .init(label: "F3", keyCode: 99), .init(label: "F4", keyCode: 118),
        .init(label: "F5", keyCode: 96), .init(label: "F6", keyCode: 97),
        .init(label: "F7", keyCode: 98), .init(label: "F8", keyCode: 100),
        .init(label: "F9", keyCode: 101), .init(label: "F10", keyCode: 109),
        .init(label: "F11", keyCode: 103), .init(label: "F12", keyCode: 111)
    ]

    static func makeShortcut(keyCode: UInt16, command: Bool, shift: Bool,
                             option: Bool, control: Bool) -> RemoteShortcut {
        let label = keys.first(where: { $0.keyCode == keyCode })?.label ?? "Key \(keyCode)"
        if RemoteModifier.location(of: keyCode) != nil {
            return RemoteShortcut(
                keyCode: keyCode, keyLabel: label,
                command: false, shift: false, option: false, control: false
            )
        }
        return RemoteShortcut(
            keyCode: keyCode, keyLabel: label,
            command: command, shift: shift, option: option, control: control
        )
    }
}

/// Local first-responder fallback for systems without global intercept access.
private final class ShortcutCaptureNSView: NSView {
    var onRecorded: ((RemoteShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onFeedback: ((String) -> Void)?
    private var modifierState = RemoteModifierCaptureState()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) { capture(event) }

    override func flagsChanged(with event: NSEvent) {
        guard RemoteModifier.location(of: event.keyCode) != nil else { return }
        if let standalone = modifierState.flagsChanged(keyCode: event.keyCode) {
            onRecorded?(ShortcutKeyCatalog.makeShortcut(
                keyCode: standalone, command: false, shift: false,
                option: false, control: false
            ))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event)
        return true
    }

    private func capture(_ event: NSEvent) {
        if event.isARepeat { return }
        let physicalModifiers = modifierState.heldCodes
        modifierState.ordinaryKeyPressed()
        // Escape cancels rather than accidentally becoming a mapping.
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let control = flags.contains(.control)
        let label: String
        switch event.keyCode {
        case 36: label = "↩"
        case 48: label = "⇥"
        case 49: label = "Space"
        case 51: label = "⌫"
        case 115: label = "Home"
        case 119: label = "End"
        case 116: label = "Page Up"
        case 121: label = "Page Down"
        case 123: label = "←"
        case 124: label = "→"
        case 125: label = "↓"
        case 126: label = "↑"
        case 122: label = "F1"
        case 120: label = "F2"
        case 99: label = "F3"
        case 118: label = "F4"
        case 96: label = "F5"
        case 97: label = "F6"
        case 98: label = "F7"
        case 100: label = "F8"
        case 101: label = "F9"
        case 109: label = "F10"
        case 103: label = "F11"
        case 111: label = "F12"
        default:
            let text = (event.charactersIgnoringModifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !text.isEmpty, text.count <= 3 else {
                onFeedback?("无法识别这个按键，请尝试其他组合。")
                return
            }
            label = text
        }

        onRecorded?(RemoteShortcut(
            keyCode: event.keyCode, keyLabel: label,
            command: command, shift: shift, option: option, control: control
        ).withPhysicalModifierKeys(physicalModifiers))
    }
}

private struct KeyboardEventCapture: NSViewRepresentable {
    let onRecorded: (RemoteShortcut) -> Void
    let onCancel: () -> Void
    let onFeedback: (String) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onRecorded = onRecorded
        view.onCancel = onCancel
        view.onFeedback = onFeedback
        return view
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onRecorded = onRecorded
        view.onCancel = onCancel
        view.onFeedback = onFeedback
    }
}

struct ShortcutRecorderSheet: View {
    let key: RemoteKey
    let gesture: RemoteGesture
    var targetDescription: String? = nil
    let onRecorded: (RemoteShortcut) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var feedback = "直接按 K、Space、Return、方向键或 ⌘⇧K 等组合"
    @StateObject private var globalCapture = ShortcutGlobalCapture()
    @State private var didComplete = false
    // Visual keyboard is the primary experience; global interception is an
    // optional advanced mode rather than immediately grabbing Doubao hotkeys.
    @State private var useManualEntry = true
    @State private var keyCode: UInt16 = 49
    @State private var command = false
    @State private var shift = false
    @State private var option = false
    @State private var control = false
    @State private var commandSide: RemoteModifierSide = .left
    @State private var optionSide: RemoteModifierSide = .left
    @State private var controlSide: RemoteModifierSide = .left
    @State private var shiftSide: RemoteModifierSide = .left
    @State private var showExtendedKeyboard = false

    private var manuallyConfiguredShortcut: RemoteShortcut {
        var shortcut = ShortcutKeyCatalog.makeShortcut(
            keyCode: keyCode, command: command, shift: shift,
            option: option, control: control
        )
        if command { shortcut.commandSide = commandSide }
        if shift { shortcut.shiftSide = shiftSide }
        if option { shortcut.optionSide = optionSide }
        if control { shortcut.controlSide = controlSide }
        return shortcut
    }

    private func toggleModifier(_ enabled: Binding<Bool>, side: Binding<RemoteModifierSide>,
                                position: RemoteModifierSide) {
        guard position != .both else { return }
        if !enabled.wrappedValue {
            enabled.wrappedValue = true
            side.wrappedValue = position
        } else if side.wrappedValue == position {
            enabled.wrappedValue = false
        } else if side.wrappedValue == .both {
            side.wrappedValue = position == .left ? .right : .left
        } else {
            side.wrappedValue = .both
        }
    }

    private func modifierRow(_ symbol: String, name: String,
                             checked: Binding<Bool>, side: Binding<RemoteModifierSide>) -> some View {
        HStack(spacing: 10) {
            Text(symbol + " " + name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            RemoteKeyboardKeycap(
                label: "左 " + symbol,
                selected: checked.wrappedValue && (side.wrappedValue == .left || side.wrappedValue == .both),
                onPress: { toggleModifier(checked, side: side, position: .left) }
            )
            RemoteKeyboardKeycap(
                label: "右 " + symbol,
                selected: checked.wrappedValue && (side.wrappedValue == .right || side.wrappedValue == .both),
                onPress: { toggleModifier(checked, side: side, position: .right) }
            )
        }
    }

    private func keyGrid(_ keys: [ShortcutKeyOption]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 7)], spacing: 7) {
            ForEach(keys) { key in
                RemoteKeyboardKeycap(
                    label: key.label.replacingOccurrences(of: "（单键）", with: ""),
                    selected: keyCode == key.keyCode,
                    onPress: { keyCode = key.keyCode }
                )
            }
        }
    }

    private func finish(_ shortcut: RemoteShortcut) {
        guard !didComplete else { return }
        didComplete = true
        globalCapture.stop()
        onRecorded(shortcut)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 15) {
                Image(systemName: "keyboard")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(RemotePalette.indigo,
                                in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 5) {
                    Text(useManualEntry ? "手动设置快捷键" : "录制快捷键")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("正在设置：\(targetDescription ?? "\(key.title) · \(gesture.title)")")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消录制")
            }

            HStack(spacing: 9) {
                RemoteVisualOption(
                    title: "实时录制", subtitle: "按下实体键捕获",
                    symbol: "record.circle", selected: !useManualEntry,
                    compact: true, action: { useManualEntry = false }
                )
                RemoteVisualOption(
                    title: "图形化选择", subtitle: "点击键盘图示组合",
                    symbol: "keyboard", selected: useManualEntry,
                    compact: true, action: { useManualEntry = true }
                )
            }

            if useManualEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("仅一个修饰键", systemImage: "command")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("适用于豆包单键唤起")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        keyGrid(Array(ShortcutKeyCatalog.keys.prefix(8)))
                        Divider().opacity(0.4)
                        Text("常用按键")
                            .font(.system(size: 12, weight: .semibold))
                        keyGrid(Array(ShortcutKeyCatalog.keys.dropFirst(8).prefix(9)))
                        DisclosureGroup(isExpanded: $showExtendedKeyboard) {
                            keyGrid(Array(ShortcutKeyCatalog.keys.dropFirst(17)))
                                .padding(.top, 8)
                        } label: {
                            Label("字母、数字与 F 功能键", systemImage: "square.grid.3x3")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .tint(RemotePalette.indigo)
                        if RemoteModifier.location(of: keyCode) == nil {
                            Divider().opacity(0.4)
                            HStack {
                                Text("组合修饰键")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("单击左键、右键；可同时选择两侧")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            modifierRow("⌘", name: "Command", checked: $command, side: $commandSide)
                            modifierRow("⌥", name: "Option", checked: $option, side: $optionSide)
                            modifierRow("⌃", name: "Control", checked: $control, side: $controlSide)
                            modifierRow("⇧", name: "Shift", checked: $shift, side: $shiftSide)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("快捷键预览")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            RemoteShortcutVisual(shortcut: manuallyConfiguredShortcut)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RemotePalette.indigo.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(16)
                }
                .frame(maxHeight: 470)
                .background(RemotePalette.indigo.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 17))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 17)
                        .fill(RemotePalette.indigo.opacity(0.07))
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(RemotePalette.indigo.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    VStack(spacing: 12) {
                        Image(systemName: "command.square")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(RemotePalette.indigo)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("⌘   /   K   /   ⌘⇧K")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text(globalCapture.running ? globalCapture.feedback : feedback)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 15)
                    }
                    KeyboardEventCapture(
                        onRecorded: finish,
                        onCancel: { dismiss() },
                        onFeedback: { feedback = $0 }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.01)
                    .accessibilityLabel("按下希望绑定的键盘组合")
                }
                .frame(height: 195)
                HStack {
                    Image(systemName: globalCapture.running ? "lock.shield.fill" : "exclamationmark.shield")
                    Text(globalCapture.running
                         ? "已启用临时系统级拦截：仅录制窗口期间生效"
                         : "全局拦截不可用时可直接使用「手动选择」")
                    Spacer()
                    Button("重试拦截") { globalCapture.start() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack {
                Label("支持单独 Command、其他修饰键及组合键；Esc 默认取消。",
                      systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("绑定 Esc") {
                    finish(RemoteShortcut(keyCode: 53, keyLabel: "Esc",
                                              command: false, shift: false, option: false, control: false))
                }
                .buttonStyle(RemoteActionButtonStyle())
                Button("取消") { dismiss() }
                    .buttonStyle(RemoteActionButtonStyle())
                if useManualEntry {
                    Button("保存快捷键") {
                        finish(manuallyConfiguredShortcut)
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }
            }
        }
        .padding(26)
        .frame(width: 565)
        .accessibilityElement(children: .contain)
        .onAppear {
            didComplete = false
            globalCapture.onRecorded = { shortcut in
                DispatchQueue.main.async { finish(shortcut) }
            }
            globalCapture.onCancel = {
                DispatchQueue.main.async { dismiss() }
            }
            if !useManualEntry { globalCapture.start() }
        }
        .onChange(of: useManualEntry) { _, manual in
            if manual { globalCapture.stop() }
            else { globalCapture.start() }
        }
        .onDisappear { globalCapture.stop() }
    }
}
