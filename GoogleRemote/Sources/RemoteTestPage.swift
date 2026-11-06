import AppKit
import CoreBluetooth
import CoreGraphics
import SwiftUI

/// The default landing experience: check required permissions first, then
/// provide an instantly interactive remote. UI clicks never run bound actions.
struct RemoteTestPage: View {
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var bluetooth: RemoteBluetoothManager
    @Binding var selected: RemoteKey
    let onConfigure: () -> Void
    let onConnect: () -> Void
    let onDiagnose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inputStatus = SystemHIDProbe.inputMonitoringStatus
    @State private var accessibilityAllowed = CGPreflightPostEventAccess()
    @State private var clickFlash: RemoteKey?
    @State private var clickToken = UUID()
    @State private var clickCount = 0
    @State private var lastUIClick = "点击遥控器图示上的任意按键开始测试"
    @State private var lastPhysicalSequence = 0
    @State private var lastPhysicalFeedback = "等待实体遥控器按键"

    private var bluetoothAuthorized: Bool {
        CBCentralManager.authorization == .allowedAlways
    }

    private var needsRequiredPermissions: Bool {
        inputStatus != .granted ||
            (!monitor.isExclusive && !bluetoothAuthorized) ||
            (monitor.executeHardwareActions && !accessibilityAllowed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needsRequiredPermissions {
                permissionGuide
            }

            RemoteCard {
                HStack(spacing: 13) {
                    Image(systemName: "appletvremote.gen4")
                        .font(.system(size: 20))
                        .foregroundStyle(RemotePalette.indigo)
                        .frame(width: 44, height: 44)
                        .background(RemotePalette.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("遥控器测试台")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(monitor.isExclusive ?
                             "实体遥控器 HID 已独占 · 可以测试实体按键" :
                             bluetooth.connectedDeviceID != nil ?
                             "BLE 已连接 · 正在等待系统 HID 接口" :
                             "点击图示可先测试界面；实体按键需要系统配对和 HID 独占")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    RemoteStatusPill(
                        title: monitor.isExclusive ? "实体已就绪" : "等待实体",
                        symbol: monitor.isExclusive ? "checkmark.circle.fill" : "circle.dotted",
                        tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    remoteVisual.frame(minWidth: 310, maxWidth: 410)
                    feedbackPanel.frame(minWidth: 340, maxWidth: .infinity)
                }
                VStack(spacing: 14) {
                    remoteVisual
                    feedbackPanel
                }
            }
        }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onChange(of: monitor.hardwareEventSequence) { _, sequence in
            guard sequence != lastPhysicalSequence else { return }
            lastPhysicalSequence = sequence
            lastPhysicalFeedback = monitor.lastHardwareFeedback
        }
    }

    private var remoteVisual: some View {
        RemoteCard {
            VStack(alignment: .center, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeModel.name)
                            .font(.system(size: 14, weight: .semibold))
                        Text("点击高亮 · 长按识别 · 实体按键同步")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(store.activeModel == .googleG9N9N
                         ? "\(monitor.learnedCodes.count) HID · 语音 ATVV"
                         : "\(store.activeModel.modelLabel) · HID 待验证")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                RemoteKeyVisual(
                    selected: $selected,
                    store: store,
                    feedbackKey: monitor.highlightedPhysicalKey ?? clickFlash
                ) { key, gesture in
                    testClick(key, gesture: gesture)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var feedbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            RemoteCard {
                VStack(alignment: .leading, spacing: 15) {
                    RemoteSectionTitle(
                        title: "实时测试结果",
                        subtitle: "严格区分鼠标点击和真实的 HID 物理事件",
                        symbol: "waveform.path.ecg"
                    )
                    feedbackRow(
                        title: "界面点击",
                        description: lastUIClick,
                        symbol: "cursorarrow.click.2",
                        tint: RemotePalette.indigo
                    )
                    feedbackRow(
                        title: "实体按键",
                        description: lastPhysicalFeedback,
                        symbol: "dot.radiowaves.left.and.right",
                        tint: RemotePalette.positive
                    )
                    HStack(spacing: 9) {
                        Label("\(clickCount) 次界面点击", systemImage: "hand.tap")
                        Spacer()
                        Label("\(monitor.learnedCodes.count) 个 HID 映射", systemImage: "checkmark.circle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    Text("鼠标点击只测试界面与高亮效果，不会向 macOS 发送按键，也不会执行绑定脚本。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                    RemoteSectionTitle(
                        title: "下一步",
                        subtitle: "选择按键并绑定动作；只有缺少默认码表时才需要高级学习",
                        symbol: "slider.horizontal.3"
                    )
                    HStack(spacing: 9) {
                        Image(systemName: selected.symbol)
                            .foregroundStyle(RemotePalette.indigo)
                            .frame(width: 36, height: 36)
                            .background(RemotePalette.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已选择：\(selected.title)")
                                .font(.system(size: 13, weight: .semibold))
                            Text(selected == .assistant
                                 ? "语音助手走 ATVV，开启「语音」接收后可验证实体事件" :
                                 monitor.learnedCodes[selected] != nil ?
                                 "该实体键已映射，可以设置单击与长按动作" :
                                 "尚无已验证码值；可在设置中开启高级学习")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Button {
                        onConfigure()
                    } label: {
                        Label("配置「\(selected.title)」", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    HStack(spacing: 10) {
                        Button("连接设备") { onConnect() }
                            .buttonStyle(RemoteActionButtonStyle())
                        Button("高级诊断") { onDiagnose() }
                            .buttonStyle(RemoteActionButtonStyle())
                        Spacer()
                    }
                }
            }
            RemoteCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("运行设置")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        RemoteStatusPill(title: monitor.autoSeizeEnabled ? "自动匹配已开启" : "已暂停",
                                         symbol: "lock.shield",
                                         tint: monitor.autoSeizeEnabled ? RemotePalette.positive : .secondary)
                    }
                    Toggle("自动匹配并独占遥控器", isOn: Binding(
                        get: { monitor.autoSeizeEnabled },
                        set: { $0 ? monitor.enableAutomaticCapture() : monitor.disableAutomaticCapture() }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    Toggle("允许实体按键执行已绑定的动作", isOn: $monitor.executeHardwareActions)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    Text("执行动作（含本地脚本）与 HID 独占是独立开关，首次使用可以先不开启执行。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func feedbackRow(title: String, description: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionGuide: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 20))
                        .foregroundStyle(RemotePalette.indigo)
                        .frame(width: 43, height: 43)
                        .background(RemotePalette.indigo.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开始前，检查系统权限")
                            .font(.system(size: 15, weight: .semibold))
                        Text("输入监控用于实体按键；蓝牙用于语音；辅助功能仅在模拟键盘时需要。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("刷新状态") { refreshPermissions() }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                permissionRow(
                    title: "输入监控",
                    detail: "读取并独占 Google 遥控器的 HID 按键",
                    granted: inputStatus == .granted,
                    buttonTitle: inputStatus == .notDetermined ? "申请授权" : "打开设置"
                ) {
                    if inputStatus == .notDetermined {
                        _ = SystemHIDProbe.requestInputMonitoring()
                        refreshPermissions()
                    } else {
                        openSystemSettings("Privacy_ListenEvent")
                    }
                }
                permissionRow(
                    title: "蓝牙",
                    detail: "连接 ATVV 语音服务；仅 HID 按键测试时非必需",
                    granted: bluetoothAuthorized,
                    buttonTitle: "蓝牙隐私设置"
                ) {
                    openSystemSettings("Privacy_Bluetooth")
                }
                if !accessibilityAllowed {
                    permissionRow(
                        title: "辅助功能 · 执行快捷键时需要",
                        detail: "仅在向 Mac 模拟键盘输入时需要；普通点击测试与 HID 读取不需要",
                        granted: false,
                        buttonTitle: "申请授权"
                    ) {
                        _ = CGRequestPostEventAccess()
                        refreshPermissions()
                        if !accessibilityAllowed { openSystemSettings("Privacy_Accessibility") }
                    }
                }
            }
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(granted ? RemotePalette.positive : RemotePalette.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("已授权").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RemotePalette.positive)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(RemoteActionButtonStyle())
            }
        }
    }

    private func testClick(_ key: RemoteKey, gesture: RemoteGesture) {
        let token = UUID()
        clickToken = token
        clickFlash = key
        clickCount += 1
        lastUIClick = "图示\(gesture.title)成功：\(key.title) · \(Date().formatted(date: .omitted, time: .standard))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            guard clickToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                clickFlash = nil
            }
        }
    }

    private func refreshPermissions() {
        inputStatus = SystemHIDProbe.inputMonitoringStatus
        accessibilityAllowed = CGPreflightPostEventAccess()
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
