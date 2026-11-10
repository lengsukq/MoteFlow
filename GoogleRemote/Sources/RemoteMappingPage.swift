import AppKit
import SwiftUI

private enum MappingProfileNameMode {
    case saveAs
    case rename
}

struct RemoteMappingPage: View {
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var library: RemoteLibraryStore
    @ObservedObject var monitor: HIDCaptureManager
    @Binding var selected: RemoteKey
    let onOpenLibrary: () -> Void
    @State private var showingRecorder = false
    @State private var showingMacPresetPicker = false
    @State private var presetTarget: RemoteKey = .home
    @State private var presetGesture: RemoteGesture = .tap
    @State private var editingGesture: RemoteGesture = .tap
    @State private var recordingGesture: RemoteGesture = .tap
    @State private var pendingShortcut: RemoteShortcut?
    @State private var pendingTarget: RemoteKey?
    @State private var pendingGesture: RemoteGesture = .tap
    @State private var showingResetAll = false
    @State private var pendingProfileSwitchID: UUID?
    @State private var showingProfileSwitchConfirmation = false
    @State private var showingProfileNameSheet = false
    @State private var profileNameMode: MappingProfileNameMode = .saveAs
    @State private var profileNameInput = ""
    @State private var profileNameFeedback: String?
    @State private var showingDeleteNamedProfile = false
    @State private var showingApplySideKeys = false
    @State private var fileError: String?
    @State private var showUIEventTools = false
    @State private var feedbackKey: RemoteKey?
    @State private var feedbackMessage = "等待点击遥控器图示"
    @State private var feedbackCount = 0
    @State private var feedbackToken = UUID()
    @State private var showExecutionConfirmation = false
    @State private var manualVoiceHoldActive = false
    @State private var executionKey: RemoteKey = .assistant
    @State private var executionGesture: RemoteGesture = .tap
    @EnvironmentObject private var runner: RemoteActionRunner

    private var binding: RemoteBinding { store.binding(for: selected) }
    private var action: RemoteAction { store.action(for: selected, gesture: editingGesture) }
    private var conflictKey: RemoteKey? {
        guard let pendingShortcut, let pendingTarget else { return nil }
        return store.conflictingKey(for: pendingShortcut, excluding: pendingTarget, gesture: pendingGesture)
    }

