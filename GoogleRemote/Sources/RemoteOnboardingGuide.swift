import AppKit
import CoreBluetooth
import CoreGraphics
import SwiftUI

/// Step-by-step interactive onboarding guide that helps first-time users connect,
/// grant permissions, enable action execution, and start customizing within 30 seconds.
struct RemoteQuickStartGuideCard: View {
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var bluetooth: RemoteBluetoothManager
    let configuredCount: Int
    let onOpenMapping: () -> Void
    let onOpenDualMac: () -> Void
    let onOpenPermissions: () -> Void
    let onDismiss: () -> Void

    @State private var inputStatus = SystemHIDProbe.inputMonitoringStatus
    @State private var accessibilityAllowed = CGPreflightPostEventAccess()

    private var step1Ready: Bool {
        inputStatus == .granted && monitor.isExclusive
    }

    private var step2Ready: Bool {
        monitor.executeHardwareActions && accessibilityAllowed
    }

    private var completedSteps: Int {
        [step1Ready, step2Ready, configuredCount > 0].filter { $0 }.count
    }

    var body: some View {
        RemoteCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            LinearGradient(
                                colors: [RemotePalette.indigo, RemotePalette.turquoise],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("3 步快速上手向导")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text("已完成 \(completedSteps)/3")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(completedSteps == 3 ? RemotePalette.positive : RemotePalette.indigo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    (completedSteps == 3 ? RemotePalette.positive : RemotePalette.indigo).opacity(0.11),
                                    in: Capsule()
                                )
                        }
                        Text("按顺序完成下方三步，遥控器即可直接控制这台（或局域网另一台）Mac")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        onOpenPermissions()
                    } label: {
                        Label("一页检查全部权限", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button("刷新状态") {
                        refreshPermissions()
                        monitor.tryAutomaticCapture()
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
                    .help("隐藏快速上手引导（可随时从右上角重新打开）")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        stepCards
                    }
                    VStack(spacing: 10) {
                        stepCards
                    }
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    @ViewBuilder
    private var stepCards: some View {
        onboardingStepBox(
            number: "1",
            title: "蓝牙配对与输入授权",
            detail: inputStatus != .granted
                ? "先授权 macOS「输入监控」，让软件能读取遥控器按键。"
                : (monitor.isExclusive ? "遥控器已成功连接并独占接管！" : "请在系统蓝牙设置中配对并唤醒遥控器。"),
            done: step1Ready,
            buttonTitle: inputStatus != .granted ? "授权输入监控" : "打开系统蓝牙",
            action: {
                if inputStatus == .notDetermined {
                    _ = SystemHIDProbe.requestInputMonitoring()
                    refreshPermissions()
                } else if inputStatus != .granted {
                    openPrivacyPane("Privacy_ListenEvent")
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                    NSWorkspace.shared.open(url)
                }
            }
        )

        onboardingStepBox(
            number: "2",
            title: "开启按键动作生效",
            detail: !accessibilityAllowed
                ? "模拟快捷键需要授权「辅助功能」权限。"
                : (monitor.executeHardwareActions
                    ? "动作执行已开启！现在按遥控器即可真实控制电脑。"
                    : "当前仅预览高亮；开启后按实体遥控器才会真正触发功能。"),
            done: step2Ready,
            buttonTitle: !accessibilityAllowed ? "授权辅助功能" : "一键开启生效",
            action: {
                if !accessibilityAllowed {
                    _ = CGRequestPostEventAccess()
                    refreshPermissions()
                    if !accessibilityAllowed {
                        openPrivacyPane("Privacy_Accessibility")
                    }
                } else {
                    monitor.executeHardwareActions = true
                }
            }
        )

        onboardingStepBox(
            number: "3",
            title: "自定义按键与双机切换",
            detail: "已预置方向键、确认、返回及复制粘贴；支持两台 Mac 自动连接与配置同步。",
            done: step1Ready && step2Ready,
            buttonTitle: "自定义按键",
            secondaryTitle: "双机互联",
            action: onOpenMapping,
            secondaryAction: onOpenDualMac
        )
    }

    private func onboardingStepBox(
        number: String,
        title: String,
        detail: String,
        done: Bool,
        buttonTitle: String,
        secondaryTitle: String? = nil,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
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

            HStack(spacing: 8) {
                if !done || secondaryAction != nil {
                    Button(buttonTitle, action: action)
                        .buttonStyle(RemoteActionButtonStyle(emphasized: !done))
                } else {
                    Label("已就绪", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RemotePalette.positive)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(RemoteActionButtonStyle())
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(done ? RemotePalette.positive.opacity(0.30) : .primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func refreshPermissions() {
        inputStatus = SystemHIDProbe.inputMonitoringStatus
        accessibilityAllowed = CGPreflightPostEventAccess()
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
