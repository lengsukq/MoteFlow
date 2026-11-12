import AppKit
import CoreGraphics
import SwiftUI

/// Clean, beginner-friendly landing workbench: shows the interactive remote
/// side-by-side with live press feedback, current button assignment summary,
/// and 1-click navigation to customize or pair a second Mac.
struct RemoteTestPage: View {
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var library: RemoteLibraryStore
    @ObservedObject var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @Binding var selected: RemoteKey
    let onConfigure: () -> Void
    let onConnect: () -> Void
    let onOpenDualMac: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clickFlash: RemoteKey?
    @State private var clickToken = UUID()
    @State private var lastUIClick = "点击左侧遥控器上的任意按钮可预览并查看功能"
    @State private var lastPhysicalSequence = 0
    @State private var lastPhysicalFeedback = "按下手中的实体遥控器按键，此处会实时显示识别结果"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                remoteIllustrationCard
                    .frame(minWidth: 308, maxWidth: 390)
                rightInspectionColumn
                    .frame(minWidth: 350, maxWidth: .infinity)
            }
            VStack(spacing: 16) {
                remoteIllustrationCard
                rightInspectionColumn
            }
        }
        .onChange(of: monitor.hardwareEventSequence) { _, sequence in
            guard sequence != lastPhysicalSequence else { return }
            lastPhysicalSequence = sequence
            lastPhysicalFeedback = monitor.lastHardwareFeedback
            if let key = monitor.activePhysicalKey ?? monitor.highlightedPhysicalKey {
                selected = key
            }
        }
    }

    private var remoteIllustrationCard: some View {
        RemoteCard {
            VStack(alignment: .center, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.activeModel.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text("点按按钮查看功能 · 按真机同步高亮")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RemoteStatusPill(
                        title: monitor.isExclusive ? "真机已连" : "界面预览",
                        symbol: monitor.isExclusive ? "checkmark.circle.fill" : "hand.tap",
                        tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                RemoteKeyVisual(
                    selected: $selected,
                    store: store,
                    feedbackKey: monitor.highlightedPhysicalKey ?? clickFlash
                ) { key, gesture in
                    previewTap(key, gesture: gesture)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var rightInspectionColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectedKeySummaryCard
            liveFeedbackCard
            quickControlsCard
        }
    }

    private var selectedKeySummaryCard: some View {
        let binding = store.binding(for: selected)
        let tapDesc = library.description(for: binding.action(for: .tap))
        let holdDesc = library.description(for: binding.action(for: .longPress))

        return RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: selected.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RemotePalette.indigo)
                        .frame(width: 46, height: 46)
                        .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前选中：\(selected.title)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("\(selected.location) · 点击下方按钮即可修改它的动作")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if selected == .assistant {
                    actionPreviewRow(
                        badge: "语音键",
                        text: holdDesc == "未配置" ? "前往「语音输入」页面可一键配置豆包语音或本地转写" : holdDesc,
                        configured: holdDesc != "未配置"
                    )
                } else {
                    HStack(spacing: 10) {
                        actionPreviewRow(
                            badge: "单击动作",
                            text: tapDesc,
                            configured: binding.action(for: .tap).kind != .none
                        )
                        actionPreviewRow(
                            badge: "长按动作",
                            text: holdDesc,
                            configured: binding.action(for: .longPress).kind != .none
                        )
                    }
                }

                Button {
                    onConfigure()
                } label: {
                    Label("修改「\(selected.title)」的功能", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    private func actionPreviewRow(badge: String, text: String, configured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(configured ? RemotePalette.indigo : .secondary)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(configured ? .primary : .secondary)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveFeedbackCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                RemoteSectionTitle(
                    title: "实时响应检测",
                    subtitle: "按手中的遥控器验证连接状态；鼠标点按仅用于预览，不会误触发脚本",
                    symbol: "waveform.path.ecg"
                )

                feedbackRow(
                    title: "实体遥控器信号",
                    description: lastPhysicalFeedback,
                    symbol: "dot.radiowaves.left.and.right",
                    tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber
                )

                feedbackRow(
                    title: "界面点按预览",
                    description: lastUIClick,
                    symbol: "hand.tap",
                    tint: RemotePalette.indigo
                )
            }
        }
    }

    private var quickControlsCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("常用运行开关")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if lanRelay.isConnected {
                        RemoteStatusPill(
                            title: lanRelay.isForwardingToRemoteMac
                                ? "正在控制远端：\(lanRelay.connectedPeerName ?? "另一台 Mac")"
                                : "双机已就绪",
                            symbol: "macbook.and.ipad",
                            tint: RemotePalette.turquoise
                        )
                    }
                }

                Toggle("允许实体遥控器按键执行动作（快捷键 / 复制粘贴 / 脚本）", isOn: $monitor.executeHardwareActions)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .medium))

                Toggle("发现已配对遥控器时自动接管按键", isOn: Binding(
                    get: { monitor.autoSeizeEnabled },
                    set: { $0 ? monitor.enableAutomaticCapture() : monitor.disableAutomaticCapture() }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12))

                HStack(spacing: 10) {
                    Button {
                        onConnect()
                    } label: {
                        Label("蓝牙与设备连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        onOpenDualMac()
                    } label: {
                        Label(
                            lanRelay.isConnected ? "切换双机目标 (\(lanRelay.switchShortcut.display))" : "连接第二台 Mac",
                            systemImage: "macbook.and.ipad"
                        )
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func feedbackRow(title: String, description: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private func previewTap(_ key: RemoteKey, gesture: RemoteGesture) {
        let token = UUID()
        clickToken = token
        clickFlash = key
        lastUIClick = "已选中「\(key.title)」（\(gesture.title)）· \(Date().formatted(date: .omitted, time: .standard))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard clickToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                clickFlash = nil
            }
        }
    }
}
