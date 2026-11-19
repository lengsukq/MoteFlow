import AppKit
import SwiftUI

/// Unified WYSIWYG Remote Workbench:
/// - Automatically locks & follows the connected physical remote model when hardware is seized
///   (only exposing manual preview switching when offline so newcomers never trigger mismatch errors)
/// - Consolidates scripts into the unified Action Library
struct RemoteMappingPage: View {
    @ObservedObject var store: RemoteBindingStore
    @ObservedObject var library: RemoteLibraryStore
    @ObservedObject var monitor: HIDCaptureManager
    @Binding var selected: RemoteKey
    let onOpenLibrary: () -> Void
    var onOpenConnection: (() -> Void)? = nil

    @EnvironmentObject private var runner: RemoteActionRunner
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editingGesture: RemoteGesture = .tap
    @State private var recordingGesture: RemoteGesture = .tap
    @State private var showingRecorder = false
    @State private var showingMacPresetPicker = false
    @State private var pendingShortcut: RemoteShortcut?
    @State private var pendingTarget: RemoteKey?
    @State private var pendingGesture: RemoteGesture = .tap
    @State private var showAllKeysGrid = false
    @State private var showExecutionConfirmation = false
    @State private var manualVoiceHoldActive = false
    @State private var uiClickFlash: RemoteKey?
    @State private var uiClickToken = UUID()
    @State private var presetHint: String?
    @State private var fileError: String?

    private var binding: RemoteBinding { store.binding(for: selected) }
    private var action: RemoteAction { store.action(for: selected, gesture: editingGesture) }

    private var hardwareModel: RemoteDeviceModel? {
        guard let device = monitor.currentDeviceIdentity else { return nil }
        return RemoteDeviceProfileRegistry.identify(
            vendorID: device.vendorID,
            productID: device.productID,
            productName: device.productName
        )
    }

