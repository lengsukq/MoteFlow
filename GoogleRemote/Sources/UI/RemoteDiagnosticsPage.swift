import AppKit
import SwiftUI

enum RemoteDiagnosticLogFilter: String, CaseIterable, Identifiable {
    case all = "全部日志"
    case hid = "按键 HID"
    case voice = "蓝牙语音"
    case lan = "双机网络"

    var id: String { rawValue }
}

/// Consolidated Hardware Diagnostics, Unified Log Center & Collapsible Key Sampling:
/// Replaces the 3 previously overlapping diagnostic screens (`RemoteKeyLabPage` +
/// `RemoteDiagnosticsPage` + `Settings.advanced` + DualMac inline log box) with a single
/// cohesive ~260-line page.
struct RemoteDiagnosticsPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @ObservedObject var monitor: HIDCaptureManager
    @Binding var selectedMappingKey: RemoteKey
    @Binding var logFilter: RemoteDiagnosticLogFilter
    let onExportWave: () -> Void

    @State private var hidCandidates: [HIDRemoteCandidate] = []
    @State private var selectedCandidateID: String?
    @State private var didScanHID = false
    @State private var showKeySampling = false
    @State private var showResetOverridesConfirm = false
    @State private var copiedLogs = false
    @State private var exportError: String?

    private var selectedCandidate: HIDRemoteCandidate? {
        hidCandidates.first(where: { $0.id == selectedCandidateID })
    }

    private var filteredLogLines: [String] {
        switch logFilter {
        case .all:
            let hidLines = monitor.events.suffix(120).map { "[HID] \($0.line)" }
            let btLines = bluetooth.logs.suffix(120).map { "[BLE] \($0)" }
            let lanLines = lanRelay.logs.suffix(120).map { "[LAN] \($0)" }
            return hidLines + btLines + lanLines
        case .hid:
            return monitor.events.suffix(180).map(\.line)
        case .voice:
            return bluetooth.logs.suffix(180)
        case .lan:
            return lanRelay.logs.suffix(180)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            overviewAndHardwareCard
            unifiedLogCenterCard
            collapsibleKeySamplingCard
        }
        .onAppear {
            scanHIDDevices()
            if monitor.advancedLearningEnabled {
                showKeySampling = true
            }
        }
        .onDisappear {
            monitor.learningKey = nil
        }
        .confirmationDialog("清除所有自定义学习的硬件码？", isPresented: $showResetOverridesConfirm) {
            Button("确认清除", role: .destructive) {
                monitor.clearUserOverrides()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除本机额外采样的底层硬件编码，不会删除你的按键功能绑定与动作库。")
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("确定") { exportError = nil }
        } message: {
            Text(exportError ?? "未知错误")
        }
    }

    // MARK: - 1. Overview Metrics & Manual HID Inspection

    private var overviewAndHardwareCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    RemoteSectionTitle(
                        title: "硬件连接与协议总览",
                        subtitle: "一屏查看物理 HID 独占、蓝牙 ATVV 语音协商与双机互联监听状态",
                        symbol: "stethoscope"
                    )
                    Spacer()
                    Button {
                        onExportWave()
                    } label: {
                        Label("导出语音测试录音 (.wav)", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)
                }

                HStack(spacing: 12) { overviewMetrics }

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Text("系统 HID 遥控器接口：\(monitor.status)")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        scanHIDDevices()
                    } label: {
                        Label("重新扫描接口", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(monitor.isCapturing)

                    if monitor.isCapturing {
                        Button("释放当前独占") {
                            monitor.disableAutomaticCapture()
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    } else if let candidate = selectedCandidate, candidate.canSeize {
                        Button("手动独占选中接口") {
                            monitor.startSeizedCapture(of: candidate)
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                }

                if !hidCandidates.isEmpty {
                    Picker("已识别 HID 候选设备", selection: $selectedCandidateID) {
                        ForEach(hidCandidates) { candidate in
                            Text(String(format: "%@ · VID %04X · PID %04X · %@",
                                        candidate.productName, candidate.vendorID, candidate.productID, candidate.transport))
                                .tag(Optional(candidate.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11.5))
                    .disabled(monitor.isCapturing)
                } else if didScanHID {
                    Text("暂未枚举到已配对的遥控器 HID 接口；请确认系统蓝牙已连接并授权「输入监控」。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if !bluetooth.discoveredServices.isEmpty {
                    Text("蓝牙语音协商：\(bluetooth.protocolDetails) · 已发现 \(bluetooth.discoveredServices.count) 项 GATT 条目")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var overviewMetrics: some View {
        RemoteMetric(
            title: "HID 按键独占",
            value: monitor.isExclusive ? "正常独占" : "未接管",
            symbol: "checkmark.shield",
            tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.amber
        )
        RemoteMetric(
            title: "ATVV 语音服务",
            value: bluetooth.atvvFound ? "已就绪" : "未连接",
            symbol: "waveform",
            tint: bluetooth.atvvFound ? RemotePalette.positive : RemotePalette.indigo
        )
        RemoteMetric(
            title: "双机互联端口",
            value: lanRelay.isConnected ? "已连通:\(lanRelay.sharedPort)" : "待命:\(lanRelay.sharedPort)",
            symbol: "macbook.and.ipad",
            tint: lanRelay.isConnected ? RemotePalette.turquoise : RemotePalette.indigo
        )
    }

    // MARK: - 2. Unified Filtered Log Center

    private var unifiedLogCenterCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    RemoteSectionTitle(
                        title: "统一运行日志中心",
                        subtitle: "按模块筛选查看按键原始报文、蓝牙语音握手与双机局域网通信日志",
                        symbol: "text.alignleft"
                    )
                    Spacer()
                    Picker("日志筛选", selection: $logFilter) {
                        ForEach(RemoteDiagnosticLogFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 290)
                }

                HStack(spacing: 9) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(filteredLogLines.joined(separator: "\n"), forType: .string)
                        copiedLogs = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLogs = false }
                    } label: {
                        Label(copiedLogs ? "已复制" : "复制当前日志", systemImage: copiedLogs ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(filteredLogLines.isEmpty)

                    Button {
                        exportLogsToFile()
                    } label: {
                        Label("导出日志文件 (.txt)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(filteredLogLines.isEmpty)

                    Button {
                        clearSelectedLogs()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(filteredLogLines.isEmpty)

                    Spacer()
                    Text("共 \(filteredLogLines.count) 条记录")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if filteredLogLines.isEmpty {
                    Text("当前分类暂无日志记录。按下遥控器按键、发起语音或连接另一台 Mac 后会自动刷新。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(filteredLogLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(13)
                    }
                    .frame(height: 240)
                    .background(.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - 3. Collapsible Key Hardware Code Sampling

    private var collapsibleKeySamplingCard: some View {
        RemoteCard(padding: 16) {
            DisclosureGroup(isExpanded: $showKeySampling) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Toggle("启用新型号遥控器硬件码采样（自定义硬件码随全量备份 JSON 自动导出）",
                               isOn: $monitor.advancedLearningEnabled)
                            .toggleStyle(.switch)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if !monitor.userLearnedCodes.isEmpty {
                            Button("清除全部自定义码 (\(monitor.userLearnedCodes.count))") {
                                showResetOverridesConfirm = true
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(monitor.activePhysicalKey != nil ? RemotePalette.positive : RemotePalette.indigo)
                        Text(monitor.lastHardwareFeedback)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let code = monitor.learnedCodes[monitor.expectedKey] {
                            Text("Report \(code.reportID) / Code \(code.code)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if monitor.userLearnedCodes[monitor.expectedKey] != nil {
                            Button("清除此键") {
                                monitor.forgetLearnedKey(monitor.expectedKey)
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                        }
                        Button {
                            monitor.learningKey = monitor.expectedKey
                        } label: {
                            Text(monitor.learningKey == monitor.expectedKey
                                 ? "请按实体「\(monitor.expectedKey.title)」…"
                                 : "采样「\(monitor.expectedKey.title)」")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(!monitor.advancedLearningEnabled || !monitor.isExclusive || monitor.expectedKey == .assistant)
                    }
                    .padding(11)
                    .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                        ForEach(mappingStore.activeModel.keys) { key in
                            let isSelected = key == monitor.expectedKey
                            let sampled = monitor.sampledKeys.contains(key)
                            Button {
                                monitor.expectedKey = key
                                selectedMappingKey = key
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: key.symbol).frame(width: 16)
                                    Text(key.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if sampled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(RemotePalette.positive)
                                    }
                                }
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    isSelected ? RemotePalette.indigo.opacity(0.12) : .primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 12)
            } label: {
                HStack {
                    Label("展开未知遥控器底层硬件码采样（Google G9N9N 已内置，日常无需开启）",
                          systemImage: "waveform.path.ecg.rectangle")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(monitor.sampledKeys.count) 键已识别")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(RemotePalette.indigo)
        }
    }

    // MARK: - Helpers

    private func scanHIDDevices() {
        let report = SystemHIDProbe.scanDetailed()
        hidCandidates = report.candidates
        didScanHID = true
        if !hidCandidates.contains(where: { $0.id == selectedCandidateID }) {
            selectedCandidateID = hidCandidates.first(where: \.canSeize)?.id ?? hidCandidates.first?.id
        }
    }

    private func clearSelectedLogs() {
        switch logFilter {
        case .all:
            monitor.clearLogs()
            bluetooth.clearLogs()
            lanRelay.clearLogs()
        case .hid:
            monitor.clearLogs()
        case .voice:
            bluetooth.clearLogs()
        case .lan:
            lanRelay.clearLogs()
        }
        copiedLogs = false
    }

    private func exportLogsToFile() {
        let content = filteredLogLines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MoteFlow-Diagnostics.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
