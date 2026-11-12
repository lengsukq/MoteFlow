import AppKit
import SwiftUI

/// Real-hardware learning screen. Shared auto-capture remains active when the
/// user navigates away; only manual one-off sessions auto-release on exit.
struct RemoteKeyLabPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @ObservedObject var monitor: HIDCaptureManager
    @Binding var selectedMappingKey: RemoteKey
    @State private var candidates: [HIDRemoteCandidate] = []
    @State private var selectedDeviceID: String?
    @State private var showSeizeConfirmation = false
    @State private var exportError: String?
    @State private var hidScanReport: HIDScanReport?
    @State private var inputMonitoringStatus = SystemHIDProbe.inputMonitoringStatus

    private var inputMonitoringGranted: Bool {
        inputMonitoringStatus == .granted
    }

    private var selectedDevice: HIDRemoteCandidate? {
        candidates.first(where: { $0.id == selectedDeviceID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        RemoteSectionTitle(
                            title: "macOS 输入监控权限",
                            subtitle: "与蓝牙授权不同；HID 读取和独占需要系统许可",
                            symbol: "hand.raised"
                        )
                        Spacer(minLength: 8)
                        RemoteStatusPill(
                            title: inputMonitoringStatus.title,
                            symbol: inputMonitoringGranted ? "checkmark.shield" : "lock.shield",
                            tint: inputMonitoringGranted ? RemotePalette.positive : RemotePalette.amber
                        )
                    }
                    Text(inputMonitoringStatus.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("IOKit: \(inputMonitoringStatus.title) · CoreGraphics 检测: \(SystemHIDProbe.cgPreflightGranted ? "允许" : "未允许")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button {
                            _ = SystemHIDProbe.requestInputMonitoring()
                            inputMonitoringStatus = SystemHIDProbe.inputMonitoringStatus
                            if inputMonitoringGranted {
                                refreshDevices()
                            } else if inputMonitoringStatus == .denied {
                                openInputMonitoringSettings()
                            }
                        } label: {
                            Label(inputMonitoringStatus == .denied ? "检查输入监控设置" : "申请输入监控权限",
                                  systemImage: "checkmark.shield")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: !inputMonitoringGranted))
                        .disabled(inputMonitoringGranted)
                        Button {
                            openInputMonitoringSettings()
                        } label: {
                            Label("打开输入监控设置", systemImage: "gearshape")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        Spacer(minLength: 0)
                    }
                    Toggle("启动后自动匹配并独占已支持的遥控器", isOn: Binding(
                        get: { monitor.autoSeizeEnabled },
                        set: { enabled in
                            if enabled { monitor.enableAutomaticCapture() }
                            else { monitor.disableAutomaticCapture() }
                        }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 7) {
                        Image(systemName: "app.badge")
                            .foregroundStyle(.secondary)
                        Text("当前正在运行的 App：")
                            .font(.system(size: 11, weight: .medium))
                        Text(Bundle.main.bundleURL.path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.link)
                    }
                    if !inputMonitoringGranted {
                        Text("授权后完全退出 MoteFlow，重新打开最新版本再检测。请授权当前正在运行的 MoteFlow 应用，而不是终端或 Xcode。")
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RemoteSectionTitle(
                            title: "遥控器按键监听",
                            subtitle: "逐个采样物理按键 · 原始 HID Value 与 Report",
                            symbol: "waveform.path.ecg"
                        )
                        Spacer(minLength: 8)
                        RemoteStatusPill(
                            title: monitor.isExclusive ? "独占拦截中" : "尚未拦截",
                            symbol: monitor.isExclusive ? "lock.shield.fill" : "lock.open",
                            tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber
                        )
                    }

                    Text("App 的 BLE 连接和 macOS 系统 HID 连接是两条不同路径。若系统已识别为 HID，可尝试对指定接口独占；若找不到 HID，可检查 BLE GATT 是否暴露了输入报告。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("目标 HID 设备")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button {
                                refreshDevices()
                            } label: {
                                Label("重新检测", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                            .disabled(monitor.isCapturing)
                        }
                        if let hidScanReport {
                            Text(hidScanReport.summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(hidScanReport.error == nil ? .secondary : RemotePalette.amber)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if candidates.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                    .foregroundStyle(RemotePalette.amber)
                                Text(!inputMonitoringGranted
                                     ? "缺少输入监控权限，尚无法判断遥控器是否注册为 HID。"
                                     : hidScanReport?.error != nil
                                       ? "系统 HID 枚举发生错误，不能据此断定遥控器不存在。"
                                       : "已成功枚举，但没有 Google 遥控器 HID 接口；检查系统蓝牙配对。")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            .padding(14)
                            .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            Picker("HID 接口", selection: $selectedDeviceID) {
                                Text("请选择一个遥控器接口").tag(String?.none)
                                ForEach(candidates) { candidate in
                                    Text("\(candidate.productName) · VID \(String(format: "%04X", candidate.vendorID)) · PID \(String(format: "%04X", candidate.productID)) · \(candidate.transport)")
                                        .tag(Optional(candidate.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(monitor.isCapturing)
                            if let selectedDevice, !selectedDevice.canSeize {
                                Label("此接口身份无法安全确认，禁止独占。只能使用明确识别的 Google 遥控器接口。", systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(RemotePalette.amber)
                            }
                        }
                        if candidates.isEmpty, let hidScanReport, !hidScanReport.bluetoothDevices.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("系统中其他 Bluetooth HID（仅供识别，不允许独占）")
                                    .font(.system(size: 11, weight: .semibold))
                                ForEach(hidScanReport.bluetoothDevices) { entry in
                                    Text("\(entry.productName) · VID \(String(format: "%04X", entry.vendorID)) · PID \(String(format: "%04X", entry.productID))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                            }
                            .padding(12)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    HStack(spacing: 11) {
                        if monitor.isCapturing {
                            Button {
                                monitor.disableAutomaticCapture()
                            } label: {
                                Label("立即停止并释放", systemImage: "stop.circle.fill")
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            RemoteStatusPill(title: monitor.isAutomaticCapture ? "持续拦截（已自动匹配）" : "\(monitor.remainingSeconds)s 后自动释放",
                                             symbol: "timer",
                                             tint: RemotePalette.amber)
                        } else {
                            Button {
                                showSeizeConfirmation = true
                            } label: {
                                Label("独占选中 HID 接口", systemImage: "record.circle")
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(!inputMonitoringGranted || selectedDevice?.canSeize != true)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: monitor.isExclusive ? "checkmark.shield.fill" : "info.circle")
                            .foregroundStyle(monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber)
                        Text(monitor.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(monitor.isExclusive ? RemotePalette.positive : .secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background((monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber).opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        RemoteSectionTitle(
                            title: "BLE 按键通道探测",
                            subtitle: "适用于蓝牙已连接、但 macOS 没有 HID 设备的情况",
                            symbol: "antenna.radiowaves.left.and.right"
                        )
                        Spacer(minLength: 4)
                        RemoteStatusPill(
                            title: bluetooth.isBLEHIDMonitoring ? "仅监听 · 不拦截" :
                                bluetooth.bleHIDServiceFound ? "待启用" : "HID 服务未发现",
                            symbol: bluetooth.isBLEHIDMonitoring ? "waveform" : "info.circle",
                            tint: bluetooth.isBLEHIDMonitoring ? RemotePalette.indigo : RemotePalette.amber
                        )
                    }
                    HStack(spacing: 8) {
                        Image(systemName: bluetooth.connectedDeviceID == nil ? "circle.dotted" : "checkmark.circle")
                            .foregroundStyle(bluetooth.connectedDeviceID == nil ? RemotePalette.amber : RemotePalette.positive)
                        Text(bluetooth.connectedDeviceID == nil ? "请先连接蓝牙遥控器" : bluetooth.connectionSummary)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    Text(bluetooth.bleHIDStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            if bluetooth.isBLEHIDMonitoring {
                                bluetooth.stopBLEHIDMonitoring()
                            } else {
                                bluetooth.startBLEHIDMonitoring()
                            }
                        } label: {
                            Label(bluetooth.isBLEHIDMonitoring ? "停止 BLE 报告监听" : "尝试 BLE HID 报告监听",
                                  systemImage: bluetooth.isBLEHIDMonitoring ? "stop.circle" : "waveform.path")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: bluetooth.canMonitorBLEHID && !bluetooth.isBLEHIDMonitoring))
                        .disabled(!bluetooth.canMonitorBLEHID && !bluetooth.isBLEHIDMonitoring || monitor.isCapturing)

                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("系统蓝牙设置", systemImage: "gear")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        Spacer(minLength: 0)
                    }
                    if !bluetooth.bleHIDServiceFound && bluetooth.connectedDeviceID != nil {
                        Label("应用的 BLE 连接不等于系统 HID 配对。当前设备可能只向 CoreBluetooth 暴露 ATVV 语音服务；若 macOS 未注册 HID，也就无法独占拦截。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if candidates.isEmpty && inputMonitoringGranted && hidScanReport?.error == nil {
                        HStack(alignment: .center, spacing: 11) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("建议先完成系统级蓝牙配对")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("应用连接不是系统配对。配对过程中可暂时断开 App BLE 连接，避免占用遥控器。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button {
                                bluetooth.disconnect()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("断开 App 并前往配对", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                        }
                        .padding(12)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                    }
                    Text("BLE HID 探测只订阅遥控器的 GATT 输入通知，不能拦截系统事件。若找不到 0x1812 服务，无法通过此路径获取方向键等按键数据。语音键控制包会在 ATVV 开启时单独记录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RemoteSectionTitle(
                            title: "逐键采样",
                            subtitle: "先点选预期按键，再按一次实体遥控器按钮",
                            symbol: "cursorarrow.rays"
                        )
                        Spacer(minLength: 8)
                        Text("\(monitor.sampledKeys.count) 个 HID 已映射 · 语音走 ATVV")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(monitor.expectedKey == .assistant
                         ? "语音助手使用 ATVV 控制通知，而不是普通 HID Report。请在「语音」中开启 ATVV 接收后按实体语音键，无需 HID 学习。"
                         : "当前标签：\(monitor.expectedKey.title)。日志里的「标记」只是手动参考，不能作为识别结果。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(monitor.activePhysicalKey != nil ? RemotePalette.positive : RemotePalette.indigo)
                        Text(monitor.lastHardwareFeedback)
                            .font(.system(size: 12, weight: .medium))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer()
                    }
                    .padding(12)
                    .background((monitor.activePhysicalKey != nil ? RemotePalette.positive : RemotePalette.indigo).opacity(0.065),
                                in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 10) {
                        Button {
                            monitor.learningKey = monitor.expectedKey
                        } label: {
                            Label(monitor.learningKey == monitor.expectedKey
                                  ? "等待按下实体「\(monitor.expectedKey.title)」"
                                  : "学习当前选择的实体按键",
                                  systemImage: "record.circle")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(!monitor.isExclusive || monitor.learningKey != nil || monitor.expectedKey == .assistant)
                        if monitor.learningKey != nil {
                            Button("取消学习") { monitor.learningKey = nil }
                                .buttonStyle(RemoteActionButtonStyle())
                        }
                        if let code = monitor.learnedCodes[monitor.expectedKey] {
                            if monitor.userLearnedCodes[monitor.expectedKey] != nil {
                                Button("清除此键学习") {
                                    monitor.forgetLearnedKey(monitor.expectedKey)
                                }
                                .buttonStyle(RemoteActionButtonStyle())
                            }
                            Text(monitor.userLearnedCodes[monitor.expectedKey] == nil ? "内置默认" : "本机自定义")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Report \(code.reportID) / Code \(code.code)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("HID 仅记录真正解析的报文；语音助手通过 ATVV 单独识别，不能用学习功能生成假 HID 编码。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 9)], spacing: 9) {
                        ForEach(mappingStore.activeModel.keys) { key in
                            let selected = key == monitor.expectedKey
                            let sampled = monitor.sampledKeys.contains(key)
                            Button {
                                monitor.expectedKey = key
                                selectedMappingKey = key
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: key.symbol)
                                        .frame(width: 17)
                                    Text(key.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if sampled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(RemotePalette.positive)
                                    } else if key == .assistant {
                                        Image(systemName: "waveform")
                                            .foregroundStyle(RemotePalette.indigo)
                                    }
                                }
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 11)
                                .background(selected ? RemotePalette.indigo.opacity(0.12) : .primary.opacity(0.025),
                                            in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(selected ? RemotePalette.indigo.opacity(0.40) : .primary.opacity(0.055)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        RemoteSectionTitle(
                            title: "实时协议事件日志",
                            subtitle: "HID 独占 / BLE HID 报告 / ATVV 语音控制 · 原始十六进制",
                            symbol: "text.alignleft"
                        )
                        Spacer(minLength: 6)
                        RemoteStatusPill(title: "\(monitor.eventCount) 条事件", symbol: "number", tint: .secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnosticsText, forType: .string)
                        } label: {
                            Label("复制所有日志", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(RemoteActionButtonStyle())

                        Button {
                            exportLogs()
                        } label: {
                            Label("导出文本日志", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(monitor.isCapturing)

                        Button {
                            monitor.clearLogs()
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(monitor.events.isEmpty)
                        Spacer(minLength: 0)
                    }

                    if monitor.events.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.path")
                                .foregroundStyle(RemotePalette.indigo)
                            Text("启动 HID 独占或 BLE HID 监听后按实体键。开启 ATVV 语音时，也会捕获语音控制包。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(18)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(monitor.events.suffix(150).reversed())) { event in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: event.kind == .value ? "circle.fill" :
                                              event.kind == .report ? "square.stack" :
                                              event.kind == .ble ? "antenna.radiowaves.left.and.right" :
                                              event.kind == .atvv ? "mic" : "info.circle")
                                            .font(.system(size: 8))
                                            .foregroundStyle(event.kind == .value ? RemotePalette.positive :
                                                             event.kind == .report || event.kind == .ble ? RemotePalette.indigo : .secondary)
                                            .frame(width: 12)
                                            .padding(.top, 5)
                                        Text(event.line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(15)
                        }
                        .frame(height: 280)
                        .background(.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 13))
                    }
                    Text("安全边界：只能拦截独占成功的 HID 接口；电视红外、电源、其他复合接口或系统层转发仍可能不受影响。若未出现日志，可尝试 GATT/ATVV 路径排查。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let current = SystemHIDProbe.inputMonitoringStatus
            if current != inputMonitoringStatus {
                inputMonitoringStatus = current
                refreshDevices()
            }
        }
        .onAppear {
            inputMonitoringStatus = SystemHIDProbe.inputMonitoringStatus
            refreshDevices()
            let weakMonitor = monitor
            bluetooth.onBLEHIDReport = { [weak weakMonitor] characteristic, payload in
                weakMonitor?.recordBLEReport(characteristic: characteristic, data: payload)
            }
        }
        .onDisappear {
            bluetooth.onBLEHIDReport = nil
            bluetooth.stopBLEHIDMonitoring()
            monitor.learningKey = nil
            if monitor.isCapturing && !monitor.isAutomaticCapture {
                monitor.stop(reason: "离开临时监听页面，HID 独占已释放")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if monitor.isCapturing && !monitor.isAutomaticCapture {
                monitor.stop(reason: "应用失去焦点，已自动释放 HID 独占")
            }
            if bluetooth.isBLEHIDMonitoring {
                bluetooth.stopBLEHIDMonitoring()
            }
        }
        .confirmationDialog("独占 Google 遥控器 HID 接口？",
                            isPresented: $showSeizeConfirmation) {
            Button(monitor.autoSeizeEnabled ? "持续独占并开始监听" : "独占 90 秒并开始监听") {
                if let selectedDevice {
                    monitor.startSeizedCapture(of: selectedDevice, persistent: monitor.autoSeizeEnabled)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只独占你选定的 Google 遥控器 HID 接口。开启自动拦截时持续监听，可随时从菜单栏停止；关闭自动拦截时仅临时监听 90 秒。失败绝不会退回被动监听。")
        }
        .alert("日志导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("确定") { exportError = nil }
        } message: {
            Text(exportError ?? "未知错误")
        }
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshDevices() {
        guard !monitor.isCapturing else { return }
        inputMonitoringStatus = SystemHIDProbe.inputMonitoringStatus
        let report = SystemHIDProbe.scanDetailed()
        hidScanReport = report
        candidates = report.candidates
        if !report.candidates.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = report.candidates.first(where: \.canSeize)?.id
        }
    }

    private func exportLogs() {
        let text = diagnosticsText
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "GoogleRemote-HID-log.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var diagnosticsText: String {
        """
        MoteFlow — HID 按键采样
        导出时间：\(Date().formatted())
        注：日志中的「标记」仅为操作者选择的预期物理按键，非自动确认的 HID 映射。
        独占设备：\(selectedDevice?.productName ?? "未知")
        系统 HID 枚举：\(hidScanReport?.summary ?? "未检测")
        系统 Bluetooth HID 列表：
        \((hidScanReport?.bluetoothDevices ?? []).map { "\($0.productName) VID=\(String(format: "%04X", $0.vendorID)) PID=\(String(format: "%04X", $0.productID))" }.joined(separator: "\n"))
        应用 BLE 状态：\(bluetooth.connectionSummary)
        BLE HID 通道：\(bluetooth.bleHIDStatus)
        BLE HID 服务出现：\(bluetooth.bleHIDServiceFound)
        BLE HID 输入包数：\(bluetooth.bleHIDPacketCount)

        \(monitor.exportText())
        """
    }
}
