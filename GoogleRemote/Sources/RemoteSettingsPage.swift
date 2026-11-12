import AppKit
import SwiftUI

enum RemoteSettingsSection: String, CaseIterable, Identifiable {
    case daily
    case backup
    case advanced

    var id: String { rawValue }
}

struct RemoteSettingsPage: View {
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var runtime: RemoteAppRuntime
    @Binding var section: RemoteSettingsSection
    let onOpenLearning: () -> Void
    let onOpenVoiceSetup: () -> Void
    let onOpenDualMac: () -> Void
    let onOpenPermissions: () -> Void
    let onReopenGuide: () -> Void

    @State private var backupNoteInput = ""
    @State private var configStatusMessage = ""
    @State private var hidResultMessage = ""
    @State private var alertMessage: String?
    @State private var showResetConfirmation = false

    // Full configuration import dialog state
    @State private var pendingConfigDocument: RemoteConfigBackupDocument?
    @State private var showConfigImportDialog = false

    // Local snapshot restore dialog state
    @State private var pendingLocalRestoreRecord: RemoteLocalBackupRecord?
    @State private var showLocalRestoreDialog = false

    // Low-level HID hardware profile import state
    @State private var pendingImportData: Data?
    @State private var pendingImportProfile: RemoteHIDProfile?
    @State private var showImportConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            RemoteCard(padding: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        sectionOptionCards
                    }
                    VStack(spacing: 9) {
                        sectionOptionCards
                    }
                }
            }

            switch section {
            case .daily:
                dailySettingsCards
            case .backup:
                configBackupAndExportCards
            case .advanced:
                advancedSettingsCards
            }
        }
        .confirmationDialog(
            "选择导入配置方式（来源：\(pendingConfigDocument?.snapshot.sourcePeerName ?? "备份文件")）",
            isPresented: $showConfigImportDialog,
            titleVisibility: .visible
        ) {
            Button("合并导入（保留本机已有设置）") {
                applyPendingDocument(strategy: .merge)
            }
            Button("覆盖导入（完全一致 · 自动留存覆盖前备份）", role: .destructive) {
                applyPendingDocument(strategy: .overwrite)
            }
            Button("取消", role: .cancel) {
                pendingConfigDocument = nil
            }
        } message: {
            if let doc = pendingConfigDocument {
                Text("包含 \(doc.snapshot.totalConfiguredKeyCount) 项已设按键、\(doc.snapshot.namedProfiles.count) 个命名方案与 \(doc.snapshot.libraryActions.count) 个动作库条目。")
            }
        }
        .confirmationDialog(
            "恢复本机快照「\(pendingLocalRestoreRecord?.label ?? "")」？",
            isPresented: $showLocalRestoreDialog,
            titleVisibility: .visible
        ) {
            Button("覆盖恢复到此快照状态", role: .destructive) {
                restorePendingLocalRecord(strategy: .overwrite)
            }
            Button("合并补全（不改动当前已有按键）") {
                restorePendingLocalRecord(strategy: .merge)
            }
            Button("取消", role: .cancel) {
                pendingLocalRestoreRecord = nil
            }
        } message: {
            if let record = pendingLocalRestoreRecord {
                Text("创建于 \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · 含 \(record.configuredKeysCount) 项按键、\(record.namedProfilesCount) 个方案、\(record.libraryActionsCount) 个动作库条目。")
            }
        }
        .confirmationDialog("清除本机自定义学习的硬件码？", isPresented: $showResetConfirmation) {
            Button("确认清除", role: .destructive) {
                monitor.clearUserOverrides()
                hidResultMessage = "已恢复内置硬件码映射。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除高级学习采集的原始码，不会删除你的按键动作和动作库。")
        }
        .confirmationDialog("导入 JSON 硬件码备份？", isPresented: $showImportConfirmation) {
            Button("确认导入", role: .destructive) {
                guard let data = pendingImportData else { return }
                do {
                    try monitor.importUserProfileData(data)
                    hidResultMessage = "已导入 \(monitor.userLearnedCodes.count) 个按键硬件码。"
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
            Text("备份型号：\(pendingImportProfile?.device.productName ?? "未知")，共 \(pendingImportProfile?.entries.count ?? 0) 个按键。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private var sectionOptionCards: some View {
        RemoteVisualOption(
            title: "日常运行与快捷入口",
            subtitle: "自动接管、轻量模式与权限总览",
            symbol: "gearshape",
            selected: section == .daily,
            compact: true,
            action: { section = .daily }
        )
        RemoteVisualOption(
            title: "配置备份 · 导出与导入",
            subtitle: "备份按键方案与动作库、导出导入 JSON",
            symbol: "externaldrive.badge.checkmark",
            selected: section == .backup,
            compact: true,
            action: { section = .backup }
        )
        RemoteVisualOption(
            title: "高级硬件码适配",
            subtitle: "未知遥控器采样与底层码备份",
            symbol: "waveform.path.ecg.rectangle",
            selected: section == .advanced,
            compact: true,
            action: { section = .advanced }
        )
    }

    // MARK: - Daily Settings

    @ViewBuilder
    private var dailySettingsCards: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                RemoteSectionTitle(
                    title: "自动化与执行控制",
                    subtitle: "打开软件后无需手动干预，自动接管已配对遥控器并按需响应",
                    symbol: "bolt.shield"
                )
                Toggle("发现已配对遥控器时自动接管按键", isOn: Binding(
                    get: { monitor.autoSeizeEnabled },
                    set: { $0 ? monitor.enableAutomaticCapture() : monitor.disableAutomaticCapture() }
                ))
                .toggleStyle(.switch)

                Toggle("允许实体遥控器按键执行绑定的快捷键、系统动作与脚本", isOn: $monitor.executeHardwareActions)
                    .toggleStyle(.switch)

                Toggle("自动重连遥控器语音服务（平时待机不占用麦克风）", isOn: $bluetooth.autoVoiceConnectEnabled)
                    .toggleStyle(.switch)

                Divider().opacity(0.45)

                HStack(spacing: 10) {
                    Button {
                        onOpenPermissions()
                    } label: {
                        Label("系统权限总览与引导", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button {
                        section = .backup
                    } label: {
                        Label("备份 / 导出导入配置", systemImage: "externaldrive.badge.checkmark")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        onOpenDualMac()
                    } label: {
                        Label("配置双机互联（端口 \(lanRelay.sharedPort)）", systemImage: "macbook.and.ipad")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        onReopenGuide()
                    } label: {
                        Label("3 步新手引导", systemImage: "sparkles")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    Spacer()
                }
            }
            .font(.system(size: 12))
        }

        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "菜单栏轻量模式（后台静默运行）",
                        subtitle: "关闭主窗口后自动隐藏 Dock 图标，仅保留右上角菜单栏小图标继续监听遥控器与双机快捷键",
                        symbol: "menubar.rectangle"
                    )
                    Spacer(minLength: 5)
                    RemoteStatusPill(
                        title: runtime.lightweightModeEnabled ? "轻量模式已开启" : "常规窗口模式",
                        symbol: runtime.lightweightModeEnabled ? "checkmark.circle.fill" : "macwindow",
                        tint: runtime.lightweightModeEnabled ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                HStack(spacing: 9) {
                    RemoteVisualOption(
                        title: "常规窗口模式",
                        subtitle: "保留在程序坞 Dock 中",
                        symbol: "macwindow",
                        selected: !runtime.lightweightModeEnabled,
                        compact: true,
                        action: { runtime.lightweightModeEnabled = false }
                    )
                    RemoteVisualOption(
                        title: "菜单栏轻量模式（推荐日常使用）",
                        subtitle: "不占桌面与 Dock，随时从菜单栏呼出",
                        symbol: "menubar.arrow.up.rectangle",
                        selected: runtime.lightweightModeEnabled,
                        compact: true,
                        action: { runtime.lightweightModeEnabled = true }
                    )
                }

                Button {
                    runtime.enterLightweightMode()
                } label: {
                    Label("现在立即收起到菜单栏", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    // MARK: - Full Configuration Backup, Export & Import

    @ViewBuilder
    private var configBackupAndExportCards: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                RemoteSectionTitle(
                    title: "导出与导入全量配置文件（JSON）",
                    subtitle: "打包导出所有遥控器按键映射、长按阈值、命名方案与动作库；导入时支持自由选择「合并」或「覆盖」",
                    symbol: "square.and.arrow.up.on.square"
                )

                HStack(spacing: 10) {
                    Button {
                        exportFullConfigToFile()
                    } label: {
                        Label("导出备份文件 (.json)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button {
                        importFullConfigFromFile()
                    } label: {
                        Label("从文件导入配置 (.json)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button {
                        copyFullConfigToClipboard()
                    } label: {
                        Label("复制配置 JSON", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        importFullConfigFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Spacer()
                }

                if !configStatusMessage.isEmpty {
                    Label(configStatusMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.positive)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(RemotePalette.indigo)
                        .font(.system(size: 11))
                    Text("如果两台 Mac 在同一局域网已连接，也可以直接去「双机互联」点击一键合并或覆盖同步，无需手动传文件。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("前往双机同步") {
                        onOpenDualMac()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }

        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "本机快速快照备份与一键回滚",
                        subtitle: "随时保存当前按键状态（每次执行「覆盖导入」或「覆盖同步」前也会自动创建保护快照）",
                        symbol: "clock.arrow.circlepath"
                    )
                    Spacer()
                    RemoteStatusPill(
                        title: "\(mappingStore.localBackups.count) 份本机快照",
                        symbol: "externaldrive.fill.badge.checkmark",
                        tint: RemotePalette.indigo
                    )
                }

                HStack(spacing: 9) {
                    TextField("输入备份备注（可选，例如：剪辑工作流按键方案）", text: $backupNoteInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { createQuickLocalSnapshot() }

                    Button {
                        createQuickLocalSnapshot()
                    } label: {
                        Label("立即备份当前配置", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }

                if mappingStore.localBackups.isEmpty {
                    Text("当前暂无本机历史快照。点击上方「立即备份当前配置」即可一键保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 11))
                } else {
                    VStack(spacing: 8) {
                        ForEach(mappingStore.localBackups) { record in
                            localBackupRow(record)
                        }
                    }
                }
            }
        }
    }

    private func localBackupRow(_ record: RemoteLocalBackupRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.isAutomaticSafetyBackup ? "shield.lefthalf.filled" : "archivebox.fill")
                .foregroundStyle(record.isAutomaticSafetyBackup ? RemotePalette.amber : RemotePalette.indigo)
                .frame(width: 34, height: 34)
                .background(
                    (record.isAutomaticSafetyBackup ? RemotePalette.amber : RemotePalette.indigo).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.label)
                        .font(.system(size: 13, weight: .semibold))
                    if record.isAutomaticSafetyBackup {
                        Text("自动保护")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RemotePalette.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RemotePalette.amber.opacity(0.14), in: Capsule())
                    }
                }
                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.configuredKeysCount) 项按键 · \(record.namedProfilesCount) 个命名方案 · \(record.libraryActionsCount) 个动作库条目")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("恢复") {
                pendingLocalRestoreRecord = record
                showLocalRestoreDialog = true
            }
            .buttonStyle(RemoteActionButtonStyle(emphasized: true))

            Button {
                mappingStore.deleteLocalBackup(record.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(RemoteActionButtonStyle())
            .help("删除此本地快照")
        }
        .padding(11)
        .background(.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Advanced Hardware Code Adaptation

    @ViewBuilder
    private var advancedSettingsCards: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RemoteSectionTitle(
                        title: "高级功能 · 未知遥控器硬件码学习",
                        subtitle: "Google G9N9N 已内置完整按键码，日常无需开启；仅在适配新遥控器型号时使用",
                        symbol: "waveform.path.ecg.rectangle"
                    )
                    Spacer()
                    Toggle("启用高级学习", isOn: $monitor.advancedLearningEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if monitor.advancedLearningEnabled {
                    HStack(spacing: 10) {
                        RemoteStatusPill(title: "\(monitor.userLearnedCodes.count) 项自定义硬件码", symbol: "checkmark.circle", tint: RemotePalette.positive)
                        Spacer()
                        Button {
                            onOpenLearning()
                        } label: {
                            Label("进入逐键采样实验室", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                }
            }
        }

        RemoteCard {
            VStack(alignment: .leading, spacing: 13) {
                RemoteSectionTitle(
                    title: "底层 HID 硬件码备份与导入（仅自定义采样码）",
                    subtitle: "导出高级学习采集的原始 HID 报告编码；如需备份按键功能与动作库，请切换到上方「配置备份 · 导出与导入」",
                    symbol: "cpu"
                )
                HStack(spacing: 10) {
                    Button {
                        saveHIDMappingFile()
                    } label: {
                        Label("导出硬件码 JSON", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    .disabled(monitor.exportableLearnedCount == 0)

                    Button {
                        copyHIDMappingJSON()
                    } label: {
                        Label("复制硬件码 JSON", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(monitor.exportableLearnedCount == 0)

                    Button {
                        chooseHIDImportFile()
                    } label: {
                        Label("导入硬件码", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button("清除本机覆盖") {
                        showResetConfirmation = true
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!monitor.advancedLearningEnabled || monitor.userLearnedCodes.isEmpty)
                    Spacer()
                }
                if !hidResultMessage.isEmpty {
                    Text(hidResultMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(RemotePalette.indigo)
                }
            }
        }
    }

    // MARK: - Full Config Export / Import Actions

    private func exportFullConfigToFile() {
        do {
            let data = try mappingStore.exportBackupJSONData(
                peerName: lanRelay.localPeerName,
                note: "手动文件导出",
                library: actionLibrary
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "MoteFlow-Backup-\(formatter.string(from: Date())).json"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    configStatusMessage = "配置备份已导出至：\(url.lastPathComponent)"
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func copyFullConfigToClipboard() {
        do {
            let data = try mappingStore.exportBackupJSONData(
                peerName: lanRelay.localPeerName,
                note: "剪贴板复制导出",
                library: actionLibrary
            )
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            configStatusMessage = "已将全量配置 JSON 复制到剪贴板，可直接发给另一台 Mac 导入。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importFullConfigFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 MoteFlow 配置备份文件"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= RemoteConfigBackupDocument.maxImportBytes else {
                    alertMessage = RemoteConfigBackupError.fileTooLarge(size).localizedDescription
                    return
                }
                let data = try Data(contentsOf: url)
                pendingConfigDocument = try RemoteConfigBackupDocument.importJSONData(data)
                showConfigImportDialog = true
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func importFullConfigFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            alertMessage = "剪贴板中没有找到文本内容，请先复制 MoteFlow 配置 JSON。"
            return
        }
        do {
            pendingConfigDocument = try RemoteConfigBackupDocument.importJSONData(data)
            showConfigImportDialog = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyPendingDocument(strategy: RemoteConfigSyncStrategy) {
        guard let doc = pendingConfigDocument else { return }
        let result = mappingStore.applySyncedSnapshot(
            doc.snapshot,
            strategy: strategy,
            library: actionLibrary
        )
        configStatusMessage = result.summaryMessage
        pendingConfigDocument = nil
    }

    private func createQuickLocalSnapshot() {
        let trimmed = backupNoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "手动备份 · \(Date().formatted(date: .abbreviated, time: .shortened))" : trimmed
        do {
            let record = try mappingStore.createLocalBackup(
                label: label,
                peerName: lanRelay.localPeerName,
                library: actionLibrary
            )
            backupNoteInput = ""
            configStatusMessage = "已创建本机快照：「\(record.label)」"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func restorePendingLocalRecord(strategy: RemoteConfigSyncStrategy) {
        guard let record = pendingLocalRestoreRecord else { return }
        do {
            let result = try mappingStore.restoreLocalBackup(
                record.id,
                strategy: strategy,
                library: actionLibrary
            )
            configStatusMessage = result.summaryMessage
        } catch {
            alertMessage = error.localizedDescription
        }
        pendingLocalRestoreRecord = nil
    }

    // MARK: - Low-Level HID Profile Helpers

    private func copyHIDMappingJSON() {
        do {
            let data = try monitor.exportLearnedProfileData()
            guard let output = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            hidResultMessage = "已复制 \(monitor.exportableLearnedCount) 个按键映射 JSON。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func saveHIDMappingFile() {
        do {
            let data = try monitor.exportLearnedProfileData()
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "MoteFlow-HID-mapping.json"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    hidResultMessage = "已保存到 \(url.lastPathComponent)。"
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func chooseHIDImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 HID 映射 JSON"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard url.pathExtension.lowercased() == "json",
                      (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64_000 else {
                    alertMessage = "请选择不超过 64 KB 的 JSON 文件。"
                    return
                }
                let data = try Data(contentsOf: url)
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
