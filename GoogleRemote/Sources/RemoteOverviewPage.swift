import AppKit
import SwiftUI

/// Clear, jargon-free connection guide distinguishing macOS Bluetooth pairing,
/// optional BLE voice channel, and Dual-Mac LAN sharing.
struct RemoteOverviewPage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @State private var searchText = ""
    let onOpenDiagnostics: () -> Void
    let onOpenDualMac: () -> Void

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
                VStack(alignment: .leading, spacing: 15) {
                    RemoteSectionTitle(
                        title: "连接指引（3 种连接通道一目了然）",
                        subtitle: "普通按键只需在 macOS 系统设置里配对一次；语音与第二台 Mac 按需启用即可",
                        symbol: "antenna.radiowaves.left.and.right"
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { channelCards }
                        VStack(spacing: 10) { channelCards }
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 12) {
                        RemoteSectionTitle(
                            title: "语音蓝牙设备扫描（仅使用遥控器麦克风时需要）",
                            subtitle: "如果你只需要用遥控器按键而不需要语音说话，无需在此列表连接",
                            symbol: "waveform.badge.mic"
                        )
                        Spacer(minLength: 4)
                        Button {
                            bluetooth.toggleScan()
                        } label: {
                            Label(bluetooth.isScanning ? "停止扫描" : "扫描语音遥控器",
                                  systemImage: bluetooth.isScanning ? "stop.circle" : "arrow.clockwise")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: bluetooth.connectedDeviceID == nil))
                        .disabled(!bluetooth.isBluetoothReady)
                    }

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("按设备名称筛选…", text: $searchText)
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
                    .frame(height: 36)
                    .background(.primary.opacity(0.033), in: RoundedRectangle(cornerRadius: 10))

                    if visibleDevices.isEmpty {
                        Label(
                            bluetooth.isScanning
                                ? "正在搜索附近的 BLE 遥控器，请按一下遥控器任意键唤醒它…"
                                : "列表为空。若要启用遥控器语音，请点击右上角「扫描语音遥控器」并唤醒遥控器。",
                            systemImage: bluetooth.isScanning ? "antenna.radiowaves.left.and.right" : "info.circle"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleDevices) { device in
                                deviceRow(device)
                            }
                        }
                    }

                    HStack {
                        Text("连接遇到问题？可前往硬件诊断检测系统接口与权限。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开硬件诊断", action: onOpenDiagnostics)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var channelCards: some View {
        channelCard(
            title: "1. 普通实体按键",
            status: hidCapture.isExclusive ? "已自动接管" : "等待系统蓝牙配对",
            detail: "在 macOS「系统设置 → 蓝牙」配对遥控器后，本软件会自动接管按键。",
            symbol: "keyboard",
            ready: hidCapture.isExclusive,
            buttonTitle: "打开系统蓝牙"
        ) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                NSWorkspace.shared.open(url)
            }
        }

        channelCard(
            title: "2. 遥控器麦克风语音",
            status: bluetooth.connectedDeviceID != nil ? "语音蓝牙已连接" : "未连接（可选）",
            detail: "在下方扫描并连接 Google 遥控器的语音通道，可将声音传给豆包。",
            symbol: "mic.fill",
            ready: bluetooth.connectedDeviceID != nil,
            buttonTitle: bluetooth.isScanning ? "停止扫描" : "扫描语音蓝牙"
        ) {
            bluetooth.toggleScan()
        }

        channelCard(
            title: "3. 第二台 Mac 共享",
            status: lanRelay.isConnected ? "已连：\(lanRelay.connectedPeerName ?? "远端 Mac")" : "支持局域网自动配对",
            detail: "另一台 Mac 无需再连蓝牙，同一局域网下点击确认配对即可按快捷键切换控制。",
            symbol: "macbook.and.ipad",
            ready: lanRelay.isConnected,
            buttonTitle: "配置双机互联",
            action: onOpenDualMac
        )
    }

    private func channelCard(
        title: String,
        status: String,
        detail: String,
        symbol: String,
        ready: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ready ? RemotePalette.positive : RemotePalette.indigo)
                    .frame(width: 34, height: 34)
                    .background(
                        (ready ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ready ? RemotePalette.positive : .secondary)
                }
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button(buttonTitle, action: action)
                .buttonStyle(RemoteActionButtonStyle())
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
        .background(.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 13))
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let connected = bluetooth.connectedDeviceID == device.id
        return HStack(spacing: 12) {
            Image(systemName: "appletvremote.gen4")
                .font(.system(size: 18))
                .foregroundStyle(connected ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 40, height: 40)
                .background(
                    (connected ? RemotePalette.positive : RemotePalette.indigo).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.system(size: 13, weight: .semibold))
                Text(device.rssi != 0 ? "信号强度 \(device.rssi) dBm" : "已配对语音外设")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 5)
            if connected {
                Button("断开语音连接") { bluetooth.disconnect() }
                    .buttonStyle(RemoteActionButtonStyle())
            } else {
                Button("连接语音通道") { bluetooth.connect(to: device.id) }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(12)
        .background(.primary.opacity(connected ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 12))
    }
}
