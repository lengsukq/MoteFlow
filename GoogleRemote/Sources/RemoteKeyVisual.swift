import SwiftUI

private struct RemotePhysicalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }

}

private struct RemoteButtonFace: View {
    let key: RemoteKey
    var width: CGFloat = 53
    var height: CGFloat = 48
    let selected: Bool
    let configured: Bool
    let feedbackActive: Bool
    let longPressThreshold: Double
    var darkAppearance = false
    let onSelect: (RemoteKey, RemoteGesture) -> Void
    @State private var hovered = false
    @State private var didLongPress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAssistant: Bool { key == .assistant }
    private var fill: Color {
        if feedbackActive { return RemotePalette.positive }
        if selected { return RemotePalette.indigo }
        if isAssistant { return Color(nsColor: .labelColor).opacity(0.92) }
        if darkAppearance { return Color.white.opacity(0.16) }
        return Color(nsColor: .controlBackgroundColor)
    }

    var body: some View {
        Button {
            if didLongPress {
                didLongPress = false
            } else {
                onSelect(key, .tap)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: min(width, height) * 0.48, style: .continuous)
                    .fill(fill)
                    .shadow(color: feedbackActive ? RemotePalette.positive.opacity(0.44) :
                            selected ? RemotePalette.indigo.opacity(0.32) : Color.black.opacity(0.10),
                            radius: feedbackActive ? 18 : selected ? 10 : 5, x: 0, y: 3)

                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(feedbackActive || selected || isAssistant || darkAppearance ? .white : .primary)

                if configured {
                    Circle()
                        .fill(selected || feedbackActive ? Color.white : RemotePalette.positive)
                        .frame(width: 7, height: 7)
                        .padding(5)
                }
            }
            .frame(width: width, height: height)
            .overlay {
                RoundedRectangle(cornerRadius: min(width, height) * 0.48)
                    .strokeBorder(feedbackActive ? RemotePalette.positive :
                        selected ? RemotePalette.indigo.opacity(0.70) :
                        (darkAppearance ? Color.white.opacity(hovered ? 0.35 : 0.12) :
                            Color.primary.opacity(hovered ? 0.19 : 0.08)), lineWidth: selected ? 1.5 : 0.7)
            }
            .scaleEffect(hovered && !reduceMotion ? 1.065 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: hovered)
        }
        .buttonStyle(RemotePhysicalButtonStyle())
        .onLongPressGesture(minimumDuration: longPressThreshold, pressing: { pressed in
            if !pressed, didLongPress {
                // If the system does not deliver the Button action after a
                // long press, clear the guard before the next independent tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    didLongPress = false
                }
            }
        }, perform: {
            didLongPress = true
            onSelect(key, .longPress)
        })
        .onHover { hovered = $0 }
        .help("\(key.title) · 点击配置单击，长按配置长按")
        .accessibilityLabel("\(key.title)，\(configured ? "已配置" : "未配置")")
    }

    @ViewBuilder
    private var label: some View {
        switch key {
        case .youtube:
            Text("YouTube")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(-0.5)
        case .netflix:
            Text("NETFLIX")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(-0.2)
        case .select:
            Circle()
                .fill((selected ? Color.white : Color.primary).opacity(0.12))
                .frame(width: 13, height: 13)
        default:
            Image(systemName: key.symbol)
                .font(.system(size: key == .assistant ? 19 : 16, weight: .semibold))
        }
    }
}

