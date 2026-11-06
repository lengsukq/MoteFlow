import AppKit
import SwiftUI

private enum RemoteSettingsSection: String, CaseIterable {
    case daily, advanced
}

struct RemoteSettingsPage: View {
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var runtime: RemoteAppRuntime
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    let onOpenLearning: () -> Void
    let onOpenVoiceSetup: () -> Void

    @State private var section: RemoteSettingsSection = .daily
    @State private var resultMessage = ""
    @State private var alertMessage: String?
    @State private var showResetConfirmation = false
    @State private var pendingImportData: Data?
    @State private var pendingImportProfile: RemoteHIDProfile?
    @State private var showImportConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RemoteCard(padding: 12) {
                HStack(spacing: 9) {
                    RemoteVisualOption(
                        title: "日常运行", subtitle: "连接、权限和安全执行",
                        symbol: "gearshape",
                        selected: section == .daily, compact: true,
                        action: { section = .daily }
                    )
                    RemoteVisualOption(
                        title: "高级与数据", subtitle: "HID 学习、映射备份",
                        symbol: "externaldrive",
                        selected: section == .advanced, compact: true,
                        action: { section = .advanced }
                    )
                }
            }
            if section == .daily {
            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    RemoteSectionTitle(
                        title: "基础设置",
                        subtitle: "日常运行只需要自动匹配和选择是否执行动作",
                        symbol: "gearshape"
                    )
                    Toggle("启动后自动匹配并独占 Google 遥控器", isOn: Binding(
                        get: { monitor.autoSeizeEnabled },
                        set: { enabled in
                            if enabled { monitor.enableAutomaticCapture() }
                            else { monitor.disableAutomaticCapture() }
                        }
                    ))
                    .toggleStyle(.switch)
                    Toggle("允许实体按键执行已绑定的快捷键或脚本", isOn: $monitor.executeHardwareActions)
                        .toggleStyle(.switch)
                    Toggle("自动连接上次的 BLE 遥控器并启用 ATVV 语音接收", isOn: $bluetooth.autoVoiceConnectEnabled)
                        .toggleStyle(.switch)
                    Text(bluetooth.voiceStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("自动拦截只负责读取实体按键；执行动作是独立控制。关闭执行后不会触发脚本。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        RemoteSectionTitle(
                            title: "轻量模式 · 菜单栏常驻",
                            subtitle: "关闭主窗口后仍接收遥控器事件，不占用 Dock 和桌面空间",
                            symbol: "menubar.rectangle"
                        )
                        Spacer(minLength: 5)
                        RemoteStatusPill(
                            title: runtime.lightweightModeEnabled ? "已启用" : "标准窗口",
                            symbol: runtime.lightweightModeEnabled ? "checkmark.circle" : "macwindow",
                            tint: runtime.lightweightModeEnabled ? RemotePalette.positive : RemotePalette.indigo
                        )
                    }
                    Toggle("关闭窗口后自动进入菜单栏轻量模式", isOn: $runtime.lightweightModeEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    HStack(spacing: 9) {
                        RemoteVisualOption(
                            title: "主窗口模式",
                            subtitle: "打开设置与按键映射",
                            symbol: "macwindow",
                            selected: !runtime.lightweightModeEnabled,
                            compact: true,
                            action: { runtime.lightweightModeEnabled = false }
                        )
                        RemoteVisualOption(
                            title: "后台轻量模式",
                            subtitle: "只保留菜单栏和监听",
                            symbol: "menubar.arrow.up.rectangle",
                            selected: runtime.lightweightModeEnabled,
                            compact: true,
                            action: { runtime.lightweightModeEnabled = true }
                        )
                    }
                    Button {
                        runtime.enterLightweightMode()
                    } label: {
                        Label("现在收起到菜单栏", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    Text("菜单栏可查看 HID、BLE、ATVV 状态，暂停拦截或动作执行，重新打开主窗口或彻底退出。收起窗口不是退出程序；Mac 正常退出程序后不会继续监听。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 10) {
                    RemoteSectionTitle(
                        title: "麦克风和豆包输入法",
                        subtitle: "BlackHole 驱动、系统输入切换和语音热键配置已统一到语音工作台",
                        symbol: "mic"
                    )
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(RemotePalette.positive)
                        Text("在一个页面管理设备安装、音频路由和检测，避免多个入口重复设置。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                    }
                    Button {
                        onOpenVoiceSetup()
                    } label: {
                        Label("进入语音设备管理", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }
            }

            } else {
            RemoteCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 22))
                            .foregroundStyle(RemotePalette.indigo)
                            .frame(width: 43, height: 43)
                            .background(RemotePalette.indigo.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("高级功能 · HID 按键学习")
                                .font(.system(size: 15, weight: .semibold))
                            Text("用于适配新型号或修正按键码。完成适配后可关闭，不影响已保存的映射。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        Toggle("启用高级学习", isOn: $monitor.advancedLearningEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help("关闭后隐藏逐键学习，已有映射仍可正常使用")
                    }
                    if monitor.advancedLearningEnabled {
                        HStack(spacing: 11) {
                            RemoteStatusPill(
                                title: "\(monitor.userLearnedCodes.count) 项自定义",
                                symbol: "checkmark.circle",
                                tint: RemotePalette.positive
                            )
                            RemoteStatusPill(
                                title: "\(monitor.factoryCodes.count) 项内置默认",
                                symbol: "square.stack",
                                tint: RemotePalette.indigo
                            )
                            Spacer(minLength: 0)
                            Button {
                                onOpenLearning()
                            } label: {
                                Label("进入按键学习", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        }
                        Label("请先在测试页确认 HID 独占成功，再选择实体按钮进行学习。学习数据只保存在本机，导出后才能提交给开发者作为通用默认映射候选。", systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("高级学习已隐藏。使用内置默认映射或以前保存的自定义映射即可，无需重复学习。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            RemoteCard {
                VStack(alignment: .leading, spacing: 14) {
                    RemoteSectionTitle(
                        title: "按键映射备份与导出",
                        subtitle: "导出原始 HID 按键码，用于后续验证并制作同型号遥控器的默认映射",
                        symbol: "square.and.arrow.up"
                    )
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自定义采集")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(monitor.exportableLearnedCount) / \(mappingStore.activeModel.keys.count) 个按键")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let device = monitor.currentDeviceIdentity ?? monitor.lastLearnedDeviceIdentity {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(device.productName)
                                    .font(.system(size: 12, weight: .medium))
                                Text(String(format: "VID %04X / PID %04X", device.vendorID, device.productID))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("等待识别设备型号")
                                .font(.system(size: 11))
                                .foregroundStyle(RemotePalette.amber)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            saveMappingFile()
                        } label: {
                            Label("导出已学习 JSON", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(monitor.exportableLearnedCount == 0)

                        Button {
                            copyMappingJSON()
                        } label: {
                            Label("复制 JSON", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(monitor.exportableLearnedCount == 0)
                        Button {
                            chooseImportFile()
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        Spacer(minLength: 0)
                    }
                    Text("JSON 仅包含设备型号、VID/PID、传输方式、Report ID 和实际学习的按键码；不包含脚本、快捷键、账号或蓝牙 UUID。重新安装后，在官方默认码表发布前，也可以导入此文件恢复学习结果。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.5)
                    HStack(spacing: 9) {
                        Text("映射来源")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(monitor.factoryCodes.isEmpty ? "尚无该型号的内置默认码表" : "内置默认 + 本机覆盖")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Label(monitor.factoryCodes.isEmpty ? "清除本机学习映射" : "清除覆盖并恢复内置映射",
                              systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!monitor.advancedLearningEnabled || monitor.userLearnedCodes.isEmpty)
                    if !resultMessage.isEmpty {
                        Label(resultMessage, systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            }
        }
        .confirmationDialog("清除本机自定义 HID 映射？",
                            isPresented: $showResetConfirmation) {
            Button("确认清除自定义映射", role: .destructive) {
                monitor.clearUserOverrides()
                resultMessage = monitor.factoryCodes.isEmpty ?
                    "自定义映射已清空；当前没有可用的内置默认码表。" :
                    "已恢复此型号经过验证的内置映射。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("操作只清除本机逐键学习的数据，不影响动作库、已绑定快捷键或脚本。建议先导出 JSON 备份。")
        }
        .confirmationDialog("从 JSON 恢复已学习按键？",
                            isPresented: $showImportConfirmation) {
            Button("确认导入并替换本机学习映射", role: .destructive) {
                guard let data = pendingImportData else { return }
                do {
                    try monitor.importUserProfileData(data)
                    resultMessage = "已恢复 \(monitor.userLearnedCodes.count) 个按键；只在设备型号匹配时才启用。"
                } catch {
                    alertMessage = error.localizedDescription
                }
                pendingImportData = nil
                pendingImportProfile = nil
            }
            Button("取消", role: .cancel) {
                pendingImportData = nil
                pendingImportProfile = nil
            }
        } message: {
            Text("备份设备：\(pendingImportProfile?.device.productName ?? "未知")，共 \(pendingImportProfile?.entries.count ?? 0) 个按键。导入将替换现有本机学习结果，不修改脚本、动作库及系统权限。")
        }
        .alert("导出失败", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "未知错误")
        }
    }

    private func copyMappingJSON() {
        do {
            let data = try monitor.exportLearnedProfileData()
            guard let output = String(data: data, encoding: .utf8) else {
                alertMessage = "JSON 编码失败"
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            resultMessage = "已复制 \(monitor.exportableLearnedCount) 个真实学习按键的 JSON。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func saveMappingFile() {
        let data: Data
        do {
            data = try monitor.exportLearnedProfileData()
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "GoogleRemote-HID-G9N9N-mapping.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                resultMessage = "已保存 \(monitor.exportableLearnedCount) 个真实映射到 \(url.lastPathComponent)。"
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 HID 映射备份"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard url.pathExtension.lowercased() == "json",
                      (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64_000 else {
                    alertMessage = "请选择不超过 64 KB 的 JSON 映射备份。"
                    return
                }
                let data = try Data(contentsOf: url)
                guard data.count <= 64_000 else {
                    alertMessage = "文件过大，拒绝导入。"
                    return
                }
                let profile = try RemoteHIDProfile.importData(data)
                pendingImportData = data
                pendingImportProfile = profile
                showImportConfirmation = true
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}
