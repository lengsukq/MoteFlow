import AppKit
import SwiftUI

enum RemoteSettingsSection: String, CaseIterable, Identifiable {
    case daily
    case backup

    var id: String { rawValue }
}

/// Streamlined 2-section Preferences & Unified Backup Center:
/// - Consolidates mappings, named schemes, action library, AND custom learned HID codes
///   into ONE single portable JSON backup format (while transparently importing legacy HID files).
struct RemoteSettingsPage: View {
    @EnvironmentObject private var mappingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @ObservedObject var monitor: HIDCaptureManager
    @ObservedObject var runtime: RemoteAppRuntime
    @ObservedObject var permissionCenter: RemotePermissionCenter
    @Binding var section: RemoteSettingsSection
    let onOpenDualMac: () -> Void
    let onOpenPermissions: () -> Void
    let onReopenGuide: () -> Void

    @State private var backupNoteInput = ""
    @State private var configStatusMessage = ""
    @State private var alertMessage: String?

    @State private var pendingConfigDocument: RemoteConfigBackupDocument?
    @State private var pendingLocalRestoreRecord: RemoteLocalBackupRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            permissionQuickHealthStrip

            RemoteCard(padding: 12) {
                HStack(spacing: 9) {
                    sectionOptionCards
                }
            }

