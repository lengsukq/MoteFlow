import AppKit
import SwiftUI

enum MappingProfileNameMode {
    case saveAs
    case rename
}

/// Compact toolbar card for managing named button-mapping snapshots without
/// pushing the interactive remote illustration below the fold.
struct RemoteMappingProfileToolbar: View {
    @ObservedObject var store: RemoteBindingStore
    @State private var showingProfileNameSheet = false
    @State private var profileNameMode: MappingProfileNameMode = .saveAs
    @State private var profileNameInput = ""
    @State private var profileNameFeedback: String?
    @State private var pendingProfileSwitchID: UUID?
    @State private var showingProfileSwitchConfirmation = false
    @State private var showingDeleteNamedProfile = false
    @State private var showingApplySideKeys = false
    @State private var showingResetAll = false

    var body: some View {
        RemoteCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        profileSummary
                        Spacer(minLength: 8)
                        profileActions
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        profileSummary
                        profileActions
                    }
                }
            }
        }
        .sheet(isPresented: $showingProfileNameSheet) {
            profileNameEditorSheet
        }
        .confirmationDialog("切换映射方案？", isPresented: $showingProfileSwitchConfirmation) {
            Button("应用并替换当前工作映射") {
                if let id = pendingProfileSwitchID {
                    _ = store.applyNamedProfile(id)
                } else {
                    store.applyFactoryMapping()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("切换将替换当前工作配置，已保存的命名方案与出厂模板不受影响。")
        }
        .confirmationDialog("恢复当前遥控器的出厂默认映射？", isPresented: $showingResetAll) {
            Button("恢复出厂默认", role: .destructive) {
                store.applyFactoryMapping()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("方向键恢复为上下左右移动、确认为回车、返回为 Esc；Google 侧键恢复为复制与粘贴。已保存的自定义方案不会丢失。")
        }
        .confirmationDialog("应用 Google 侧键复制 / 粘贴预设？", isPresented: $showingApplySideKeys) {
            Button("仅替换上下两个侧键") {
                _ = store.applyGoogleSideKeyClipboardPreset()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("上侧键单击复制、长按全选复制；下侧键单击粘贴、长按全选粘贴。其余按键保持不变。")
        }
        .confirmationDialog("删除当前已保存的命名方案？", isPresented: $showingDeleteNamedProfile) {
            Button("删除方案快照", role: .destructive) {
                if let id = store.activeProfileID {
                    _ = store.deleteNamedProfile(id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除该命名快照，当前正在使用的按键映射仍会保留。")
        }
    }

    private var profileSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RemotePalette.indigo)
                .frame(width: 32, height: 32)
                .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("映射方案：\(store.activeNamedProfile?.name ?? "默认工作配置")")
                        .font(.system(size: 13, weight: .semibold))
                    if store.hasUnsavedNamedChanges {
                        Text("有未保存修改")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RemotePalette.amber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RemotePalette.amber.opacity(0.12), in: Capsule())
                    }
                }
                Text("支持按遥控器型号保存多套方案，随时一键切换或恢复出厂设置")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileActions: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    pendingProfileSwitchID = nil
                    showingProfileSwitchConfirmation = true
                } label: {
                    Label("出厂默认（\(store.activeModel.modelLabel)）", systemImage: "checkmark.shield")
                }
                if !store.profilesForActiveModel.isEmpty {
                    Divider()
                    ForEach(store.profilesForActiveModel) { profile in
                        Button {
                            pendingProfileSwitchID = profile.id
                            showingProfileSwitchConfirmation = true
                        } label: {
                            if store.activeProfileID == profile.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            } label: {
                Label("切换方案", systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)

            if store.activeNamedProfile != nil && store.hasUnsavedNamedChanges {
                Button("更新方案") {
                    _ = store.updateActiveNamedProfile()
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }

            Button("另存新方案") {
                profileNameMode = .saveAs
                profileNameInput = ""
                profileNameFeedback = nil
                showingProfileNameSheet = true
            }
            .buttonStyle(RemoteActionButtonStyle())

            Menu {
                if store.activeModel == .googleG9N9N {
                    Button {
                        showingApplySideKeys = true
                    } label: {
                        Label("应用侧键复制/粘贴预设", systemImage: "doc.on.clipboard")
                    }
                }
                if store.activeNamedProfile != nil {
                    Button {
                        profileNameMode = .rename
                        profileNameInput = store.activeNamedProfile?.name ?? ""
                        profileNameFeedback = nil
                        showingProfileNameSheet = true
                    } label: {
                        Label("重命名当前方案", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showingDeleteNamedProfile = true
                    } label: {
                        Label("删除当前方案", systemImage: "trash")
                    }
                    Divider()
                }
                Button(role: .destructive) {
                    showingResetAll = true
                } label: {
                    Label("恢复出厂默认映射", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.bordered)
        }
    }

    private var profileNameEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profileNameMode == .saveAs ? "另存为新的映射方案" : "重命名映射方案")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text("当前型号：\(store.activeModel.name)。保存后可随时在多套方案间切换。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("例如：演示翻页模式 / 视频剪辑模式", text: $profileNameInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitProfileName() }
            if let profileNameFeedback {
                Text(profileNameFeedback)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { showingProfileNameSheet = false }
                    .buttonStyle(.bordered)
                Button("保存") { submitProfileName() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func submitProfileName() {
        let ok: Bool
        switch profileNameMode {
        case .saveAs:
            ok = store.saveAsNamedProfile(profileNameInput)
        case .rename:
            ok = store.activeProfileID.map { store.renameNamedProfile($0, to: profileNameInput) } ?? false
        }
        if ok {
            profileNameFeedback = nil
            showingProfileNameSheet = false
        } else {
            profileNameFeedback = store.profileError ?? "无法保存方案名称"
        }
    }
}

/// Searchable catalog sheet of standard macOS actions and keyboard shortcuts.
struct MacShortcutPickerSheet: View {
    let selectedAction: RemoteAction
    let onSelect: (MacShortcutPreset) -> Void
    let onSelectSwitchMac: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [MacShortcutPreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MacShortcutPreset.all }
        return MacShortcutPreset.all.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.detail.localizedCaseInsensitiveContains(query) ||
            $0.shortcut.display.localizedCaseInsensitiveContains(query) ||
            $0.category.title.localizedCaseInsensitiveContains(query)
        }
    }

    private func shortcuts(in category: MacShortcutCategory) -> [MacShortcutPreset] {
        filtered.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("常用系统功能与快捷键库")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("点选任意一项即可直接绑定到当前按键；截图与复制粘贴优先走 macOS 原生能力")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索功能：截图、复制、粘贴、双机切换、全屏、锁屏…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(11)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if searchText.isEmpty || "双机切换另一台mac转发".localizedCaseInsensitiveContains(searchText) {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("多设备协同", systemImage: "macbook.and.ipad")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RemotePalette.turquoise)
                            Button {
                                onSelectSwitchMac()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(RemotePalette.turquoise)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("切换双机控制目标（本机 ⇄ 另一台 Mac）")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text("按下此遥控器按钮即可在两台已配对的 Mac 之间来回切换控制权")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedAction.kind == .systemAction && selectedAction.systemAction == .switchMacTarget {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(RemotePalette.turquoise)
                                    }
                                }
                                .padding(12)
                                .background(RemotePalette.turquoise.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ForEach(MacShortcutCategory.allCases) { category in
                        if !shortcuts(in: category).isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(category.title, systemImage: category.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RemotePalette.indigo)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 9)], spacing: 9) {
                                    ForEach(shortcuts(in: category)) { preset in
                                        presetCard(preset)
                                    }
                                }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 660, minHeight: 480, idealHeight: 610)
    }

    private func presetCard(_ preset: MacShortcutPreset) -> some View {
        let selected = preset.nativeAction.map {
            selectedAction.kind == .systemAction && selectedAction.systemAction == $0
        } ?? (selectedAction.kind == .keyboardShortcut && selectedAction.shortcut == preset.shortcut)

        return Button {
            onSelect(preset)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RemotePalette.indigo)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(preset.nativeAction == nil ? preset.shortcut.display : "系统原生动作")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RemotePalette.indigo)
                    Text(preset.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RemotePalette.indigo)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .background(
                selected ? RemotePalette.indigo.opacity(0.09) : Color.primary.opacity(0.032),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? RemotePalette.indigo.opacity(0.45) : .primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}
