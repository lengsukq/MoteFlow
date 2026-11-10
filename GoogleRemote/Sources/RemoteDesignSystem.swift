import SwiftUI

enum RemotePalette {
    static let indigo = Color(red: 0.39, green: 0.43, blue: 0.96)
    static let turquoise = Color(red: 0.23, green: 0.77, blue: 0.77)
    static let positive = Color(red: 0.24, green: 0.73, blue: 0.52)
    static let amber = Color(red: 0.97, green: 0.69, blue: 0.30)
}

/// Identical voice behavior selector in the binding workspace and Settings.
struct RemoteVoiceTriggerSelector: View {
    @Binding var trigger: DoubaoShortcutTrigger

    var body: some View {
        HStack(spacing: 9) {
            RemoteVisualOption(
                title: "单击唤起", subtitle: "发一次完整快捷键",
                symbol: "hand.tap", selected: trigger == .tap,
                compact: true, action: { trigger = .tap }
            )
            RemoteVisualOption(
                title: "按住说话", subtitle: "会话结束自动释放",
                symbol: "hand.point.up.left.fill", selected: trigger == .hold,
                compact: true, action: { trigger = .hold }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("豆包语音快捷键触发方式")
    }
}

extension RemoteBindingKind {
    var visualTitle: String {
        switch self {
        case .none: "无动作"
        case .keyboardShortcut: "键盘按键"
        case .systemAction: "系统动作"
        case .libraryAction: "动作库"
        case .script: "本地脚本"
        case .voiceInput: "语音输入"
        }
    }

    var visualSymbol: String {
        switch self {
        case .none: "circle.slash"
        case .keyboardShortcut: "keyboard"
        case .systemAction: "gearshape.2"
        case .libraryAction: "square.stack.3d.up"
        case .script: "terminal"
        case .voiceInput: "waveform"
        }
    }

    var visualDetail: String {
        switch self {
        case .none: "不触发系统动作"
        case .keyboardShortcut: "单键、组合或修饰键"
        case .systemAction: "调用 macOS 原生功能"
        case .libraryAction: "使用已保存动作"
        case .script: "运行已授权脚本"
        case .voiceInput: "ATVV 专用，待接入"
        }
    }
}

extension RemoteActionStepKind {
    var visualSymbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .openApp: "app"
        case .script: "terminal"
        case .wait: "clock"
        }
    }

    var visualDetail: String {
        switch self {
        case .keyboard: "发送快捷键"
        case .openApp: "启动 macOS App"
        case .script: "执行脚本文件"
        case .wait: "延时后继续"
        }
    }
}

/// One selection language for remote bindings, keyboard keycaps, and action
/// library steps. Selection is never inferred from colors alone.
struct RemoteVisualChoiceStyle: ButtonStyle {
    let selected: Bool
    var radius: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? RemotePalette.indigo.opacity(0.11) : Color.primary.opacity(0.032))
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? RemotePalette.indigo.opacity(0.65) :
                                  Color.primary.opacity(0.075), lineWidth: selected ? 1.5 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct RemoteVisualOption: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 15 : 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : RemotePalette.indigo)
                    .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                    .background(selected ? RemotePalette.indigo :
                                RemotePalette.indigo.opacity(0.085),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 1 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(RemotePalette.indigo)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 47 : 59, alignment: .leading)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(RemoteVisualChoiceStyle(selected: selected))
        .accessibilityLabel(title + (subtitle.isEmpty ? "" : "，" + subtitle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The very same keycap is used in the keyboard editor and the binding/step
/// previews, including standalone left/right Command and modifier chords.
struct RemoteKeyboardKeycap: View {
    let label: String
    var selected = false
    var width: CGFloat? = nil
    var onPress: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onPress {
                Button(action: onPress) { keyContent }
                    .buttonStyle(RemoteVisualChoiceStyle(selected: selected, radius: 10))
            } else {
                keyContent
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selected ? RemotePalette.indigo.opacity(0.11) : Color.primary.opacity(0.045))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? RemotePalette.indigo.opacity(0.55) :
                                          Color.primary.opacity(0.07))
                    }
            }
        }
        .accessibilityLabel(label)
    }

    private var keyContent: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? RemotePalette.indigo : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: 36)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .padding(.horizontal, width == nil ? 5 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct RemoteShortcutVisual: View {
    let shortcut: RemoteShortcut?
    var placeholder = "点击设置快捷键"

    private var modifierLabels: [String] {
        guard let shortcut else { return [] }
        func label(_ symbol: String, side: RemoteModifierSide?) -> String {
            switch side {
            case .left: symbol + "左"
            case .right: symbol + "右"
            case .both: symbol + "双"
            case nil: symbol
            }
        }
        var labels: [String] = []
        if shortcut.command { labels.append(label("⌘", side: shortcut.commandSide)) }
        if shortcut.shift { labels.append(label("⇧", side: shortcut.shiftSide)) }
        if shortcut.option { labels.append(label("⌥", side: shortcut.optionSide)) }
        if shortcut.control { labels.append(label("⌃", side: shortcut.controlSide)) }
        return labels
    }

    var body: some View {
        if let shortcut {
            HStack(spacing: 5) {
                if shortcut.isModifierOnly {
                    RemoteKeyboardKeycap(label: shortcut.display, selected: true,
                                         width: 82)
                } else {
                    ForEach(Array(modifierLabels.enumerated()), id: \.offset) { _, label in
                        RemoteKeyboardKeycap(label: label, selected: true, width: 45)
                    }
                    RemoteKeyboardKeycap(label: shortcut.keyLabel,
                                         selected: true, width: shortcut.keyLabel.count > 4 ? 78 : 54)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(shortcut.display)
        } else {
            Label(placeholder, systemImage: "keyboard")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct RemoteBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [RemotePalette.indigo.opacity(0.075), .clear, RemotePalette.turquoise.opacity(0.035)],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                Circle()
                    .fill(RemotePalette.indigo.opacity(0.07))
                    .frame(width: 340, height: 340)
                    .blur(radius: 90)
                    .offset(x: geometry.size.width * 0.08, y: -180)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct RemoteCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(RemotePalette.indigo.opacity(isHovered ? 0.17 : 0.065), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.065 : 0.035), radius: isHovered ? 24 : 20, x: 0, y: 9)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.20), value: isHovered)
    }
}

struct RemoteSectionTitle: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RemotePalette.indigo)
                .frame(width: 36, height: 36)
                .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
        }
    }
}