            switch section {
            case .daily:
                dailySettingsCards
            case .backup:
                configBackupAndExportCards
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingConfigDocument != nil },
            set: { if !$0 { pendingConfigDocument = nil } }
        )) {
            if let doc = pendingConfigDocument {
                let hidNote = doc.snapshot.learnedHIDProfile.map { " · 含 \($0.entries.count) 个硬件码" } ?? ""
                RemoteConfigSyncStrategySheet(
                    title: "导入配置文件",
                    sourceLabel: doc.snapshot.sourcePeerName,
                    summaryDetail: "含 \(doc.snapshot.totalConfiguredKeyCount) 项按键、\(doc.snapshot.namedProfiles.count) 个命名方案与 \(doc.snapshot.libraryActions.count) 个动作库条目\(hidNote)"
                ) { strategy in
                    let result = mappingStore.applySyncedSnapshot(
                        doc.snapshot,
                        strategy: strategy,
                        library: actionLibrary,
                        onRestoreHIDProfile: { profile in
                            monitor.applyImportedLearnedProfile(profile)
                        }
                    )
                    configStatusMessage = result.summaryMessage
                    pendingConfigDocument = nil
                }
            }
        }
        .sheet(item: $pendingLocalRestoreRecord) { record in
            RemoteConfigSyncStrategySheet(
                title: "恢复本机快照「\(record.label)」",
                sourceLabel: record.createdAt.formatted(date: .abbreviated, time: .shortened),
                summaryDetail: "含 \(record.configuredKeysCount) 项按键、\(record.namedProfilesCount) 个方案、\(record.libraryActionsCount) 个动作库条目",
                preselectedStrategy: .overwrite
            ) { strategy in
                do {
                    let result = try mappingStore.restoreLocalBackup(
                        record.id,
                        strategy: strategy,
                        library: actionLibrary,
                        onRestoreHIDProfile: { profile in
                            monitor.applyImportedLearnedProfile(profile)
                        }
                    )
                    configStatusMessage = result.summaryMessage
                } catch {
                    alertMessage = error.localizedDescription
                }
            }
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

    private var permissionQuickHealthStrip: some View {
        let missing = permissionCenter.missingCoreCount
        return RemoteCard(padding: 13) {
            HStack(spacing: 12) {
                Image(systemName: missing == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(missing == 0 ? RemotePalette.positive : RemotePalette.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(missing == 0 ? "系统核心权限已全部就绪" : "检测到还有 \(missing) 项核心权限待开启")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已授权 \(permissionCenter.grantedTotalCount)/\(max(permissionCenter.snapshots.count, 6)) 项能力 · 蓝牙、输入监控与辅助功能决定遥控按键能否直接生效")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onOpenPermissions()
                } label: {
                    Label(missing == 0 ? "查看权限详情" : "一键修复权限", systemImage: "checkmark.shield")
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: missing > 0))
            }
        }
    }

    @ViewBuilder
    private var sectionOptionCards: some View {
        RemoteVisualOption(
            title: "日常运行与轻量常驻",
            subtitle: "自动接管与菜单栏后台模式",
            symbol: "gearshape",
            selected: section == .daily,
            compact: true,
            action: { section = .daily }
        )
        RemoteVisualOption(
            title: "全量备份 · 导出与回滚",
            subtitle: "一份 JSON 打包按键、方案、动作库与硬件码",
            symbol: "externaldrive.badge.checkmark",
            selected: section == .backup,
            compact: true,
            action: { section = .backup }
        )
    }

    // MARK: - Daily Settings

    @ViewBuilder
    private var dailySettingsCards: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                RemoteSectionTitle(
                    title: "自动化与按键响应",
                    subtitle: "打开软件后自动接管并生效已配对遥控器，无需每次手动连接",
                    symbol: "bolt.shield"
                )
                Toggle("自动接管已配对遥控器并立即生效按键控制", isOn: Binding(
                    get: { monitor.isRemoteControlActive },
                    set: { monitor.setRemoteControlActive($0) }
                ))
                .toggleStyle(.switch)

                Toggle("自动重连遥控器语音通道（待机不占用系统麦克风）", isOn: $bluetooth.autoVoiceConnectEnabled)
                    .toggleStyle(.switch)

                Divider().opacity(0.45)

                HStack(spacing: 10) {
                    Button {
                        onReopenGuide()
                    } label: {
                        Label("重新展开 30 秒新手引导", systemImage: "sparkles")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        section = .backup
                    } label: {
                        Label("全量备份 / 导出配置", systemImage: "externaldrive.badge.checkmark")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button {
                        onOpenDualMac()
                    } label: {
                        Label("双机协同设置（端口 \(lanRelay.sharedPort)）", systemImage: "macbook.and.ipad")
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
                        title: "菜单栏轻量模式（推荐日常开启）",
                        subtitle: "收起主窗口并隐藏程序坞 Dock 图标，仅保留右上角菜单栏图标静默运行，随时点击可重新唤出",
                        symbol: "menubar.rectangle"
                    )
                    Spacer(minLength: 5)
                    RemoteStatusPill(
                        title: runtime.lightweightModeEnabled ? "轻量模式开启" : "常规窗口模式",
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
                        title: "菜单栏轻量模式",
                        subtitle: "不占桌面与 Dock，屏幕顶部悬浮提示确认收起状态",
                        symbol: "menubar.arrow.up.rectangle",
                        selected: runtime.lightweightModeEnabled,
                        compact: true,
                        action: { runtime.lightweightModeEnabled = true }
                    )
                }

                Button {
                    runtime.enterLightweightMode()
                } label: {
                    Label("现在立即收起到右上角菜单栏", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }

    // MARK: - Unified Full Configuration Backup, Export & Import

    @ViewBuilder
    private var configBackupAndExportCards: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                RemoteSectionTitle(
                    title: "导出与导入统一全量备份（JSON）",
                    subtitle: "单文件打包所有遥控器按键映射、长按阈值、命名方案、动作库与自定义硬件码；同时兼容旧版硬件码文件导入",
                    symbol: "square.and.arrow.up.on.square"
                )

                HStack(spacing: 10) {
                    Button { exportFullConfigToFile() } label: {
                        Label("导出备份文件 (.json)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button { importFullConfigFromFile() } label: {
                        Label("从文件导入 (.json)", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button { copyFullConfigToClipboard() } label: {
                        Label("复制备份 JSON", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Button { importFullConfigFromClipboard() } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    Spacer()
                }

                if !configStatusMessage.isEmpty {
                    Label(configStatusMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.positive)
                }
            }
        }

        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RemoteSectionTitle(
                        title: "本机历史快照与一键回滚",
                        subtitle: "随时保存当前状态；每次执行覆盖同步或覆盖导入前也会自动生成保护快照",
                        symbol: "clock.arrow.circlepath"
                    )
                    Spacer()
                    RemoteStatusPill(
                        title: "\(mappingStore.localBackups.count) 份快照",
                        symbol: "externaldrive.fill.badge.checkmark",
                        tint: RemotePalette.indigo
                    )
                }

                HStack(spacing: 9) {
                    TextField("输入快照备注（可选，不填则按当前时间自动命名）", text: $backupNoteInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { createQuickLocalSnapshot() }

                    Button { createQuickLocalSnapshot() } label: {
                        Label("立即创建快照", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }

                if mappingStore.localBackups.isEmpty {
                    Text("当前暂无本机历史快照。点击上方「立即创建快照」即可一键保存。")
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
                    Text(record.label).font(.system(size: 13, weight: .semibold))
                    if record.isAutomaticSafetyBackup {
                        Text("自动保护")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(RemotePalette.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RemotePalette.amber.opacity(0.14), in: Capsule())
                    }
                }
                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.configuredKeysCount) 项按键 · \(record.namedProfilesCount) 个方案 · \(record.libraryActionsCount) 个动作")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("恢复") {
                pendingLocalRestoreRecord = record
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

    // MARK: - Export / Import Helpers

    private func exportFullConfigToFile() {
        do {
            let data = try mappingStore.exportBackupJSONData(
                peerName: lanRelay.localPeerName,
                note: "手动文件导出",
                library: actionLibrary,
                learnedHIDProfile: monitor.exportLearnedProfile()
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
                    configStatusMessage = "全量备份已导出至：\(url.lastPathComponent)"
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
                library: actionLibrary,
                learnedHIDProfile: monitor.exportLearnedProfile()
            )
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            configStatusMessage = "已将全量备份 JSON 复制到剪贴板。"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importFullConfigFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 MoteFlow 备份文件"
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
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func importFullConfigFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            alertMessage = "剪贴板中没有找到有效的配置文本。"
            return
        }
        do {
            pendingConfigDocument = try RemoteConfigBackupDocument.importJSONData(data)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func createQuickLocalSnapshot() {
        let trimmed = backupNoteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "手动备份 · \(Date().formatted(date: .abbreviated, time: .shortened))" : trimmed
        do {
            let record = try mappingStore.createLocalBackup(
                label: label,
                peerName: lanRelay.localPeerName,
                library: actionLibrary,
                learnedHIDProfile: monitor.exportLearnedProfile()
            )
            backupNoteInput = ""
            configStatusMessage = "已创建本机快照：「\(record.label)」"
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
