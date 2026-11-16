import AppKit
import CoreBluetooth
import CoreGraphics
import SwiftUI

/// Progressive 3-step onboarding card tailored for first-time users:
/// - Only mutates state when macOS permission status genuinely changes (never firing
///   unconditional spring animations during background scroll).
struct RemoteQuickStartGuideCard: View {
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var bluetooth: RemoteBluetoothManager
    @ObservedObject var store: RemoteBindingStore
    let onOpenPermissions: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputStatus = SystemHIDProbe.inputMonitoringStatus
    @State private var accessibilityAllowed = CGPreflightPostEventAccess()
    @State private var appliedPresetFeedback: String?

    private var step1Ready: Bool {
        inputStatus == .granted && monitor.isExclusive
    }

    private var step2Ready: Bool {
        monitor.executeHardwareActions && accessibilityAllowed
    }

    private var completedSteps: Int {
        [step1Ready, step2Ready, store.configuredCount > 0].filter { $0 }.count
    }

    var body: some View {
        RemoteCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                headerBar

                HStack(alignment: .top, spacing: 10) {
                    stepCards
                }

                if let appliedPresetFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(RemotePalette.positive)
                        Text(appliedPresetFeedback)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(RemotePalette.positive)
                        Spacer()
                    }
                }
            }
        }
        .onAppear { refreshPermissions(animated: false) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                refreshPermissions(animated: true)
                if inputStatus == .granted && !monitor.isExclusive {
                    monitor.tryAutomaticCapture()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions(animated: false)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: completedSteps == 3 ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(
                        colors: completedSteps == 3
                            ? [RemotePalette.positive, RemotePalette.turquoise]
                            : [RemotePalette.indigo, RemotePalette.turquoise],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("新手 30 秒快速上手")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("已完成 \(completedSteps)/3 · 授权后自动检测")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(completedSteps == 3 ? RemotePalette.positive : RemotePalette.indigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            (completedSteps == 3 ? RemotePalette.positive : RemotePalette.indigo).opacity(0.11),
                            in: Capsule()
                        )
                }
                Text("只需开启 2 项基础系统权限并选一个场景模板，即可拿起遥控器直接操控（语音与双机权限按需再开）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Button {
                onOpenPermissions()
            } label: {
                Label("查看全部权限状态", systemImage: "checkmark.shield")
            }
            .buttonStyle(RemoteActionButtonStyle())

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("收起新手引导（随时可从右上角快速上手按钮重新展开）")
        }
    }

    @ViewBuilder
    private var stepCards: some View {
        onboardingStepBox(
            number: "1",
            title: "配对遥控器与输入监控",
            detail: inputStatus != .granted
                ? "授权「输入监控」让 MoteFlow 接管遥控器按键（在系统设置勾选后将自动变绿）。"
                : (monitor.isExclusive
                    ? "遥控器已自动独占接管！按下任意实体键可在下方实时看到高亮。"
                    : "请在系统「蓝牙设置」配对遥控器，并按一下遥控器任意键唤醒它。"),
            done: step1Ready
        ) {
            Button(inputStatus != .granted ? "一键开启输入监控" : "打开系统蓝牙配对") {
                if inputStatus == .notDetermined {
                    _ = SystemHIDProbe.requestInputMonitoring()
                    refreshPermissions(animated: true)
                } else if inputStatus != .granted {
                    openPrivacyPane("Privacy_ListenEvent")
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(RemoteActionButtonStyle(emphasized: !step1Ready))
        }

        onboardingStepBox(
            number: "2",
            title: "允许模拟快捷键控制",
            detail: !accessibilityAllowed
                ? "授权「辅助功能」后才能把遥控器按键转换为方向、回车与复制粘贴操作。"
                : (monitor.executeHardwareActions
                    ? "按键执行已激活！现在按下手中的遥控器即可真实控制电脑。"
                    : "权限已就绪，点击下方按钮立即允许实体遥控器触发动作。"),
            done: step2Ready
        ) {
            if !step2Ready {
                Button(!accessibilityAllowed ? "一键开启辅助功能" : "立即激活遥控控制") {
                    if !accessibilityAllowed {
                        _ = CGRequestPostEventAccess()
                        refreshPermissions(animated: true)
                        if !accessibilityAllowed {
                            openPrivacyPane("Privacy_Accessibility")
                        }
                    } else {
                        monitor.executeHardwareActions = true
                    }
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            } else {
                Label("核心权限已就绪", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RemotePalette.positive)
            }
        }

        onboardingStepBox(
            number: "3",
            title: "一键套用常用场景模板",
            detail: "点选下方任一场景即可自动配好全套按键，随后直接在下方点击任意按键微调：",
            done: step1Ready && step2Ready
        ) {
            HStack(spacing: 6) {
                ForEach(RemoteStarterScenePreset.allCases) { preset in
                    Button {
                        store.applyStarterScene(preset)
                        appliedPresetFeedback = "已套用「\(preset.title)」(\(preset.subtitle))，现在按一下遥控器试试吧！"
                    } label: {
                        Text(preset.title.replacingOccurrences(of: "模式", with: ""))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(RemotePalette.indigo)
                    }
                    .buttonStyle(.plain)
                    .help(preset.subtitle)
                }
            }
        }
    }

    private func onboardingStepBox<Footer: View>(
        number: String,
        title: String,
        detail: String,
        done: Bool,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(done ? RemotePalette.positive : RemotePalette.indigo.opacity(0.14))
                        .frame(width: 24, height: 24)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(number)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(RemotePalette.indigo)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)
            footer()
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            done ? RemotePalette.positive.opacity(0.035) : Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(done ? RemotePalette.positive.opacity(0.32) : .primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func refreshPermissions(animated: Bool) {
        let nextInput = SystemHIDProbe.inputMonitoringStatus
        let nextAX = CGPreflightPostEventAccess()
        guard nextInput != inputStatus || nextAX != accessibilityAllowed else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                inputStatus = nextInput
                accessibilityAllowed = nextAX
            }
        } else {
            inputStatus = nextInput
            accessibilityAllowed = nextAX
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
