import AppKit
import SwiftUI

enum RemoteVoiceSection: String, CaseIterable, Identifiable {
    case live, devices, transcript

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "语音工作台"
        case .devices: "虚拟麦克风设置"
        case .transcript: "录音转文字"
        }
    }

    var subtitle: String {
        switch self {
        case .live: "准备检查与实时说话"
        case .devices: "安装与配置 BlackHole"
        case .transcript: "本地离线识别 WAV"
        }
    }

    var symbol: String {
        switch self {
        case .live: "waveform"
        case .devices: "mic.badge.plus"
        case .transcript: "text.bubble"
        }
    }
}

struct RemoteVoicePage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var bindingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @ObservedObject var transcriber: NativeVoiceTranscriber
    let onImport: () -> Void
    let onExport: () -> Void
    let onOpenConnection: () -> Void
    let onOpenVoiceBinding: () -> Void
    let onOpenSettings: () -> Void
    @Binding var section: RemoteVoiceSection
    @State private var showProtocolDetails = false

    private var voiceShortcutReady: Bool {
        for gesture in [RemoteGesture.longPress, .tap] {
            let action = bindingStore.action(for: .assistant, gesture: gesture)
            guard let steps = actionLibrary.steps(for: action), steps.count == 1 else { continue }
            if steps[0].kind == .keyboard && steps[0].shortcut != nil { return true }
        }
        return false
    }

    private var virtualDeviceReady: Bool {
        let router = bluetooth.virtualMicrophone
        return router.isEnabled && router.devices.contains(where: { $0.id == router.selectedUID })
    }

    private var inputReady: Bool {
        let router = bluetooth.virtualMicrophone
        return virtualDeviceReady &&
            (router.selectedIsDefaultInput || router.autoSwitchInputForVoice)
    }

    private var completionCount: Int {
        [
            bluetooth.connectedDeviceID != nil,
            bluetooth.voiceModeEnabled,
            virtualDeviceReady,
            inputReady,
            voiceShortcutReady,
            hidCapture.executeHardwareActions
        ].filter { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            RemoteCard(padding: 12) {
                HStack(spacing: 9) {
                    ForEach(RemoteVoiceSection.allCases) { item in
                        RemoteVisualOption(
                            title: item.title,
                            subtitle: item.subtitle,
                            symbol: item.symbol,
                            selected: section == item,
                            compact: true,
                            action: { section = item }
                        )
                    }
                }
            }

            switch section {
            case .live:
                voiceReadinessCard
                voiceHeroAndWaveformCard
            case .devices:
                RemoteVirtualMicrophoneSettings(router: bluetooth.virtualMicrophone)
                RemoteCard(padding: 14) {
                    HStack {
                        Text("虚拟麦克风只需设置一次，完成后返回工作台按遥控器语音键即可说话测试。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            section = .live
                        } label: {
                            Label("返回语音工作台", systemImage: "waveform")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                }
            case .transcript:
                transcriptCard
            }
        }
    }

    private var voiceReadinessCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    RemoteSectionTitle(
                        title: "语音输入一键检查清单",
                        subtitle: "把遥控器麦克风的声音实时传给豆包等语音工具，只需完成以下 6 项（未完成项可直接点右侧按钮修复）",
                        symbol: "checklist"
                    )
                    Spacer(minLength: 5)
                    RemoteStatusPill(
                        title: "\(completionCount)/6 已就绪",
                        symbol: completionCount == 6 ? "checkmark.circle.fill" : "circle.dotted",
                        tint: completionCount == 6 ? RemotePalette.positive : RemotePalette.indigo
                    )
                }

                ProgressView(value: Double(completionCount), total: 6)
                    .tint(completionCount == 6 ? RemotePalette.positive : RemotePalette.indigo)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 10)], spacing: 10) {
                    readinessRow(
                        "1. 连接语音蓝牙",
                        detail: bluetooth.connectedDeviceID != nil ? "已连接遥控器语音通道" : "需在连接设备页扫描连接一次",
                        symbol: "antenna.radiowaves.left.and.right",
                        ready: bluetooth.connectedDeviceID != nil,
                        actionTitle: "去连接",
                        action: onOpenConnection
                    )
                    readinessRow(
                        "2. 开启语音监听",
                        detail: bluetooth.voiceModeEnabled ? "语音键监听中（待机不占麦克风）" : "点击开启语音键接收",
                        symbol: "waveform",
                        ready: bluetooth.voiceModeEnabled,
                        actionTitle: bluetooth.canEnableVoiceMode ? "立即开启" : "先连蓝牙",
                        action: {
                            if bluetooth.canEnableVoiceMode { bluetooth.toggleVoiceMode() }
                            else { onOpenConnection() }
                        }
                    )
                    readinessRow(
                        "3. 启用虚拟麦克风",
                        detail: virtualDeviceReady ? "BlackHole 音频路由已启用" : "需选择并开启 BlackHole 2ch",
                        symbol: "mic",
                        ready: virtualDeviceReady,
                        actionTitle: "去设置",
                        action: { section = .devices }
                    )
                    readinessRow(
                        "4. 按需切换输入",
                        detail: inputReady ? "说话时自动切到虚拟麦，松开恢复" : "需开启按需切换系统输入",
                        symbol: "mic.badge.plus",
                        ready: inputReady,
                        actionTitle: "一键配置",
                        action: { section = .devices }
                    )
                    readinessRow(
                        "5. 绑定豆包快捷键",
                        detail: voiceShortcutReady ? "语音键已绑定听写快捷键" : "为语音键绑定豆包唤起热键",
                        symbol: "keyboard",
                        ready: voiceShortcutReady,
                        actionTitle: "绑定热键",
                        action: onOpenVoiceBinding
                    )
                    readinessRow(
                        "6. 允许动作生效",
                        detail: hidCapture.executeHardwareActions ? "已允许按键触发热键" : "点击立即允许执行动作",
                        symbol: "bolt.fill",
                        ready: hidCapture.executeHardwareActions,
                        actionTitle: "立即开启",
                        action: { hidCapture.executeHardwareActions = true }
                    )
                }

                if lanRelay.isForwardingToRemoteMac {
                    Label("当前处于「双机转发模式」：按下遥控器语音键说话时，声音与热键将自动实时转发至「\(lanRelay.connectedPeerName ?? "另一台 Mac")」！",
                          systemImage: "macbook.and.ipad")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RemotePalette.turquoise)
                }
            }
        }
    }

    private func readinessRow(
        _ title: String,
        detail: String,
        symbol: String,
        ready: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ready ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 34, height: 34)
                .background(
                    (ready ? RemotePalette.positive : RemotePalette.indigo).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !ready {
                Button(actionTitle, action: action)
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var voiceHeroAndWaveformCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        voiceHeroSummary
                        Spacer(minLength: 8)
                        RemoteMicrophoneVisual(isActive: bluetooth.isRecording, audioLevel: bluetooth.audioLevel)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        voiceHeroSummary
                        RemoteMicrophoneVisual(isActive: bluetooth.isRecording, audioLevel: bluetooth.audioLevel)
                            .frame(maxWidth: .infinity)
                    }
                }

                RemoteWaveform(level: bluetooth.audioLevel, active: bluetooth.isRecording)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(RemotePalette.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 10) {
                    Button {
                        onExport()
                    } label: {
                        Label("导出最近录音 (.wav)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)

                    Button {
                        section = .transcript
                        if let data = bluetooth.waveFileData() {
                            transcriber.recognize(waveData: data)
                        }
                    } label: {
                        Label("本机离线转成文字", systemImage: "sparkles")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)

                    Spacer()

                    Button(showProtocolDetails ? "收起技术详情" : "查看底层链路详情") {
                        showProtocolDetails.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }

                if showProtocolDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { audioMetrics }
                            VStack(spacing: 10) { audioMetrics }
                        }
                        Text("\(pipelineDiagnostic) · 协议：\(bluetooth.protocolDetails)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var voiceHeroSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteStatusPill(
                title: bluetooth.isRecording ? "正在接收遥控器语音" :
                    (bluetooth.voiceModeEnabled ? "语音待机就绪 · 按语音键说话" : "语音监听未开启"),
                symbol: bluetooth.isRecording ? "record.circle" : "waveform",
                tint: bluetooth.isRecording ? RemotePalette.positive : RemotePalette.indigo
            )
            Text("按住遥控器说话，松开即停。")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(bluetooth.voiceStatus)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("当前系统麦克风：\(bluetooth.virtualMicrophone.systemInputName)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button {
                bluetooth.toggleVoiceMode()
            } label: {
                Label(
                    bluetooth.voiceModeEnabled ? "停止语音键监听" : "开启语音键监听",
                    systemImage: bluetooth.voiceModeEnabled ? "stop.circle" : "mic.circle"
                )
            }
            .buttonStyle(RemoteActionButtonStyle(emphasized: !bluetooth.voiceModeEnabled))
            .disabled(!bluetooth.canEnableVoiceMode)
        }
    }

    private var transcriptCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    RemoteSectionTitle(
                        title: "录音离线转文字",
                        subtitle: "调用 macOS 本机语音识别能力，录音数据保留在本机",
                        symbol: "text.bubble"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(title: "本机识别", symbol: "lock.shield", tint: RemotePalette.positive)
                }

                HStack(spacing: 10) {
                    Picker("识别语言", selection: $transcriber.language) {
                        Text("简体中文").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    Spacer()
                    Button {
                        onImport()
                    } label: {
                        Label("导入 WAV 文件", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(transcriber.isProcessing)

                    if transcriber.isProcessing {
                        Button("停止识别") { transcriber.cancel() }
                            .buttonStyle(RemoteActionButtonStyle())
                    } else {
                        Button {
                            if let data = bluetooth.waveFileData() {
                                transcriber.recognize(waveData: data)
                            }
                        } label: {
                            Label("识别上次录音", systemImage: "sparkles")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if transcriber.transcript.isEmpty {
                        Text("识别出的文字将显示在这里，可自由编辑并一键复制…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $transcriber.transcript)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 140)
                }
                .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text(transcriber.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcriber.transcript, forType: .string)
                    } label: {
                        Label("复制文字", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(transcriber.transcript.isEmpty)
                }
            }
        }
    }

    private var pipelineDiagnostic: String {
        let router = bluetooth.virtualMicrophone
        if !bluetooth.voiceModeEnabled { return "等待开启语音键监听" }
        if bluetooth.isRecording && bluetooth.audioPacketCount == 0 { return "已收到开始信号，等待音频帧" }
        if router.forwardedFrames > 0 { return "已向虚拟麦克风输出 \(router.forwardedFrames / 48_000) 秒音频" }
        return "待机就绪"
    }

    @ViewBuilder
    private var audioMetrics: some View {
        RemoteMetric(title: "音频包数", value: "\(bluetooth.audioPacketCount)", symbol: "waveform.path", tint: RemotePalette.indigo)
        RemoteMetric(title: "解码帧数", value: "\(bluetooth.decodedFrameCount)", symbol: "waveform.badge.mic", tint: RemotePalette.turquoise)
        RemoteMetric(title: "累计数据", value: ByteCountFormatter.string(fromByteCount: Int64(bluetooth.audioByteCount), countStyle: .binary), symbol: "externaldrive", tint: RemotePalette.indigo)
        RemoteMetric(title: "丢帧计数", value: "\(bluetooth.droppedFrameCount)", symbol: "exclamationmark.circle", tint: bluetooth.droppedFrameCount == 0 ? RemotePalette.positive : RemotePalette.amber)
    }
}