    private var conflictKey: RemoteKey? {
        guard let pendingShortcut, let pendingTarget else { return nil }
        return store.conflictingKey(for: pendingShortcut, excluding: pendingTarget, gesture: pendingGesture)
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
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if lanRelay.isUsingPeerMappingForSession {
                borrowedPeerMappingBanner
            }
            starterScenesAndModelBar
            RemoteMappingProfileToolbar(store: store)

            HStack(alignment: .top, spacing: 16) {
                leftRemotePreviewCard
                    .frame(minWidth: 306, maxWidth: 380)
                rightConfigurationCard
                    .frame(minWidth: 360, maxWidth: .infinity)
            }

            allKeysQuickGridCard
        }
        .onAppear {
            if let hardwareModel, store.activeModel != hardwareModel {
                store.selectModel(hardwareModel)
            }
            if selected == .assistant { editingGesture = .longPress }
        }
        .onChange(of: monitor.hardwareEventSequence) { _, _ in
            if let key = monitor.activePhysicalKey ?? monitor.highlightedPhysicalKey {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                    selected = key
                }
            }
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
                targetDescription: selected == .assistant ? "语音助手 · 听写热键" : nil
            ) { shortcut in
                let target = selected
                let gesture = recordingGesture
                DispatchQueue.main.async {
                    bindShortcut(shortcut, to: target, gesture: gesture)
                }
            }
        }
        .sheet(isPresented: $showingMacPresetPicker) {
            MacShortcutPickerSheet(
                selectedAction: action,
                onSelect: { preset in
                    let target = selected
                    let gesture = editingGesture
                    showingMacPresetPicker = false
                    DispatchQueue.main.async {
                        bindMacPreset(preset, to: target, gesture: gesture)
                    }
                },
                onSelectSwitchMac: {
                    store.setSystemAction(.switchMacTarget, for: selected, gesture: editingGesture)
                    showingMacPresetPicker = false
                }
            )
        }
        .alert("快捷键冲突提示", isPresented: Binding(
            get: { pendingShortcut != nil },
            set: { if !$0 { clearPendingConflict() } }
        )) {
            Button("替换到当前按键", role: .destructive) {
                if let pendingShortcut, let pendingTarget {
                    _ = store.setShortcut(
                        pendingShortcut,
                        for: pendingTarget,
                        gesture: pendingGesture,
                        replaceConflict: true
                    )
                }
                clearPendingConflict()
            }
            Button("取消", role: .cancel) { clearPendingConflict() }
        } message: {
            Text("快捷键已被「\(conflictKey?.title ?? "其他按键")」的\(pendingGesture.title)使用，是否移到当前按键？")
        }
        .confirmationDialog("立即在本机试运行此动作？", isPresented: $showExecutionConfirmation) {
            Button("确认试运行") { runCurrentActionTest() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将真实触发「\(selected.title) · \(editingGesture.title)」所绑定的功能。")
        }
        .alert("选择失败", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("确定") { fileError = nil }
        } message: {
            Text(fileError ?? "未知错误")
        }
    }

    // MARK: - Active Session Peer-Mapping Borrow Banner

    private var borrowedPeerMappingBanner: some View {
        RemoteCard(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RemotePalette.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前联机正在复用「\(lanRelay.activeMappingOwnerName)」的键位方案")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("联机期间按对端标准执行且不覆盖本机配置；断开联机后自动恢复下方本机配置。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("切回本机方案") {
                    lanRelay.setMappingFollowSource(.followLocalMac)
                }
                .buttonStyle(RemoteActionButtonStyle())
            }
        }
    }

    // MARK: - Top Starter Scene Presets & Auto-Following Hardware Badge

    private var starterScenesAndModelBar: some View {
        RemoteCard(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    starterSceneChips
                    Spacer(minLength: 8)
                    modelHeaderBadgeOrPicker
                }
                if let presetHint {
                    Text(presetHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.positive)
                }
            }
        }
    }

    private var starterSceneChips: some View {
        HStack(spacing: 7) {
            Label("一键场景预设：", systemImage: "wand.and.stars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(RemoteStarterScenePreset.allCases) { preset in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        store.applyStarterScene(preset)
                        presetHint = "已套用「\(preset.title)」：\(preset.subtitle)"
                    }
                } label: {
                    Label(preset.title, systemImage: preset.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RemotePalette.indigo.opacity(0.085), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(RemotePalette.indigo)
                }
                .buttonStyle(.plain)
                .help(preset.subtitle)
            }
        }
    }

    private var modelHeaderBadgeOrPicker: some View {
        HStack(spacing: 8) {
            Text("已配 \(store.configuredCount)/\(store.activeModel.keys.count) 键")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            if let hardwareModel {
                // Auto-locked to the connected physical remote so newcomers cannot accidentally switch models
                RemoteStatusPill(
                    title: hardwareModel.name,
                    symbol: "appletvremote.gen4",
                    tint: RemotePalette.positive
                )
            } else {
                // Offline preview mode: allow inspecting built-in remote layouts
                Menu {
                    ForEach(RemoteDeviceProfileRegistry.builtIn) { model in
                        Button {
                            store.selectModel(model)
                            if !model.keys.contains(selected) { selected = .select }
                        } label: {
                            if store.activeModel == model {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "appletvremote.gen4")
                        Text("预览：\(store.activeModel.name)")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Left Interactive Remote Canvas

    private var leftRemotePreviewCard: some View {
        RemoteCard {
            VStack(alignment: .center, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按手中遥控器或点选按键")
                            .font(.system(size: 14, weight: .semibold))
                        Text("按实体键实时波纹跟选 · 改完再按当场测试")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onOpenConnection, !monitor.isExclusive {
                        Button("连接指引", action: onOpenConnection)
                            .buttonStyle(RemoteActionButtonStyle())
                    } else {
                        RemoteStatusPill(
                            title: monitor.isExclusive ? "真机已接管" : "预览画布",
                            symbol: monitor.isExclusive ? "checkmark.circle.fill" : "hand.tap",
                            tint: monitor.isExclusive ? RemotePalette.positive : RemotePalette.indigo
                        )
                    }
                }

                if monitor.advancedLearningEnabled {
                    inlineLearningBar
                }

                RemoteKeyVisual(
                    selected: $selected,
                    store: store,
                    feedbackKey: monitor.highlightedPhysicalKey ?? uiClickFlash
                ) { key, gesture in
                    editingGesture = key == .assistant ? .longPress : gesture
                    flashUIPreview(key)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 9) {
                    Image(systemName: monitor.activePhysicalKey != nil ? "bolt.circle.fill" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(monitor.activePhysicalKey != nil ? RemotePalette.positive : RemotePalette.indigo)
                    Text(monitor.lastHardwareFeedback)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 11))

                Toggle("允许实体遥控器立即触发动作", isOn: $monitor.executeHardwareActions)
                    .font(.system(size: 12, weight: .medium))
                    .toggleStyle(.switch)
            }
        }
    }

    private func flashUIPreview(_ key: RemoteKey) {
        let token = UUID()
        uiClickToken = token
        uiClickFlash = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard uiClickToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                uiClickFlash = nil
            }
        }
    }

    private var inlineLearningBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("高级硬件码学习", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let learned = monitor.learnedCodes[selected] {
                    Text("R\(learned.reportID) · C\(learned.code)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RemotePalette.positive)
                }
            }
            HStack(spacing: 8) {
                Button {
                    monitor.expectedKey = selected
                    monitor.learningKey = selected
                } label: {
                    Text(monitor.learningKey == selected ? "请按下实体「\(selected.title)」…" : "学习此实体键")
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                .disabled(!monitor.isExclusive || monitor.learningKey != nil || selected == .assistant)

                if monitor.learningKey != nil {
                    Button("取消") { monitor.learningKey = nil }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                Spacer()
            }
        }
        .padding(11)
        .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Right Streamlined Configuration Panel

    private var rightConfigurationCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 18) {
                selectedKeyHeader

                if selected == .assistant {
                    assistantDedicatedSection
                } else {
                    gesturePickerSection
                    quickPresetsSection
                }

                actionKindAndDetailSection

                if supportsPhysicalHold {
                    physicalHoldSection
                }

                bottomTestAndResetBar
            }
        }
    }

    private var selectedKeyHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selected.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(RemotePalette.indigo)
                .frame(width: 50, height: 50)
                .background(RemotePalette.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(selected.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("\(selected.location) · 单击、双击和长按可分别绑定不同动作")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RemoteStatusPill(
                title: binding.isConfigured ? "已配置" : "未设置",
                symbol: binding.isConfigured ? "checkmark.circle.fill" : "circle.dotted",
                tint: binding.isConfigured ? RemotePalette.positive : .secondary
            )
        }
        .padding(12)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private var gesturePickerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("1. 选择触发手势")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                RemoteVisualOption(
                    title: "单击",
                    subtitle: library.description(for: binding.action(for: .tap)),
                    symbol: "hand.tap",
                    selected: editingGesture == .tap,
                    compact: true,
                    action: { editingGesture = .tap }
                )
                RemoteVisualOption(
                    title: "双击",
                    subtitle: library.description(for: binding.action(for: .doubleTap)),
                    symbol: "hand.tap.fill",
                    selected: editingGesture == .doubleTap,
                    compact: true,
                    action: { editingGesture = .doubleTap }
                )
                RemoteVisualOption(
                    title: "长按",
                    subtitle: library.description(for: binding.action(for: .longPress)),
                    symbol: "hand.point.up.left.fill",
                    selected: editingGesture == .longPress,
                    compact: true,
                    action: { editingGesture = .longPress }
                )
            }

            if editingGesture == .doubleTap {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("双击连击窗口")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { binding.effectiveDoubleTapWindow },
                            set: { store.setDoubleTapWindow($0, for: selected) }
                        ), in: 0.15...0.60, step: 0.02)
                        Text(String(format: "%.2f 秒", binding.effectiveDoubleTapWindow))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RemotePalette.indigo)
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text("未配置双击动作时，单击保持 0 延迟即时触发。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            if editingGesture == .longPress {
                HStack(spacing: 10) {
                    Text("长按判定时长")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { binding.effectiveThreshold },
                        set: { store.setLongPressThreshold($0, for: selected) }
                    ), in: 0.2...2.5, step: 0.05)
                    Text(String(format: "%.2f 秒", binding.effectiveThreshold))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RemotePalette.indigo)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var quickPresetsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("2. 一键选用常用动作")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    showingMacPresetPicker = true
                } label: {
                    Label("全部 22+ 项系统功能库", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                quickChip(
                    title: "切换双机目标",
                    subtitle: "本机 ⇄ 另一台 Mac",
                    symbol: "macbook.and.ipad",
                    active: action.kind == .systemAction && action.systemAction == .switchMacTarget
                ) {
                    store.setSystemAction(.switchMacTarget, for: selected, gesture: editingGesture)
                }

                quickChip(
                    title: "打开任意 App",
                    subtitle: "选择本机应用程序",
                    symbol: "app.badge",
                    active: currentActionIsApp && action.presetID != RemoteLibraryStore.chatGPTPresetID,
                    action: chooseApplicationForKey
                )

                quickChip(
                    title: "打开 ChatGPT",
                    subtitle: "启动并聚焦输入",
                    symbol: "bubble.left.and.text.bubble.right",
                    active: action.kind == .libraryAction && action.presetID == RemoteLibraryStore.chatGPTPresetID
                ) {
                    store.setLibraryAction(RemoteLibraryStore.chatGPTPresetID, for: selected, gesture: editingGesture)
                }

                ForEach(MacShortcutPreset.popular.prefix(3)) { preset in
                    let active = preset.nativeAction.map {
                        action.kind == .systemAction && action.systemAction == $0
                    } ?? (action.kind == .keyboardShortcut && action.shortcut == preset.shortcut)
                    quickChip(
                        title: preset.title,
                        subtitle: preset.nativeAction == nil ? preset.shortcut.display : "系统原生",
                        symbol: preset.symbol,
                        active: active
                    ) {
                        bindMacPreset(preset, to: selected, gesture: editingGesture)
                    }
                }
            }
        }
    }

    private func quickChip(
        title: String,
        subtitle: String,
        symbol: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? .white : RemotePalette.indigo)
                    .frame(width: 26, height: 26)
                    .background(
                        active ? RemotePalette.indigo : RemotePalette.indigo.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                active ? RemotePalette.indigo.opacity(0.10) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(active ? RemotePalette.indigo.opacity(0.50) : .primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var assistantDedicatedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语音助手专用配置（配合豆包等 AI 语音工具）")
                .font(.system(size: 12, weight: .semibold))
            RemoteVoiceTriggerSelector(trigger: $monitor.doubaoShortcutTrigger)
            Text(monitor.doubaoShortcutTrigger.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RemotePalette.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private var actionKindAndDetailSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(selected == .assistant ? "语音键关联热键或动作" : "3. 或自由定制键盘热键与动作库（含本地脚本）")
                .font(.system(size: 12, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
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

            currentActionDetailEditor
        }
    }

    @ViewBuilder
    private var currentActionDetailEditor: some View {
        switch action.kind {
        case .keyboardShortcut:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RemoteShortcutVisual(shortcut: action.shortcut, placeholder: "尚未录制快捷键")
                    Spacer()
                    Button {
                        recordingGesture = editingGesture
                        showingRecorder = true
                    } label: {
                        Label(action.shortcut == nil ? "录制快捷键" : "修改快捷键", systemImage: "keyboard")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                }
                if selected != .assistant && (editingGesture != .longPress || action.effectiveHoldMode == .timed) {
                    HStack(spacing: 10) {
                        Text("按住目标键时长")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { action.effectiveHoldSeconds },
                            set: { store.setOutputHold($0, for: selected, gesture: editingGesture) }
                        ), in: 0.04...3.0, step: 0.02)
                        Text(String(format: "%.2f 秒", action.effectiveHoldSeconds))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(12)
            .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

        case .systemAction:
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(RemotePalette.indigo)
                Text(action.systemAction?.title ?? "尚未选择系统动作")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(RemoteSystemAction.allCases) { native in
                        Button {
                            store.setSystemAction(native, for: selected, gesture: editingGesture)
                        } label: {
                            if action.systemAction == native {
                                Label(native.title, systemImage: "checkmark")
                            } else {
                                Text(native.title)
                            }
                        }
                    }
                } label: {
                    Label("更换系统动作", systemImage: "chevron.up.chevron.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

        case .libraryAction:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("选择已保存的动作或脚本（支持多步组合）")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        onOpenLibrary()
                    } label: {
                        Label("新建 / 编辑动作与脚本", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .semibold))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)], spacing: 8) {
                    ForEach(library.actions) { saved in
                        RemoteVisualOption(
                            title: saved.name,
                            subtitle: saved.summary,
                            symbol: saved.steps.first?.kind.visualSymbol ?? "square.stack",
                            selected: action.presetID == saved.id,
                            compact: true
                        ) {
                            store.setLibraryAction(saved.id, for: selected, gesture: editingGesture)
                        }
                    }
                }
            }
            .padding(12)
            .background(RemotePalette.indigo.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

        case .none:
            EmptyView()
        }
    }

    private var physicalHoldSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("长按持续输出模式")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("长按输出方式", selection: Binding(
                    get: { action.effectiveHoldMode },
                    set: { store.setOutputHoldMode($0, for: selected, gesture: .longPress) }
                )) {
                    ForEach(RemoteOutputHoldMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            Text(action.effectiveHoldMode == .physical
                 ? "按住遥控器时持续连发目标键（方向键连续滚动、退格键连续删除），松开即停。"
                 : "松开遥控器后，按设定的固定时长发送一次按键。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var bottomTestAndResetBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.45)
            if manualVoiceHoldActive && runner.voiceShortcutHeld {
                Button {
                    runner.endVoiceShortcutHold()
                    manualVoiceHoldActive = false
                } label: {
                    Label("结束语音热键测试并释放按键", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }

            HStack(spacing: 10) {
                Button {
                    showExecutionConfirmation = true
                } label: {
                    Label("模拟试运行此动作", systemImage: "play.fill")
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                .disabled(!canTestCurrentAction || runner.running)

                Button {
                    store.reset(selected, gesture: editingGesture)
                } label: {
                    Label("清空此\(editingGesture.title)", systemImage: "trash")
                }
                .buttonStyle(RemoteActionButtonStyle())
                .disabled(action.kind == .none)

                Spacer()
                Text(runner.result)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var canTestCurrentAction: Bool {
        switch action.kind {
        case .none: return false
        case .keyboardShortcut: return action.shortcut != nil
        case .systemAction: return action.systemAction != nil
        case .libraryAction: return library.steps(for: action) != nil
        }
    }

    private var allKeysQuickGridCard: some View {
        RemoteCard(padding: 14) {
            DisclosureGroup(isExpanded: $showAllKeysGrid) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    ForEach(store.activeModel.keys) { key in
                        let current = store.binding(for: key)
                        let active = selected == key
                        Button {
                            selected = key
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: key.symbol)
                                    .foregroundStyle(active ? RemotePalette.indigo : .secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(quickGridSummary(for: current))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(
                                active ? RemotePalette.indigo.opacity(0.10) : Color.primary.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Label("展开全部按键配置总览表", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("已配置 \(store.configuredCount)/\(store.activeModel.keys.count) 个按键")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(RemotePalette.indigo)
        }
    }

    // MARK: - Helpers

    private func quickGridSummary(for binding: RemoteBinding) -> String {
        let tap = binding.action(for: .tap)
        if tap.kind != .none { return library.description(for: tap) }
        let doubleTap = binding.action(for: .doubleTap)
        if doubleTap.kind != .none { return "双击：\(library.description(for: doubleTap))" }
        let longPress = binding.action(for: .longPress)
        if longPress.kind != .none { return "长按：\(library.description(for: longPress))" }
        return "未配置"
    }

    private func runCurrentActionTest() {
        let selectedAction = store.action(for: selected, gesture: editingGesture)
        if selected == .assistant, editingGesture == .longPress,
           let steps = library.steps(for: selectedAction), steps.count == 1,
           let shortcut = steps.first?.shortcut, steps.first?.kind == .keyboard {
            if monitor.doubaoShortcutTrigger == .tap {
                runner.tapVoiceShortcut(shortcut)
            } else {
                runner.beginVoiceShortcutHold(shortcut)
                manualVoiceHoldActive = runner.voiceShortcutHeld
            }
        } else {
            runner.test(
                action: selectedAction,
                label: "\(selected.title) · \(editingGesture.title)",
                library: library
            )
        }
    }

    private func bindMacPreset(_ preset: MacShortcutPreset, to key: RemoteKey, gesture: RemoteGesture) {
        if let native = preset.nativeAction {
            store.setSystemAction(native, for: key, gesture: gesture)
        } else {
            bindShortcut(preset.shortcut, to: key, gesture: gesture)
        }
    }

    private func bindShortcut(_ shortcut: RemoteShortcut, to key: RemoteKey, gesture: RemoteGesture) {
        if store.conflictingKey(for: shortcut, excluding: key, gesture: gesture) == nil {
            _ = store.setShortcut(shortcut, for: key, gesture: gesture)
        } else {
            pendingTarget = key
            pendingShortcut = shortcut
            pendingGesture = gesture
        }
    }

    private func clearPendingConflict() {
        pendingShortcut = nil
        pendingTarget = nil
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
                fileError = "请选择有效的 .app 应用程序。"
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
