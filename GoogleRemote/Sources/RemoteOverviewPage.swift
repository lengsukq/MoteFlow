import SwiftUI

/// Connection is a subpage of the remote workbench, not a separate dashboard.
/// BLE voice and system HID interception are deliberately shown separately.
struct RemoteOverviewPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @State private var searchText = ""
    let onOpenDiagnostics: () -> Void

    private var visibleDevices: [RemoteDevice] {
        bluetooth.devices.filter { device in
            searchText.isEmpty ||
            device.name.localizedStandardContains(searchText) ||
            device.id.uuidString.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteSectionTitle(
                        title: "连接状态",
                        subtitle: "系统 HID 用于实体按键，App 蓝牙 BLE 用于 ATVV 语音；两条链路分别管理",
                        symbol: "antenna.radiowaves.left.and.right"
                    )
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { connectionMetrics }
                        VStack(spacing: 10) { connectionMetrics }
                    }
                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(RemotePalette.indigo)
                        Text(hidCapture.isExclusive
                             ? "实体遥控器已由系统 HID 独占接管，普通按键无需再通过 BLE 设备列表连接。"
                             : "如果已配对但看不到 HID，请到诊断检查系统权限与接口状态。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("打开诊断") { onOpenDiagnostics() }
                            .buttonStyle(.link)
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteSectionTitle(
                            title: "蓝牙设备",
                            subtitle: "仅在使用 ATVV 语音服务或诊断 BLE 时需要连接",
                            symbol: "dot.radiowaves.left.and.right"
                        )
                        Spacer(minLength: 4)
                        Button {
                            bluetooth.toggleScan()
                        } label: {
                            Label(bluetooth.isScanning ? "停止扫描" : "扫描设备",
                                  systemImage: bluetooth.isScanning ? "stop.circle" : "arrow.clockwise")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: bluetooth.connectedDeviceID == nil))
                        .disabled(!bluetooth.isBluetoothReady)
                    }
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索遥控器名称或 UUID", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 39)
                    .background(.primary.opacity(0.033), in: RoundedRectangle(cornerRadius: 10))

                    if visibleDevices.isEmpty {
                        Label(bluetooth.isScanning ? "正在搜索附近设备，请唤醒遥控器" :
                              "当前没有 BLE 广播设备。已配对 HID 遥控器不一定继续广播。",
                              systemImage: bluetooth.isScanning ? "antenna.radiowaves.left.and.right" : "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(17)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleDevices) { device in deviceRow(device) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionMetrics: some View {
        compactMetric(
            title: "实体按键 HID",
            value: hidCapture.isExclusive ? "正在独占" : "未独占",
            symbol: "keyboard",
            isPositive: hidCapture.isExclusive
        )
        compactMetric(
            title: "语音 BLE",
            value: bluetooth.connectedDeviceID != nil ? "已连接" : "未连接",
            symbol: "waveform",
            isPositive: bluetooth.connectedDeviceID != nil
        )
        compactMetric(
            title: "ATVV 语音服务",
            value: bluetooth.voiceModeEnabled ? "已开启" : "待开启",
            symbol: "mic",
            isPositive: bluetooth.voiceModeEnabled
        )
    }

    private func compactMetric(title: String, value: String, symbol: String, isPositive: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(isPositive ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 40, height: 40)
                .background((isPositive ? RemotePalette.positive : RemotePalette.indigo).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let connected = bluetooth.connectedDeviceID == device.id
        return HStack(spacing: 12) {
            Image(systemName: "appletvremote.gen4")
                .font(.system(size: 19))
                .foregroundStyle(connected ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 42, height: 42)
                .background((connected ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).font(.system(size: 13, weight: .semibold))
                Text(device.id.uuidString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 5)
            if device.rssi != 0 {
                Text("\(device.rssi) dBm")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if connected {
                Button("断开 BLE") { bluetooth.disconnect() }
                    .buttonStyle(RemoteActionButtonStyle())
            } else {
                Button("连接 BLE") { bluetooth.connect(to: device.id) }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(12)
        .background(.primary.opacity(connected ? 0.055 : 0.025),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
