import AppKit
import SwiftUI

struct RemoteDiagnosticsPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @State private var hidCandidates: [HIDRemoteCandidate] = []
    @State private var didScanHID = false
    @State private var copiedLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RemoteCard {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .top, spacing: 14) {
                        RemoteSectionTitle(title: "连接详情", subtitle: "系统蓝牙状态及已连接设备",
                                           symbol: "point.3.connected.trianglepath.dotted")
                        Spacer(minLength: 0)
                        RemoteStatusPill(title: bluetooth.connectedDeviceID == nil ? "未连接" : "已连接",
                                         symbol: bluetooth.connectedDeviceID == nil ? "circle.dotted" : "checkmark.circle.fill",
                                         tint: bluetooth.connectedDeviceID == nil ? RemotePalette.amber : RemotePalette.positive)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 20))
                            .foregroundStyle(RemotePalette.indigo)
                            .frame(width: 44, height: 44)
                            .background(RemotePalette.indigo.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(bluetooth.connectionSummary).font(.system(size: 14, weight: .semibold))
                            Text(bluetooth.bluetoothState).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if bluetooth.connectedDeviceID != nil {
                            Button {
                                bluetooth.disconnect()
                            } label: {
                                Label("断开", systemImage: "xmark.circle")
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                        }
                    }
                    .padding(13)
                    .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 14))

                    Divider().opacity(0.45)
                    HStack {
                        Text("ATVV 语音服务").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 8)
                        RemoteStatusPill(title: bluetooth.atvvFound ? "已发现" : "未发现",
                                         symbol: bluetooth.atvvFound ? "checkmark.circle" : "questionmark.circle",
                                         tint: bluetooth.atvvFound ? RemotePalette.positive : .secondary)
                    }
                    HStack {
                        Text("语音协议").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 8)
                        Text(bluetooth.protocolDetails)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteSectionTitle(title: "系统 HID 设备", subtitle: "排查已配对但没有持续广播的遥控器",
                                           symbol: "keyboard")
                        Spacer(minLength: 0)
                        Button {
                            hidCandidates = SystemHIDProbe.scanCandidates()
                            didScanHID = true
                        } label: {
                            Label("检测系统 HID", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }

                    if hidCandidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "keyboard.badge.ellipsis")
                                .font(.system(size: 27, weight: .light))
                                .foregroundStyle(RemotePalette.indigo)
                            Text(didScanHID ? "没有找到匹配的 HID 遥控器" : "尚未检测系统设备")
                                .font(.system(size: 13, weight: .semibold))
                            Text(didScanHID ? "请检查 macOS 蓝牙配对状态，再重新检测。" : "点击右上角按钮读取 macOS 当前注册的 HID 设备。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        ForEach(hidCandidates) { candidate in
                            HStack(spacing: 12) {
                                Image(systemName: "appletvremote.gen4")
                                    .foregroundStyle(RemotePalette.indigo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.productName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(String(format: "VID %04X  ·  PID %04X  ·  %@",
                                                candidate.vendorID, candidate.productID, candidate.transport))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    Label("这里只检测设备信息，不拦截按键。macOS 是否能接收全部按键需要单独验证。", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 15) {
                    RemoteSectionTitle(title: "GATT 服务与特征", subtitle: "显示从当前 BLE 设备读取到的原始 UUID",
                                       symbol: "square.stack.3d.up")
                    if bluetooth.discoveredServices.isEmpty {
                        emptyHint("连接支持 BLE 的设备后，服务与特征会显示在这里。", symbol: "rectangle.stack")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(bluetooth.discoveredServices.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        RemoteSectionTitle(title: "实时诊断日志", subtitle: "仅存储在当前应用进程中",
                                           symbol: "text.alignleft")
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bluetooth.logs.joined(separator: "\n"), forType: .string)
                            copiedLogs = true
                        } label: {
                            Label(copiedLogs ? "已复制" : "复制", systemImage: copiedLogs ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(bluetooth.logs.isEmpty)

                        Button("清空") {
                            bluetooth.clearLogs()
                            copiedLogs = false
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(bluetooth.logs.isEmpty)
                    }
                    if bluetooth.logs.isEmpty {
                        emptyHint("还没有日志记录。设备事件将在此实时更新。", symbol: "text.alignleft")
                    } else {
                        ScrollView {
                            Text(bluetooth.logs.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(15)
                        }
                        .frame(height: 220)
                        .background(.primary.opacity(0.027),
                                    in: RoundedRectangle(cornerRadius: 13))
                        .onChange(of: bluetooth.logs.count) { _, _ in copiedLogs = false }
                    }
                    Label("复制日志前请注意其中可能包含设备名称和 UUID。", systemImage: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func emptyHint(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary).font(.system(size: 12))
            Spacer()
        }
        .padding(18)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
    }
}
