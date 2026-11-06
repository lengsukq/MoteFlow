import AppKit
import SwiftUI

struct RemoteActionLibraryPage: View {
    @ObservedObject var library: RemoteLibraryStore
    @State private var selectedID: UUID?
    @State private var draft = RemoteLibraryAction(name: "新建动作")
    @State private var hasDraft = false
    @State private var recordingStep: UUID?
    @State private var showingDelete = false
    @State private var showingDiscardConfirmation = false
    @State private var pendingSelection: UUID?
    @State private var pendingNewAction = false
    @State private var status = "选择一个动作，或新建可复用动作。"
    @StateObject private var runner = RemoteActionRunner()
    @State private var confirmingRun = false

    private var hasUnsavedChanges: Bool {
        guard hasDraft else { return false }
        guard let saved = library.action(draft.id) else { return true }
        return saved.name != draft.name || saved.steps != draft.steps
    }

    private func chooseApplication(at index: Int) {
        let id = draft.steps[index].id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择此动作要打开的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  let idx = draft.steps.firstIndex(where: { $0.id == id }) else {
                status = "请选择有效的 .app 应用程序，而不是普通文件。"
                return
            }
            draft.steps[idx].applicationBundleID = bundleID
            draft.steps[idx].applicationName =
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                url.deletingPathExtension().lastPathComponent
            status = "已选择 \(draft.steps[idx].applicationName ?? "应用")，保存动作后可绑定多个遥控器按钮。"
        }
    }

    private func createNew() {
        draft = RemoteLibraryAction(name: "新建动作", steps: [
            RemoteActionStep(kind: .keyboard)
        ])
        selectedID = nil
        hasDraft = true
        status = "新建动作：请设置名称与步骤，完成后点击保存。"
    }

    private func requestNavigation(to item: RemoteLibraryAction?) {
        guard hasUnsavedChanges else {
            if let item { select(item) } else { createNew() }
            return
        }
        // Selecting the already-open action should not throw away edits.
        if let item, item.id == draft.id { return }
        pendingSelection = item?.id
        pendingNewAction = item == nil
        showingDiscardConfirmation = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RemoteCard(padding: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        RemoteStatusPill(title: "ONE ACTION LIBRARY", symbol: "square.stack.3d.up")
                        Text("动作库")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Text("单键、快捷键、脚本、等待，统一作为动作步骤。一个动作可包含多步，保存后能绑定给多个遥控器按键。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 43, weight: .ultraLight))
                        .foregroundStyle(RemotePalette.indigo.opacity(0.5))
                        .frame(width: 84)
                }
                .padding(23)
                .background(
                    LinearGradient(colors: [RemotePalette.indigo.opacity(0.11),
                                            RemotePalette.turquoise.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20)
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    libraryList.frame(minWidth: 230, maxWidth: 275)
                    editor.frame(minWidth: 420, maxWidth: .infinity)
                }
                VStack(spacing: 16) { libraryList; editor }
            }
        }
        .onAppear {
            if !hasDraft, let first = library.actions.first { select(first) }
        }
        .sheet(isPresented: Binding(
            get: { recordingStep != nil },
            set: { if !$0 { recordingStep = nil } }
        )) {
            ShortcutRecorderSheet(
                key: .assistant, gesture: .tap,
                targetDescription: "\(draft.name) · 动作步骤"
            ) { shortcut in
                if let index = draft.steps.firstIndex(where: { $0.id == recordingStep }) {
                    draft.steps[index].shortcut = shortcut
                }
                recordingStep = nil
            }
        }
        .confirmationDialog("删除此动作？", isPresented: $showingDelete) {
            Button("删除动作", role: .destructive) {
                library.delete(draft.id)
                hasDraft = false
                selectedID = nil
                if let first = library.actions.first { select(first) }
                status = "已删除动作。引用它的按键将显示「动作已删除」，不会误执行。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("动作被删除后，引用它的遥控器按键不会自动执行其他动作。")
        }
        .confirmationDialog("执行动作中的所有步骤？", isPresented: $confirmingRun) {
            Button("确认在本机执行") {
                let reference = RemoteAction(kind: .libraryAction, presetID: draft.id)
                runner.test(action: reference, label: draft.name, library: library)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("按键事件可能影响当前活动应用，脚本以当前用户身份运行。确认前请保存并检查动作步骤。")
        }
        .confirmationDialog("放弃当前未保存的修改？", isPresented: $showingDiscardConfirmation) {
            Button("放弃修改", role: .destructive) {
                if pendingNewAction {
                    createNew()
                } else if let pendingSelection, let item = library.action(pendingSelection) {
                    select(item)
                }
                pendingSelection = nil
                pendingNewAction = false
            }
            Button("继续编辑", role: .cancel) {
                pendingSelection = nil
                pendingNewAction = false
            }
        } message: {
            Text("当前动作还有未保存的修改，切换后这些修改会丢失。")
        }
    }

    private var libraryList: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("全部动作")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(library.actions.count)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Button {
                    requestNavigation(to: nil)
                } label: {
                    Label("新建动作", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                if library.actions.isEmpty {
                    Label("还没有保存的动作", systemImage: "square.stack")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                } else {
                    ForEach(library.actions) { item in
                        RemoteVisualOption(
                            title: item.name, subtitle: item.summary,
                            symbol: item.steps.contains(where: { $0.kind == .script })
                                ? "terminal" : item.steps.first?.kind.visualSymbol ?? "square.stack",
                            selected: selectedID == item.id,
                            compact: true, action: { requestNavigation(to: item) }
                        )
                    }
                }
            }
        }
    }

    private var editor: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                RemoteSectionTitle(
                    title: "动作编辑器",
                    subtitle: "按顺序执行多个步骤，修改后重新保存即更新全部引用",
                    symbol: "slider.horizontal.3"
                )
                if !hasDraft {
                    Label("先从左侧选择或新建一个动作。", systemImage: "arrow.left.circle")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 50)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("动作名称").font(.system(size: 12, weight: .semibold))
                        TextField("例如：打开终端并输入指令", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("执行步骤").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 9)], spacing: 9) {
                        ForEach(RemoteActionStepKind.allCases) { kind in
                            RemoteVisualOption(
                                title: kind.title, subtitle: kind.visualDetail,
                                symbol: kind.visualSymbol, selected: false,
                                compact: true, action: { add(kind) }
                            )
                        }
                    }
                    ForEach(draft.steps.indices, id: \.self) { index in
                        stepEditor(index)
                    }
                    if draft.steps.isEmpty {
                        Label("动作至少需要一个执行步骤。", systemImage: "plus.circle")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.5)
                    HStack(spacing: 10) {
                        Button {
                            if library.save(draft) {
                                selectedID = draft.id
                                if let saved = library.action(draft.id) { draft = saved }
                                status = "保存成功：\(draft.name) · 已同步给所有引用此动作的按键"
                            } else {
                                status = library.error ?? "保存失败"
                            }
                        } label: {
                            Label("保存动作", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        Button {
                            confirmingRun = true
                        } label: {
                            Label("试运行", systemImage: "play")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(library.action(draft.id) == nil || runner.running ||
                                  library.action(draft.id) != draft)
                        Spacer()
                        if library.action(draft.id) != nil {
                            Button("删除") { showingDelete = true }
                                .buttonStyle(RemoteActionButtonStyle())
                        }
                    }
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if hasUnsavedChanges {
                        RemoteStatusPill(title: "修改尚未保存", symbol: "pencil.circle",
                                         tint: RemotePalette.amber)
                    }
                    Text(runner.result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Label("仅在点击「试运行」并确认后才执行。实体遥控器自动触发尚未接通。", systemImage: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stepEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(RemotePalette.indigo)
                Text(draft.steps[index].kind.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { moveStep(from: index, by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                Button { moveStep(from: index, by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == draft.steps.count - 1)
                Button(role: .destructive) {
                    draft.steps.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 7)], spacing: 7) {
                ForEach(RemoteActionStepKind.allCases) { kind in
                    RemoteVisualOption(
                        title: kind.title, subtitle: "",
                        symbol: kind.visualSymbol,
                        selected: draft.steps[index].kind == kind,
                        compact: true,
                        action: { draft.steps[index].kind = kind }
                    )
                }
            }

            switch draft.steps[index].kind {
            case .openApp:
                RemoteVisualOption(
                    title: draft.steps[index].applicationName ?? "选择一个应用",
                    subtitle: draft.steps[index].applicationBundleID ?? "点击浏览本机的 .app",
                    symbol: "app.badge",
                    selected: draft.steps[index].applicationBundleID != nil,
                    compact: true, action: { chooseApplication(at: index) }
                )
                Text("使用应用 Bundle ID 打开，不绑定固定安装路径。支持任意已安装的 macOS App。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .keyboard:
                HStack(spacing: 10) {
                    RemoteShortcutVisual(shortcut: draft.steps[index].shortcut,
                                         placeholder: "尚未设置快捷键")
                    Spacer()
                    Button("录制按键") { recordingStep = draft.steps[index].id }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                HStack {
                    Text("按住目标键")
                    Slider(value: $draft.steps[index].holdSeconds, in: 0.04...5, step: 0.02)
                    Text(String(format: "%.2f 秒", draft.steps[index].holdSeconds))
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
            case .script:
                HStack {
                    Picker("语言", selection: $draft.steps[index].scriptLanguage) {
                        ForEach(RemoteScriptLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .frame(maxWidth: 190)
                    Spacer()
                    Button("导入脚本内容") { importScript(at: index) }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                TextEditor(text: $draft.steps[index].scriptSource)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 155)
                    .padding(8)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                Text("脚本内容保存在动作库中。执行时以当前用户权限运行，最多 20 秒。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .wait:
                HStack {
                    Text("等待")
                    Slider(value: $draft.steps[index].waitSeconds, in: 0...10, step: 0.1)
                    Text(String(format: "%.1f 秒", draft.steps[index].waitSeconds))
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
            }
        }
        .padding(14)
        .background(.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 14))
    }

    private func select(_ item: RemoteLibraryAction) {
        selectedID = item.id
        draft = item
        hasDraft = true
        status = "正在编辑：\(item.name)"
    }

    private func add(_ kind: RemoteActionStepKind) {
        guard draft.steps.count < 30 else { status = "一个动作最多包含 30 个步骤"; return }
        draft.steps.append(RemoteActionStep(kind: kind))
    }

    private func moveStep(from index: Int, by delta: Int) {
        let other = index + delta
        guard draft.steps.indices.contains(other) else { return }
        draft.steps.swapAt(index, other)
    }

    private func importScript(at index: Int) {
        let stepID = draft.steps[index].id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.utf8.count <= 200_000 else {
                    status = "脚本大于 200 KB，拒绝导入"
                    return
                }
                guard let index = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
                draft.steps[index].scriptSource = text
                switch url.pathExtension.lowercased() {
                case "py": draft.steps[index].scriptLanguage = .python
                case "zsh": draft.steps[index].scriptLanguage = .zsh
                default: draft.steps[index].scriptLanguage = .bash
                }
                status = "已导入脚本内容，点击「保存动作」完成保存"
            } catch {
                status = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