/// A vector-drawn, individually clickable representation of the original
/// Chromecast Voice Remote. No image hotspots, fixed screenshots, or web UI.
struct RemoteKeyVisual: View {
    @Binding var selected: RemoteKey
    @ObservedObject var store: RemoteBindingStore
    var feedbackKey: RemoteKey?
    var onInteraction: ((RemoteKey, RemoteGesture) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            if store.activeModel == .googleG9N9N {
                googleRemote
            } else {
                xiaomiRemote
            }

            HStack(spacing: 8) {
                Circle().fill(RemotePalette.indigo).frame(width: 8, height: 8)
                Text("当前选中")
                Circle().fill(RemotePalette.positive).frame(width: 8, height: 8)
                    .padding(.leading, 9)
                Text("已配置")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private var googleRemote: some View {
        ZStack {
            shell
            VStack(spacing: 19) {
                dpad.padding(.top, 5)
                HStack(spacing: 32) {
                    keyFace(.back)
                    keyFace(.assistant)
                }
                HStack(spacing: 32) {
                    keyFace(.home)
                    keyFace(.mute)
                }
                HStack(spacing: 32) {
                    keyFace(.youtube)
                    keyFace(.netflix)
                }
                HStack(spacing: 42) {
                    keyFace(.power, width: 43, height: 39)
                    keyFace(.input, width: 43, height: 39)
                }
                Circle()
                    .fill(RemotePalette.indigo.opacity(0.53))
                    .frame(width: 4, height: 4)
                    .padding(.top, -5)
            }
            .offset(y: -12)
            VStack(spacing: 2) {
                keyFace(.volumeUp, width: 36, height: 43)
                keyFace(.volumeDown, width: 36, height: 43)
            }
            .padding(3)
            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.13)))
            .offset(x: 113, y: -58)
        }
        .frame(width: 290, height: 520)
    }

    /// Interactive SwiftUI illustration for Xiaomi 2 / 2 Pro. It is deliberately
    /// a semantic schematic, not an assertion that unverified HID codes work.
    private var xiaomiRemote: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 45, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.20, green: 0.23, blue: 0.29),
                             Color(red: 0.095, green: 0.11, blue: 0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 206, height: 496)
                .overlay {
                    RoundedRectangle(cornerRadius: 45)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.19), radius: 22, x: 0, y: 13)

            VStack(spacing: 19) {
                HStack(spacing: 62) {
                    xiaomiFace(.power, width: 43, height: 40)
                    xiaomiFace(.assistant, width: 43, height: 40)
                }
                .padding(.bottom, 3)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.11))
                        .frame(width: 155, height: 155)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16)))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.09))
                        .frame(width: 108, height: 108)
                    xiaomiFace(.up, width: 55, height: 40).offset(y: -51)
                    xiaomiFace(.down, width: 55, height: 40).offset(y: 51)
                    xiaomiFace(.left, width: 40, height: 55).offset(x: -51)
                    xiaomiFace(.right, width: 40, height: 55).offset(x: 51)
                    xiaomiFace(.select, width: 58, height: 58)
                }
                .frame(height: 157)

                HStack(spacing: 14) {
                    xiaomiFace(.back, width: 48, height: 43)
                    xiaomiFace(.home, width: 48, height: 43)
                    xiaomiFace(.menu, width: 48, height: 43)
                }
                HStack(spacing: 37) {
                    VStack(spacing: 3) {
                        xiaomiFace(.volumeUp, width: 52, height: 40)
                        xiaomiFace(.volumeDown, width: 52, height: 40)
                    }
                    if store.activeModel.keys.contains(.tv) {
                        xiaomiFace(.tv, width: 52, height: 50)
                    } else {
                        Color.clear.frame(width: 52, height: 50)
                    }
                }
                Text("mi")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.top, 2)
            }
            .padding(.top, 18)
        }
        .frame(width: 260, height: 520)
    }

    private func xiaomiFace(_ key: RemoteKey, width: CGFloat, height: CGFloat) -> some View {
        RemoteButtonFace(
            key: key, width: width, height: height,
            selected: selected == key,
            configured: store.binding(for: key).isConfigured,
            feedbackActive: feedbackKey == key,
            longPressThreshold: store.binding(for: key).effectiveThreshold,
            darkAppearance: true,
            onSelect: { item, gesture in
                withAnimation(reduceMotion ? nil : .spring(response: 0.29, dampingFraction: 0.8)) {
                    selected = item
                }
                onInteraction?(item, gesture)
            }
        )
    }
    private var shell: some View {
        RoundedRectangle(cornerRadius: 80, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor),
                             Color(nsColor: .windowBackgroundColor),
                             Color(nsColor: .controlBackgroundColor).opacity(0.96)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 223, height: 508)
            .overlay {
                RoundedRectangle(cornerRadius: 80, style: .continuous)
                    .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 75, style: .continuous)
                    .strokeBorder(.white.opacity(0.13), lineWidth: 5)
                    .padding(4)
            }
            .shadow(color: .black.opacity(0.13), radius: 24, x: 0, y: 17)
            .accessibilityHidden(true)
    }

    private var dpad: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 164, height: 164)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

            Circle()
                .strokeBorder(.primary.opacity(0.045), lineWidth: 1)
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

            keyFace(.up, width: 59, height: 42).offset(y: -56)
            keyFace(.down, width: 59, height: 42).offset(y: 56)
            keyFace(.left, width: 42, height: 59).offset(x: -56)
            keyFace(.right, width: 42, height: 59).offset(x: 56)
            keyFace(.select, width: 63, height: 63)
        }
        .frame(width: 170, height: 170)
    }

    private func keyFace(_ key: RemoteKey, width: CGFloat = 53, height: CGFloat = 48) -> some View {
        RemoteButtonFace(
            key: key,
            width: width,
            height: height,
            selected: selected == key,
            configured: store.binding(for: key).isConfigured,
            feedbackActive: feedbackKey == key,
            longPressThreshold: store.binding(for: key).effectiveThreshold,
            onSelect: { item, gesture in
                withAnimation(reduceMotion ? nil : .spring(response: 0.29, dampingFraction: 0.80)) {
                    selected = item
                }
                onInteraction?(item, gesture)
            }
        )
    }
}