    private var mappingProfilesPanel: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    RemoteSectionTitle(
                        title: "遥控器映射方案",
                        subtitle: "出厂映射不可覆盖 · 自定义方案可命名保存",
                        symbol: "square.stack.3d.up"
                    )
                    Spacer(minLength: 5)
                    Text("\(store.profilesForActiveModel.count) 套已保存")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(RemotePalette.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeNamedProfile?.name ?? "当前工作映射 · 尚未命名")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.activeNamedProfile == nil
                             ? "正在编辑工作副本；请另存为自己的映射方案"
                             : store.hasUnsavedNamedChanges
                               ? "已修改工作副本，尚未更新已保存的方案"
                               : "与已保存的方案一致")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Menu {
                        Button {
                            pendingProfileSwitchID = nil
                            showingProfileSwitchConfirmation = true
                        } label: {
                            Label("官方默认 · \(store.activeModel.modelLabel)",
                                  systemImage: "checkmark.shield")
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
                }
                HStack(spacing: 9) {
                    Button {
                        profileNameMode = .saveAs
                        profileNameInput = ""
                        profileNameFeedback = nil
                        showingProfileNameSheet = true
                    } label: {
                        Label("另存为新方案", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                    Button {
                        _ = store.updateActiveNamedProfile()
                    } label: {
                        Label("保存当前修改", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(store.activeNamedProfile == nil || !store.hasUnsavedNamedChanges)

                    if store.activeNamedProfile != nil {
                        Menu {
                            Button {
                                profileNameMode = .rename
                                profileNameInput = store.activeNamedProfile?.name ?? ""
                                profileNameFeedback = nil
                                showingProfileNameSheet = true
                            } label: {
                                Label("重命名当前方案", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                showingDeleteNamedProfile = true
                            } label: {
                                Label("删除当前命名方案", systemImage: "trash")
                            }
                        } label: {
                            Label("管理方案", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.system(size: 11))
                if store.activeModel == .googleG9N9N {
                    HStack(spacing: 9) {
                        Text("侧键：上短按复制 / 长按全选复制；下短按粘贴 / 长按全选粘贴")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Button {
                            showingApplySideKeys = true
                        } label: {
                            Label("应用侧键预设", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("方向键出厂设置：单击移动一步，长按连续移动。应用默认只修改工作副本；修改后请另存为新方案，或明确保存到当前已命名方案。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileNameEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(profileNameMode == .saveAs ? "另存为新的遥控器映射方案" : "重命名映射方案")
                .font(.system(size: 18, weight: .semibold))
            Text("当前型号：\(store.activeModel.modelLabel)。名称不能和该型号已保存的方案重复。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("请输入方案名称（最多 40 个字符）", text: $profileNameInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { finishProfileNameEdit() }
            if let profileNameFeedback {
                Text(profileNameFeedback)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { showingProfileNameSheet = false }
                    .buttonStyle(.bordered)
                Button(profileNameMode == .saveAs ? "创建并保存" : "保存名称") {
                    finishProfileNameEdit()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func finishProfileNameEdit() {
        let succeeded: Bool
        switch profileNameMode {
        case .saveAs:
            succeeded = store.saveAsNamedProfile(profileNameInput)
        case .rename:
            succeeded = store.activeProfileID.map {
                store.renameNamedProfile($0, to: profileNameInput)
            } ?? false
        }
        if succeeded {
            profileNameFeedback = nil
            showingProfileNameSheet = false
        } else {
            profileNameFeedback = store.profileError ?? "无法保存映射方案"
        }
    }

    private func bindMacPreset(_ preset: MacShortcutPreset, to key: RemoteKey,
                               gesture: RemoteGesture) {
        if let native = preset.nativeAction {
            store.setSystemAction(native, for: key, gesture: gesture)
        } else {
            bindShortcut(preset.shortcut, to: key, gesture: gesture)
        }
    }

    private var supportsPhysicalHold: Bool {
        guard selected != .assistant, editingGesture == .longPress else { return false }
        if action.kind == .keyboardShortcut { return true }
        if action.kind == .libraryAction,
           let steps = library.steps(for: action), steps.count == 1,
           steps[0].kind == .keyboard, steps[0].shortcut != nil { return true }
        return false
    }

    private var currentActionIsApp: Bool {
        guard action.kind == .libraryAction,
              let steps = library.action(action.presetID)?.steps else { return false }
        return steps.contains(where: { $0.kind == .openApp })
    }

    private var bindingOptions: [RemoteBindingKind] {
        var options: [RemoteBindingKind] = [.keyboardShortcut, .libraryAction, .none]
        if selected != .assistant { options.insert(.systemAction, at: 0) }
        if action.kind == .script { options.append(.script) }
        if action.kind == .voiceInput { options.append(.voiceInput) }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            mappingProfilesPanel
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    visualPanel.frame(minWidth: 302, maxWidth: 420)
                    settingsPanel.frame(minWidth: 360, maxWidth: .infinity)
                }
                VStack(spacing: 14) {
                    visualPanel
                    settingsPanel
                }
            }

            if selected == .assistant {
                RemoteCard {
                    VStack(alignment: .leading, spacing: 11) {
                        RemoteSectionTitle(
                            title: "语音键 · 豆包输入法",
                            subtitle: "快捷键单击或按住模式由用户自行选择",
                            symbol: "mic"
                        )
                        RemoteVoiceTriggerSelector(trigger: $monitor.doubaoShortcutTrigger)
                        Text(monitor.doubaoShortcutTrigger.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                editingGesture = .longPress
                                recordingGesture = .longPress
                                showingRecorder = true
                            } label: {
                                Label("设置豆包快捷键", systemImage: "keyboard")
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            Text("可直接录制，也可手动选择组合键")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Text("豆包仍使用其选择的 Mac 麦克风；此功能只发送快捷键，不会将 Google 遥控器的 ATVV 音频传入豆包。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            RemoteCard {
                DisclosureGroup {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 9)], spacing: 9) {
                        ForEach(store.activeModel.keys) { key in keyChip(key) }
                    }
                    .padding(.top, 11)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "square.grid.3x3")
                            .foregroundStyle(RemotePalette.indigo)
                        Text("全部按键 · 快速选择")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 8)
                        Text("\(store.configuredCount)/\(store.activeModel.keys.count) 已配置")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(RemotePalette.indigo)
            }

            RemoteCard {
                DisclosureGroup(isExpanded: $showUIEventTools) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("仅验证图示点击与长按反馈，不代表收到实体遥控器事件，也不会执行脚本。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button {
                            markTest(key: selected, gesture: editingGesture)
                        } label: {
                            Label("测试当前图示 \(editingGesture.title)", systemImage: "hand.tap")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        Text(feedbackMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } label: {
                    Label("界面交互测试 · 开发工具", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .medium))
                }
                .tint(RemotePalette.indigo)
            }
        }
        .sheet(isPresented: $showingProfileNameSheet) {
            profileNameEditor
        }
        .onChange(of: monitor.activePhysicalKey) { _, key in
            if let key {
                selected = key
            }
        }
        .onAppear {
            if selected == .assistant { editingGesture = .longPress }
        }
        .onChange(of: selected) { _, key in
            if key == .assistant { editingGesture = .longPress }
        }
        .onChange(of: runner.voiceShortcutHeld) { _, held in
            if !held { manualVoiceHoldActive = false }
        }
        .onDisappear {
            if manualVoiceHoldActive {
                runner.endVoiceShortcutHold()
                manualVoiceHoldActive = false
            }
        }
        .sheet(isPresented: $showingRecorder) {
            ShortcutRecorderSheet(
                key: selected,
                gesture: recordingGesture,
                targetDescription: selected == .assistant ? "语音助手 · ATVV 会话快捷键" : nil
            ) { shortcut in
                let target = selected
                let gesture = recordingGesture
                // Dismiss the modal first so the conflict alert can become key.
                DispatchQueue.main.async {
                    bindShortcut(shortcut, to: target, gesture: gesture)
                }
            }
        }
        .sheet(isPresented: $showingMacPresetPicker) {
            MacShortcutPickerSheet(
                selectedAction: store.action(for: presetTarget, gesture: presetGesture)
            ) { preset in
                let key = presetTarget
                let gesture = presetGesture
                showingMacPresetPicker = false
                // Present a shortcut conflict alert only after the sheet closes.
                DispatchQueue.main.async {
                    bindMacPreset(preset, to: key, gesture: gesture)
                }
            }
        }
        .alert("快捷键已经被使用", isPresented: Binding(
            get: { pendingShortcut != nil },
            set: { if !$0 { clearPendingConflict() } }
        )) {
            Button("替换原绑定", role: .destructive) {
                if let pendingShortcut, let pendingTarget {
                    _ = store.setShortcut(pendingShortcut, for: pendingTarget,
                                          gesture: pendingGesture, replaceConflict: true)
                }
                clearPendingConflict()
            }
            Button("保留原设置", role: .cancel) { clearPendingConflict() }
        } message: {
            Text("这组快捷键已经分配给「\(conflictKey?.title ?? "其他按钮")」的\(pendingGesture.title)动作。是否替换？")
        }
        .confirmationDialog(
            "恢复当前遥控器的出厂映射？",
            isPresented: $showingResetAll
        ) {
            Button("恢复出厂映射", role: .destructive) {
                store.applyFactoryMapping()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会替换当前工作配置，但不会删除已命名保存的方案。建议先「另存为新方案」以保留当前修改；出厂映射本身不会被覆盖。")
        }
        .confirmationDialog(
            "应用 Google 遥控器侧键复制 / 粘贴预设？",
            isPresented: $showingApplySideKeys
        ) {
            Button("仅替换上、下两个侧键") {
                _ = store.applyGoogleSideKeyClipboardPreset()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("上侧键单击复制、长按全选并复制；下侧键单击粘贴、长按全选并粘贴。长按粘贴会替换当前可编辑区域的全部选中内容，其余键位与已保存的命名方案不会改变。")
        }
        .confirmationDialog(
            "切换映射方案？",
            isPresented: $showingProfileSwitchConfirmation
        ) {
            Button("应用并替换当前工作映射") {
                if let id = pendingProfileSwitchID {
                    _ = store.applyNamedProfile(id)
                } else {
                    store.applyFactoryMapping()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("切换将覆盖当前工作映射，但不会改变出厂默认和已保存的命名方案。尚未另存或更新的修改会丢失。")
        }
        .confirmationDialog(
            "删除当前已保存的命名方案？",
            isPresented: $showingDeleteNamedProfile
        ) {
            Button("删除命名方案", role: .destructive) {
                if let id = store.activeProfileID {
                    _ = store.deleteNamedProfile(id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除命名方案的快照，当前工作映射仍会保留，出厂方案不受影响。")
        }
        .confirmationDialog("确认真实执行此动作？",
                            isPresented: $showExecutionConfirmation) {
            Button("执行到本机") {
                let selectedAction = store.action(for: executionKey, gesture: executionGesture)
                if executionKey == .assistant, executionGesture == .longPress,
                   let steps = library.steps(for: selectedAction), steps.count == 1,
                   let shortcut = steps.first?.shortcut, steps.first?.kind == .keyboard {
                    if monitor.doubaoShortcutTrigger == .tap {
                        runner.tapVoiceShortcut(shortcut)
                    } else {
                        runner.beginVoiceShortcutHold(shortcut)
                        manualVoiceHoldActive = runner.voiceShortcutHeld
                    }
                } else {
                    runner.test(action: selectedAction,
                                label: "\(executionKey.title) · \(executionGesture.title)",
                                library: library)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(executionKey == .assistant && executionGesture == .longPress
                 ? (monitor.doubaoShortcutTrigger == .tap
                    ? "将单击一次豆包快捷键，不会持续按住；检查豆包是否进入听写模式。使用豆包选择的 Mac 麦克风。"
                    : "将开始按住豆包快捷键，直到你在配置页点击「结束并释放」；不限制测试秒数。使用豆包选择的 Mac 麦克风，不会把遥控器音频传给豆包。")
                 : "将真实执行「\(executionKey.title) · \(executionGesture.title)」的动作。键盘动作会向 macOS 发送按键；本地脚本会以当前用户权限运行，请确保脚本可信。")
        }
        .alert("文件选择失败", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("确定") { fileError = nil }
        } message: {
            Text(fileError ?? "未知错误")
        }
    }

    private var visualPanel: some View {
        RemoteCard {
            VStack(alignment: .center, spacing: 14) {
                HStack {
                    RemoteSectionTitle(
                        title: store.activeModel.name,
                        subtitle: "\(store.activeModel.modelLabel) · 交互式按键图示",
                        symbol: "appletvremote.gen4"
                    )
                }
                if monitor.advancedLearningEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(RemotePalette.indigo)
                        Text("实体按键学习")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 4)
                        Text("\(monitor.learnedCodes.count)/\(store.activeModel.keys.count) 已映射")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 9) {
                        Button {
                            monitor.expectedKey = selected
                            monitor.learningKey = selected
                        } label: {
                            Label(monitor.learningKey == selected
                                  ? "等待按下实体「\(selected.title)」"
                                  : "学习「\(selected.title)」",
                                  systemImage: "record.circle")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(!monitor.isExclusive || monitor.learningKey != nil || selected == .assistant)
                        if monitor.learningKey != nil {
                            Button("取消") { monitor.learningKey = nil }
                                .buttonStyle(RemoteActionButtonStyle())
                        }
                        Spacer(minLength: 0)
                    }
                    if let learned = monitor.learnedCodes[selected] {
                        HStack {
                            Label("\(monitor.userLearnedCodes[selected] != nil ? "自定义" : "内置默认") Report \(learned.reportID) · Code \(learned.code)",
                                  systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(RemotePalette.positive)
                            Spacer(minLength: 5)
                            Button("重新学习") {
                                monitor.forgetLearnedKey(selected)
                                monitor.learningKey = selected
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Text(selected == .assistant
                         ? "语音助手经 ATVV 通道识别，不产生可学习的普通 HID 按键码。请到「语音」开启接收并测试。"
                         : "先选中图示按钮，再点击「学习」并按一次实体键；可在「设置 → 高级功能」隐藏此区域。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .background(RemotePalette.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                }
                RemoteKeyVisual(selected: $selected, store: store,
                                feedbackKey: monitor.highlightedPhysicalKey ?? feedbackKey) { key, gesture in
                    editingGesture = key == .assistant ? .longPress : gesture
                    if showUIEventTools { markTest(key: key, gesture: gesture) }
                }
                    .frame(maxWidth: .infinity)
                HStack(spacing: 9) {
                    Image(systemName: showUIEventTools && feedbackCount > 0 ? "checkmark.circle.fill" : "hand.tap")
                        .foregroundStyle(showUIEventTools && feedbackCount > 0 ? RemotePalette.positive : RemotePalette.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(showUIEventTools ? feedbackMessage : "点击选中单击配置；长按图示按钮可选中长按配置")
                            .font(.system(size: 12, weight: .semibold))
                        Text(showUIEventTools ? "已识别 \(feedbackCount) 次界面操作 · 非实体硬件事件" :
                             "界面测试已收纳在页面底部；点击图示只选择按键，不会执行本机动作")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background((showUIEventTools && feedbackCount > 0 ? RemotePalette.positive : RemotePalette.indigo).opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 13))
                HStack(spacing: 10) {
                    Image(systemName: monitor.activePhysicalKey != nil ? "checkmark.circle.fill" : "waveform.path")
                        .foregroundStyle(monitor.activePhysicalKey != nil ? RemotePalette.positive : RemotePalette.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("实体遥控器反馈")
                            .font(.system(size: 12, weight: .semibold))
                        Text(monitor.lastHardwareFeedback)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RemotePalette.positive.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                Toggle("允许已学习的实体按键自动执行绑定动作", isOn: $monitor.executeHardwareActions)
                    .font(.system(size: 11, weight: .medium))
                    .toggleStyle(.switch)
                    .help("开启后，已学习的实体键松开时将直接执行对应单击/长按绑定，包括脚本。请仅绑定信任的动作。")
                Text("遥控器示意图使用纯 SwiftUI 绘制。实体按键仍需 HID 真机采样，界面点击成功不代表已收到实体遥控器事件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
            }
        }
    }

    private var settingsPanel: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 20) {
                RemoteSectionTitle(
                    title: "按键设置",
                    subtitle: "选中一个按钮后即可配置它的动作",
                    symbol: "slider.horizontal.3"
                )

                HStack(spacing: 13) {
                    Image(systemName: selected.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(RemotePalette.indigo)
                        .frame(width: 57, height: 57)
                        .background(RemotePalette.indigo.opacity(0.095),
                                    in: RoundedRectangle(cornerRadius: 17))
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(selected.location)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: binding.isConfigured ? "已配置" : "未配置",
                        symbol: binding.isConfigured ? "checkmark.circle.fill" : "circle.dotted",
                        tint: binding.isConfigured ? RemotePalette.positive : .secondary
                    )
                }
                .padding(13)
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))

                if selected != .assistant {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("物理触发方式").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("分别配置").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 9) {
                        RemoteVisualOption(
                            title: "单击", subtitle: library.description(for: binding.action(for: .tap)),
                            symbol: "hand.tap", selected: editingGesture == .tap,
                            compact: true, action: { editingGesture = .tap }
                        )
                        RemoteVisualOption(
                            title: "长按", subtitle: library.description(for: binding.action(for: .longPress)),
                            symbol: "hand.point.up.left.fill", selected: editingGesture == .longPress,
                            compact: true, action: { editingGesture = .longPress }
                        )
                    }
                    if selected != .assistant {
                        macShortcutQuickPicker
                    }
                }
                }

                if selected == .assistant {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("语音专用 · ATVV 会话")
                            .font(.system(size: 12, weight: .semibold))
                        Text("语音按键不使用普通 HID 的单击/长按阈值。语音请求开始时触发，ATVV 会话结束时释放；快捷键是「单击」还是「按住」，由豆包设置决定。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if editingGesture == .longPress && selected != .assistant {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("长按判定阈值").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(String(format: "%.2f 秒", binding.effectiveThreshold))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(RemotePalette.indigo)
                        }
                        Slider(value: Binding(
                            get: { binding.effectiveThreshold },
                            set: { store.setLongPressThreshold($0, for: selected) }
                        ), in: 0.2...3, step: 0.05)
                        Text("实体键持续按下超过此时间判定为长按，释放前不触发单击动作。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(selected == .assistant ? "语音会话开始时执行" : "\(editingGesture.title)时执行")
                        .font(.system(size: 12, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 9)], spacing: 9) {
                        ForEach(bindingOptions) { kind in
                            RemoteVisualOption(
                                title: kind.visualTitle,
                                subtitle: kind.visualDetail,
                                symbol: kind.visualSymbol,
                                selected: action.kind == kind,
                                compact: true,
                                action: { store.setKind(kind, for: selected, gesture: editingGesture) }
                            )
                        }
                    }
                    Text("快速绑定")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 9) {
                        RemoteVisualOption(
                            title: "ChatGPT", subtitle: "打开并聚焦输入栏",
                            symbol: "bubble.left.and.text.bubble.right",
                            selected: action.kind == .libraryAction &&
                                      action.presetID == RemoteLibraryStore.chatGPTPresetID,
                            compact: true,
                            action: {
                                store.setLibraryAction(RemoteLibraryStore.chatGPTPresetID,
                                                       for: selected, gesture: editingGesture)
                            }
                        )
                        RemoteVisualOption(
                            title: "打开 App", subtitle: "选择本机应用",
                            symbol: "app.badge",
                            selected: currentActionIsApp && action.presetID != RemoteLibraryStore.chatGPTPresetID,
                            compact: true, action: chooseApplicationForKey
                        )
                    }

                    HStack(spacing: 10) {
                        Image(systemName: action.kind == .keyboardShortcut ? "keyboard" :
                              action.kind == .systemAction ? "gearshape.2" :
                              action.kind == .script ? "terminal" :
                              action.kind == .voiceInput ? "mic" : "minus.circle")
                            .foregroundStyle(RemotePalette.indigo)
                        if action.kind == .keyboardShortcut {
                            RemoteShortcutVisual(shortcut: action.shortcut)
                        } else {
                            Text(library.description(for: action))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 6)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RemotePalette.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                }

                if action.kind == .keyboardShortcut {
                    VStack(alignment: .leading, spacing: 11) {
                        Button {
                            recordingGesture = editingGesture
                            showingRecorder = true
                        } label: {
                            Label(action.shortcut == nil ? "录制单键或组合快捷键" : "重新录制按键",
                                  systemImage: "record.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        Text("通过可视化键盘选择、手动组合左右修饰键，或直接录制实体键。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if selected == .assistant {
                            Label(
                                monitor.doubaoShortcutTrigger == .hold
                                ? "语音专用：开始说话时按下豆包快捷键，遥控器语音会话结束时松开。不使用固定秒数。"
                                : "语音专用：会话开始时仅单击一次快捷键，由豆包自己的单击模式控制听写。",
                                systemImage: "waveform"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(RemotePalette.indigo)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if editingGesture != .longPress || action.effectiveHoldMode == .timed {
                            HStack {
                                Text("目标键按住时长").font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(String(format: "%.2f 秒", action.effectiveHoldSeconds))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(RemotePalette.indigo)
                            }
                            Slider(value: Binding(
                                get: { action.effectiveHoldSeconds },
                                set: { store.setOutputHold($0, for: selected, gesture: editingGesture) }
                            ), in: 0.04...5, step: 0.02)
                            Text("普通按键可以指定 Mac 目标键按住的秒数，与实体遥控器长按阈值互不影响。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if action.kind == .systemAction {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            presetTarget = selected
                            presetGesture = editingGesture
                            showingMacPresetPicker = true
                        } label: {
                            Label(action.systemAction == nil ? "选择 macOS 系统动作" : "更换系统动作",
                                  systemImage: "gearshape.2")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        Menu {
                            ForEach(RemoteSystemAction.allCases) { native in
                                Button {
                                    store.setSystemAction(native, for: selected,
                                                          gesture: editingGesture)
                                } label: {
                                    if action.systemAction == native {
                                        Label(native.title, systemImage: "checkmark")
                                    } else {
                                        Text(native.title)
                                    }
                                }
                            }
                        } label: {
                            Label("从全部原生系统动作中选择", systemImage: "list.bullet")
                        }
                        .buttonStyle(.bordered)
                        Text("截图直接调用 macOS 截图工具；复制、粘贴等通过当前前台 App 的可访问编辑菜单执行。无需依赖预设快捷键，但需要相应系统权限与应用支持。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if action.kind == .script {
                    VStack(alignment: .leading, spacing: 11) {
                        RemoteVisualOption(
                            title: action.scriptPath == nil ? "选择本地脚本" : "更换本地脚本",
                            subtitle: action.scriptPath.map { URL(fileURLWithPath: $0).lastPathComponent } ??
                                "支持 .sh / .zsh / .command / .py",
                            symbol: "doc.badge.gearshape",
                            selected: action.scriptPath != nil,
                            compact: true, action: chooseScript
                        )
                        if let path = action.scriptPath {
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        Text("支持 .sh / .zsh / .command / .py。脚本仅在动作真正触发或明确试运行时，以当前用户权限执行。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if action.kind == .libraryAction {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择可复用动作")
                            .font(.system(size: 12, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                            ForEach(library.actions) { saved in
                                RemoteVisualOption(
                                    title: saved.name, subtitle: saved.summary,
                                    symbol: saved.steps.first?.kind.visualSymbol ?? "square.stack",
                                    selected: action.presetID == saved.id,
                                    compact: true,
                                    action: {
                                        store.setLibraryAction(saved.id, for: selected,
                                                               gesture: editingGesture)
                                    }
                                )
                            }
                        }
                        if let saved = library.action(action.presetID) {
                            ForEach(Array(saved.steps.enumerated()), id: \.element.id) { index, step in
                                HStack {
                                    Text("\(index + 1). \(step.summary)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        } else {
                            Text("动作库中没有此项；先创建动作，再回来选择。")
                                .font(.system(size: 11))
                                .foregroundStyle(RemotePalette.amber)
                        }
                        Label("引用同一动作的所有按键，会在下一次执行时使用动作库的最新内容。", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if action.kind == .voiceInput {
                    Text("语音动作已作为单击或长按预设保存；实体语音键触发仍需 ATVV 真机验收。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if supportsPhysicalHold {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("长按输出方式")
                            .font(.system(size: 12, weight: .semibold))
                        Picker("长按输出方式", selection: Binding(
                            get: { action.effectiveHoldMode },
                            set: { store.setOutputHoldMode($0, for: selected, gesture: .longPress) }
                        )) {
                            ForEach(RemoteOutputHoldMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(action.effectiveHoldMode == .physical
                             ? "超过长按阈值后持续按住目标键；Delete、方向键等普通按键会按 macOS 键盘重复速度连续执行，松开立即停止。Command / Option / Control 快捷键只触发一次以避免误操作。支持单步骤键盘动作库。"
                             : "使用已设置的目标键固定按住时长；实体遥控器释放后执行。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if manualVoiceHoldActive && runner.voiceShortcutHeld {
                        Button {
                            runner.endVoiceShortcutHold()
                            manualVoiceHoldActive = false
                        } label: {
                            Label("结束语音测试并释放快捷键", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        Text("手动测试期间快捷键保持按住，点击上方按钮即可随时结束；离开本页面也会释放。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            markTest(key: selected, gesture: editingGesture)
                        } label: {
                            Label("预览\(editingGesture.title)（不执行）", systemImage: "hand.tap")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        Button {
                            executionKey = selected
                            executionGesture = editingGesture
                            showExecutionConfirmation = true
                        } label: {
                            Label("试运行真实动作", systemImage: "play.fill")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(action.kind == .none || action.kind == .voiceInput ||
                                  (action.kind == .keyboardShortcut && action.shortcut == nil) ||
                                  (action.kind == .systemAction && action.systemAction == nil) ||
                                  (action.kind == .script && action.scriptPath == nil) ||
                                  (action.kind == .libraryAction && library.action(action.presetID) == nil) ||
                                  runner.running)
                    }
                    Text(runner.result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.45)
                HStack {
                    Button {
                        store.reset(selected, gesture: editingGesture)
                    } label: {
                        Label("清除\(editingGesture.title)动作", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(action.kind == .none)
                    Spacer(minLength: 4)
                    Button {
                        showingResetAll = true
                    } label: {
                        Label("恢复出厂映射", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(RemotePalette.amber)
                    Text("图示只用于选择按键。若同型号已有内置码表，或之前学习过，就无需重复学习；需要重新学习时请在「设置」启用高级功能。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RemotePalette.amber.opacity(0.065),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var macShortcutQuickPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("macOS 系统动作与快捷键", systemImage: "gearshape.2")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Button {
                    presetTarget = selected
                    presetGesture = editingGesture
                    showingMacPresetPicker = true
                } label: {
                    Label("查看全部预设", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                ForEach(MacShortcutPreset.popular) { preset in
                    let chosen = preset.nativeAction.map {
                        action.kind == .systemAction && action.systemAction == $0
                    } ?? (action.kind == .keyboardShortcut && action.shortcut == preset.shortcut)
                    Button {
                        bindMacPreset(preset, to: selected, gesture: editingGesture)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(RemotePalette.indigo)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(preset.nativeAction == nil ? preset.shortcut.display : "系统原生调用")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if chosen {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(RemotePalette.indigo)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(chosen ? RemotePalette.indigo.opacity(0.09) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(chosen ? RemotePalette.indigo.opacity(0.48) : .primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("\(preset.title) · \(preset.nativeAction == nil ? preset.shortcut.display : "不依赖快捷键")")
                }
            }
            Text("点击即绑定到当前\(editingGesture.title)；不会立即执行系统动作。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func bindShortcut(_ shortcut: RemoteShortcut, to key: RemoteKey,
                              gesture: RemoteGesture) {
        if store.conflictingKey(for: shortcut, excluding: key, gesture: gesture) == nil {
            _ = store.setShortcut(shortcut, for: key, gesture: gesture)
        } else {
            pendingTarget = key
            pendingShortcut = shortcut
            pendingGesture = gesture
        }
    }

    private func keyChip(_ key: RemoteKey) -> some View {
        let current = store.binding(for: key)
        let active = selected == key
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selected = key
            }
            if showUIEventTools { markTest(key: key, gesture: .tap) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: key.symbol)
                    .foregroundStyle(active ? RemotePalette.indigo : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(library.description(for: current.action(for: .tap)))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 12)
            .background(active ? RemotePalette.indigo.opacity(0.095) : Color.primary.opacity(0.028),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .strokeBorder(active ? RemotePalette.indigo.opacity(0.36) : .primary.opacity(0.055)))
        }
        .buttonStyle(.plain)
        .help("配置 \(key.title)")
    }

    private func clearPendingConflict() {
        pendingShortcut = nil
        pendingTarget = nil
    }

    private func markTest(key: RemoteKey, gesture: RemoteGesture) {
        let id = UUID()
        feedbackToken = id
        feedbackKey = key
        feedbackCount += 1
        feedbackMessage = "界面\(gesture.title)成功：\(key.title) · \(Date().formatted(date: .omitted, time: .standard))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard feedbackToken == id else { return }
            feedbackKey = nil
        }
    }

    private func chooseScript() {
        let key = selected
        let gesture = editingGesture
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "绑定到\(key.title) · \(gesture.title)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard ["sh", "zsh", "command", "py"].contains(url.pathExtension.lowercased()) else {
                fileError = "请选择 .sh、.zsh、.command 或 .py 脚本文件。"
                return
            }
            store.setScript(url.path, for: key, gesture: gesture)
        }
    }

    private func chooseApplicationForKey() {
        let key = selected
        let gesture = editingGesture
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "选择要用遥控器打开的 App"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                fileError = "请选择包含有效 Bundle ID 的 .app 应用程序。"
                return
            }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                       (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                       url.deletingPathExtension().lastPathComponent
            let preset = RemoteLibraryAction(name: "打开 \(name)", steps: [
                RemoteActionStep(kind: .openApp, applicationBundleID: id, applicationName: name)
            ])
            if library.save(preset) {
                store.setLibraryAction(preset.id, for: key, gesture: gesture)
            } else {
                fileError = library.error ?? "保存应用启动动作失败"
            }
        }
    }
}

/// A searchable shortcut catalog that only selects a mapping. The existing
/// explicit "试运行真实动作" confirmation remains the execution boundary.
private struct MacShortcutPickerSheet: View {
    let selectedAction: RemoteAction
    let onSelect: (MacShortcutPreset) -> Void
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
                VStack(alignment: .leading, spacing: 5) {
                    Text("macOS 系统动作与快捷键")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("优先使用系统原生调用；其余仍使用可自定义的快捷键")
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
                TextField("搜索：截图、复制、粘贴、窗口、⌘…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(12)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(MacShortcutCategory.allCases) { category in
                        if !shortcuts(in: category).isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(category.title, systemImage: category.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RemotePalette.indigo)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 9)], spacing: 9) {
                                    ForEach(shortcuts(in: category)) { preset in
                                        let selected = preset.nativeAction.map {
                                            selectedAction.kind == .systemAction && selectedAction.systemAction == $0
                                        } ?? (selectedAction.kind == .keyboardShortcut && selectedAction.shortcut == preset.shortcut)
                                        Button {
                                            onSelect(preset)
                                        } label: {
                                            HStack(alignment: .center, spacing: 10) {
                                                Image(systemName: preset.symbol)
                                                    .font(.system(size: 16, weight: .medium))
                                                    .foregroundStyle(RemotePalette.indigo)
                                                    .frame(width: 23)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(preset.title)
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundStyle(.primary)
                                                    Text(preset.nativeAction == nil ? preset.shortcut.display : "系统原生调用")
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(RemotePalette.indigo)
                                                    Text(preset.detail)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 0)
                                                if selected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(RemotePalette.indigo)
                                                }
                                            }
                                            .padding(12)
                                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                                            .background(selected ? RemotePalette.indigo.opacity(0.09)
                                                        : Color.primary.opacity(0.035),
                                                        in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(selected ? RemotePalette.indigo.opacity(0.45)
                                                              : .primary.opacity(0.06)))
                                        }
                                        .buttonStyle(.plain)
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
            Divider()
            Text("仅保存映射，不立即执行。截图和部分编辑命令不依赖快捷键；其他条目仍使用预设按键。系统原生菜单操作需要辅助功能权限且由前台 App 提供。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 660, minHeight: 480, idealHeight: 620)
    }
}
