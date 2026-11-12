import AppKit
import SwiftUI

struct RemoteDiagnosticsPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @State private var hidCandidates: [HIDRemoteCandidate] = []
    @State private var didScanHID = false
    @State private var copiedLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    RemoteSectionTitle(
                        title: "系统全局健康概览",
                        subtitle: "一屏汇总物理 HID 接管、蓝牙语音服务与双机局域网通道状态",
                        symbol: "stethoscope"
                    )
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { overviewMetrics }
                        VStack(spacing: 10) { overviewMetrics }
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteSectionTitle(
                            title: "macOS 系统 HID 接口检测",
                            subtitle: "查看系统蓝牙当前已注册的遥控器硬件接口（VID / PID）",
                            symbol: "keyboard"
                        )
                        Spacer()
                        Button {
                            hidCandidates = SystemHIDProbe.scanCandidates()
                            didScanHID = true
                        } label: {
                            Label("扫描系统 HID", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }

                    if hidCandidates.isEmpty {
                        Text(didScanHID ? "未检测到受支持的遥控器 HID 接口，请先确认系统蓝牙已连接。" : "点击右上角「扫描系统 HID」读取本机外设信息。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ForEach(hidCandidates) { candidate in
                            HStack(spacing: 12) {
                                Image(systemName: "appletvremote.gen4")
                                    .foregroundStyle(RemotePalette.indigo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.productName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(String(format: "VID %04X · PID %04X · %@", candidate.vendorID, candidate.productID, candidate.transport))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(11)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                    RemoteSectionTitle(
                        title: "BLE GATT 服务与语音协议详情",
                        subtitle: "当前蓝牙状态：\(bluetooth.bluetoothState) · \(bluetooth.connectionSummary)",
                        symbol: "antenna.radiowaves.left.and.right"
                    )
                    Text("语音协议协商：\(bluetooth.protocolDetails)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !bluetooth.discoveredServices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(bluetooth.discoveredServices.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        RemoteSectionTitle(
                            title: "实时运行日志（蓝牙 + 局域网双机）",
                            subtitle: "仅保留在当前应用内存中，便于快速定位连接问题",
                            symbol: "text.alignleft"
                        )
                        Spacer()
                        Button {
                            let combined = (bluetooth.logs + lanRelay.logs).joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(combined, forType: .string)
                            copiedLogs = true
                        } label: {
                            Label(copiedLogs ? "已复制" : "复制日志", systemImage: copiedLogs ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(bluetooth.logs.isEmpty && lanRelay.logs.isEmpty)

                        Button("清空") {
                            bluetooth.clearLogs()
                            lanRelay.clearLogs()
                            copiedLogs = false
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(bluetooth.logs.isEmpty && lanRelay.logs.isEmpty)
                    }

                    let allLogs = bluetooth.logs + lanRelay.logs
                    if allLogs.isEmpty {
                        Text("暂无日志记录。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ScrollView {
                            Text(allLogs.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(13)
                        }
                        .frame(height: 210)
                        .background(.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var overviewMetrics: some View {
        RemoteMetric(
            title: "HID 接管",
            value: hidCapture.isExclusive ? "正常独占" : "未接管",
            symbol: "checkmark.shield",
            tint: hidCapture.isExclusive ? RemotePalette.positive : RemotePalette.amber
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
}