struct RemoteStatusPill: View {
    let title: String
    let symbol: String
    var tint: Color = RemotePalette.indigo

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.14), lineWidth: 1))
    }
}

struct RemoteMetric: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = RemotePalette.indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(value)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.primary.opacity(0.055)))
    }
}

struct RemoteActionButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(emphasized ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(emphasized ? RemotePalette.indigo : Color.primary.opacity(0.065))
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct RemoteMicrophoneVisual: View {
    let isActive: Bool
    let audioLevel: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(RemotePalette.indigo.opacity(isActive ? 0.22 : 0.10), lineWidth: 1.5)
                .frame(width: 172, height: 172)
                .scaleEffect(breathing && isActive ? 1.06 : 0.96)
            Circle()
                .strokeBorder(RemotePalette.turquoise.opacity(isActive ? 0.30 : 0.13), lineWidth: 1)
                .frame(width: 141, height: 141)
                .scaleEffect(breathing && isActive ? 1.11 : 0.96)
            Circle()
                .fill(
                    LinearGradient(colors: [RemotePalette.indigo.opacity(0.22), RemotePalette.turquoise.opacity(0.17)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 116, height: 116)
                .blur(radius: isActive ? 8 : 0)
            Circle()
                .fill(LinearGradient(colors: [RemotePalette.indigo, RemotePalette.turquoise],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 85, height: 85)
                .scaleEffect(isActive && !reduceMotion ? 1 + CGFloat(audioLevel) * 0.14 : 1)
                .shadow(color: RemotePalette.indigo.opacity(0.28), radius: 18, y: 7)
            Image(systemName: isActive ? "waveform" : "mic.fill")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 190, height: 190)
        .accessibilityLabel(isActive ? "正在接收语音" : "语音待机")
        .onAppear { breathing = !reduceMotion }
        .onChange(of: reduceMotion) { _, value in breathing = !value }
        .animation(reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathing && isActive)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: audioLevel)
    }
}

struct RemoteWaveform: View {
    let level: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let count = 40
                let spacing = size.width / CGFloat(count)
                for index in 0..<count {
                    let center = abs(Double(index) - Double(count - 1) / 2) / Double(count / 2)
                    let envelope = pow(max(0.08, 1 - center), 0.55)
                    let ripple = abs(sin(time * 6 + Double(index) * 0.69))
                    let height = active ? max(3, size.height * (0.10 + 0.83 * min(1, level * 2.6) * envelope * (0.3 + 0.7 * ripple))) : 3.5 + 10 * envelope
                    let rect = CGRect(x: CGFloat(index) * spacing + 1, y: (size.height - height) / 2,
                                      width: max(2, spacing - 4), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: spacing / 2),
                                 with: .color(active ? RemotePalette.turquoise : RemotePalette.indigo.opacity(0.30)))
                }
            }
        }
        .frame(height: 65)
        .accessibilityLabel(active ? "实时声音波形" : "声音波形待机")
        .accessibilityValue(active ? "输入音量 \(Int(level * 100))%" : "未录音")
    }
}
