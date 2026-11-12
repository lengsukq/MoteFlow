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
    @State private var status = "从左侧选择已有动作，或使用下方一键模板快速创建。"
    @StateObject private var runner = RemoteActionRunner()
    @State private var confirmingRun = false

    private var hasUnsavedChanges: Bool {
        guard hasDraft else { return false }
        guard let saved = library.action(draft.id) else { return true }
        return saved.name != draft.name || saved.steps != draft.steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            starterTemplatesBar

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    libraryListCard
                        .frame(minWidth: 235, maxWidth: 285)
                    editorCard
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
                VStack(spacing: 16) {
                    libraryListCard
                    editorCard
                }
            }
        }
        .onAppear {
            if !hasDraft, let first = library.actions.first {
                select(first)
            }
        }
        .sheet(isPresented: Binding(
            get: { recordingStep != nil },
            set: { if !$0 { recordingStep = nil } }
        )) {
            ShortcutRecorderSheet(
                key: .assistant,
                gesture: .tap,
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
                status = "动作已删除；原本绑定它的按键将安全停用。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后，引用该动作的遥控器按钮不会误触发其他操作。")
        }
        .confirmationDialog("在本机试运行此多步动作？", isPresented: $confirmingRun) {
            Button("确认试运行") {
                let reference = RemoteAction(kind: .libraryAction, presetID: draft.id)
                runner.test(action: reference, label: draft.name, library: library)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将依次执行该动作中的所有步骤，请确保已保存当前修改。")
        }
        .confirmationDialog("放弃未保存的修改？", isPresented: $showingDiscardConfirmation) {
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
            Text("当前动作有尚未保存的更改，切换后将丢失。")
        }
    }

    // MARK: - One-Click Starter Templates

    private var starterTemplatesBar: some View {
        RemoteCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("新手快速模板（点击即可一键生成草稿并自由修改）", systemImage: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("保存后可在「遥控器 → 按键配置」绑定到任意按键")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    templateButton(
                        title: "演讲翻页（下一页）",
                        symbol: "rectangle.on.rectangle.angled"
                    ) {
                        loadTemplate(name: "演讲下一页", steps: [
                            RemoteActionStep(
                                kind: .keyboard,
                                shortcut: RemoteShortcut(keyCode: 124, keyLabel: "→", command: false, shift: false, option: false, control: false)
                            )
                        ])
                    }

                    templateButton(
                        title: "打开浏览器并新开标签",
                        symbol: "safari"
                    ) {
                        loadTemplate(name: "打开 Safari 新标签", steps: [
                            RemoteActionStep(kind: .openApp, applicationBundleID: "com.apple.Safari", applicationName: "Safari"),
                            RemoteActionStep(kind: .wait, waitSeconds: 0.4),
                            RemoteActionStep(
                                kind: .keyboard,
                                shortcut: RemoteShortcut(keyCode: 17, keyLabel: "T", command: true, shift: false, option: false, control: false)
                            )
                        ])
                    }

                    templateButton(
                        title: "全屏 / 退出全屏",
                        symbol: "arrow.up.left.and.arrow.down.right"
                    ) {
                        loadTemplate(name: "切换窗口全屏", steps: [
                            RemoteActionStep(
                                kind: .keyboard,
                                shortcut: RemoteShortcut(keyCode: 3, keyLabel: "F", command: true, shift: false, option: false, control: true)
                            )
                        ])
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func templateButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(RemoteActionButtonStyle())
    }

    private func loadTemplate(name: String, steps: [RemoteActionStep]) {
        draft = RemoteLibraryAction(name: name, steps: steps)
        selectedID = nil
        hasDraft = true
        status = "已载入模板「\(name)」，点击「保存动作」即可生效。"
    }

    // MARK: - Left List & Right Editor

    private var libraryListCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("已保存动作")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(library.actions.count) 项")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Button {
                    requestNavigation(to: nil)
                } label: {
                    Label("新建空白动作", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))

                if library.actions.isEmpty {
                    Label("暂无已保存动作", systemImage: "square.stack")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                } else {
                    ForEach(library.actions) { item in
                        RemoteVisualOption(
                            title: item.name,
                            subtitle: item.summary,
                            symbol: item.steps.contains(where: { $0.kind == .script })
                                ? "terminal"
                                : (item.steps.first?.kind.visualSymbol ?? "square.stack"),
                            selected: selectedID == item.id,
                            compact: true,
                            action: { requestNavigation(to: item) }
                        )
                    }
                }
            }
        }
    }

    private var editorCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    RemoteSectionTitle(
                        title: "多步骤动作组合器",
                        subtitle: "把「打开应用 → 等待 → 发送快捷键 → 运行脚本」串联成一个遥控按键动作",
                        symbol: "slider.horizontal.3"
                    )
                    if hasUnsavedChanges {
                        RemoteStatusPill(title: "未保存", symbol: "pencil.circle", tint: RemotePalette.amber)
                    }
                }

                if !hasDraft {
                    Label("请从左侧选择一个动作，或点击「新建空白动作」。", systemImage: "arrow.left.circle")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 44)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("动作名称").font(.system(size: 12, weight: .semibold))
                        TextField("例如：打开会议软件并静音", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("点击下方卡片添加新步骤：")
                            .font(.system(size: 12, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                            ForEach(RemoteActionStepKind.allCases) { kind in
                                RemoteVisualOption(
                                    title: "+ " + kind.title,
                                    subtitle: kind.visualDetail,
                                    symbol: kind.visualSymbol,
                                    selected: false,
                                    compact: true,
                                    action: { add(kind) }
                                )
                            }
                        }
                    }

                    ForEach(draft.steps.indices, id: \.self) { index in
                        stepEditor(index)
                    }

                    Divider().opacity(0.45)

                    HStack(spacing: 10) {
                        Button {
                            if library.save(draft) {
                                selectedID = draft.id
                                if let saved = library.action(draft.id) { draft = saved }
                                status = "已保存「\(draft.name)」，可在遥控器按键配置中直接选用。"
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
                            Label("试运行", systemImage: "play.fill")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(library.action(draft.id) == nil || runner.running || hasUnsavedChanges)

                        Spacer()
                        if library.action(draft.id) != nil {
                            Button("删除") { showingDelete = true }
                                .buttonStyle(RemoteActionButtonStyle())
                        }
                    }

                    HStack {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if runner.result != "尚未试运行" {
                            Text(runner.result)
                                .font(.system(size: 11))
                                .foregroundStyle(RemotePalette.indigo)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("步骤 \(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RemotePalette.indigo, in: Capsule())

                Picker("步骤类型", selection: $draft.steps[index].kind) {
                    ForEach(RemoteActionStepKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)

                Spacer()
                Button { moveStep(from: index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                Button { moveStep(from: index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == draft.steps.count - 1)
                Button(role: .destructive) {
                    draft.steps.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)

            switch draft.steps[index].kind {
            case .openApp:
                RemoteVisualOption(
                    title: draft.steps[index].applicationName ?? "点击选择本机应用程序 (.app)",
                    subtitle: draft.steps[index].applicationBundleID ?? "打开 /Applications 选择应用",
                    symbol: "app.badge",
                    selected: draft.steps[index].applicationBundleID != nil,
                    compact: true,
                    action: { chooseApplication(at: index) }
                )

            case .keyboard:
                HStack(spacing: 10) {
                    RemoteShortcutVisual(shortcut: draft.steps[index].shortcut, placeholder: "未设置快捷键")
                    Spacer()
                    Button("设置按键") { recordingStep = draft.steps[index].id }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                HStack {
                    Text("按键持续")
                    Slider(value: $draft.steps[index].holdSeconds, in: 0.04...3.0, step: 0.02)
                    Text(String(format: "%.2f 秒", draft.steps[index].holdSeconds))
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))

            case .script:
                HStack {
                    Picker("脚本环境", selection: $draft.steps[index].scriptLanguage) {
                        ForEach(RemoteScriptLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .frame(maxWidth: 180)
                    Spacer()
                    Button("从文件导入") { importScript(at: index) }
                        .buttonStyle(RemoteActionButtonStyle())
                }
                TextEditor(text: $draft.steps[index].scriptSource)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            case .wait:
                HStack {
                    Text("暂停等待")
                    Slider(value: $draft.steps[index].waitSeconds, in: 0.1...10, step: 0.1)
                    Text(String(format: "%.1f 秒", draft.steps[index].waitSeconds))
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11))
            }
        }
        .padding(13)
        .background(.primary.opacity(0.027), in: RoundedRectangle(cornerRadius: 13))
    }

    // MARK: - Helpers

    private func createNew() {
        draft = RemoteLibraryAction(name: "新建动作", steps: [RemoteActionStep(kind: .keyboard)])
        selectedID = nil
        hasDraft = true
        status = "正在创建新动作：请填写名称并配置步骤后保存。"
    }

    private func requestNavigation(to item: RemoteLibraryAction?) {
        guard hasUnsavedChanges else {
            if let item { select(item) } else { createNew() }
            return
        }
        if let item, item.id == draft.id { return }
        pendingSelection = item?.id
        pendingNewAction = item == nil
        showingDiscardConfirmation = true
    }

    private func select(_ item: RemoteLibraryAction) {
        selectedID = item.id
        draft = item
        hasDraft = true
        status = "正在编辑：\(item.name)"
    }

    private func add(_ kind: RemoteActionStepKind) {
        guard draft.steps.count < 30 else { status = "单个动作最多支持 30 个步骤"; return }
        draft.steps.append(RemoteActionStep(kind: kind))
    }

    private func moveStep(from index: Int, by delta: Int) {
        let other = index + delta
        guard draft.steps.indices.contains(other) else { return }
        draft.steps.swapAt(index, other)
    }

    private func chooseApplication(at index: Int) {
        let id = draft.steps[index].id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择此步骤要打开的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  let idx = draft.steps.firstIndex(where: { $0.id == id }) else {
                status = "请选择有效的 .app 应用程序。"
                return
            }
            draft.steps[idx].applicationBundleID = bundleID
            draft.steps[idx].applicationName =
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
                (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
                url.deletingPathExtension().lastPathComponent
            status = "已选择应用：\(draft.steps[idx].applicationName ?? "")"
        }
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
                    status = "脚本超过 200 KB 上限"
                    return
                }
                guard let idx = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
                draft.steps[idx].scriptSource = text
                switch url.pathExtension.lowercased() {
                case "py": draft.steps[idx].scriptLanguage = .python
                case "zsh": draft.steps[idx].scriptLanguage = .zsh
                default: draft.steps[idx].scriptLanguage = .bash
                }
                status = "已导入脚本内容，点击「保存动作」即可生效。"
            } catch {
                status = "读取脚本失败：\(error.localizedDescription)"
            }
        }
    }
}
