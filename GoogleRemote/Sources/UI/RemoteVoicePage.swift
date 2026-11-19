import AppKit
import SwiftUI

enum RemoteVoiceSection: String, CaseIterable, Identifiable {
    case live
    case devices
    case transcript

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "语音工作台"
        case .devices: "虚拟声卡与防回音"
        case .transcript: "免驱动离线听写"
        }
    }

    var subtitle: String {
        switch self {
        case .live: "三步绿灯与模式选择"
        case .devices: "接入豆包麦克风设置"
        case .transcript: "本机识别直接上屏"
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

/// Focused Voice Assistant page (free of arbitrary WAV file import/export clutter):
/// - Top 3-step green-light readiness bar (Bluetooth Mic -> Audio Route -> Anti-Echo)
/// - Immediate warning banner if macOS System Output is mistakenly set to BlackHole
/// - Two clear scenario cards: "AI Voice App Mode (Doubao + BlackHole)" vs. "Zero-Driver Offline Dictation"
struct RemoteVoicePage: View {
    @EnvironmentObject private var bluetooth: RemoteBluetoothManager
    @EnvironmentObject private var hidCapture: HIDCaptureManager
    @EnvironmentObject private var bindingStore: RemoteBindingStore
    @EnvironmentObject private var actionLibrary: RemoteLibraryStore
    @EnvironmentObject private var lanRelay: RemoteLANRelayManager
    @ObservedObject var transcriber: NativeVoiceTranscriber
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

    private var micChannelReady: Bool {
        bluetooth.connectedDeviceID != nil && bluetooth.voiceModeEnabled
    }

    private var virtualDeviceReady: Bool {
        let router = bluetooth.virtualMicrophone
        return router.isEnabled && router.devices.contains(where: { $0.id == router.selectedUID })
    }

    private var antiEchoReady: Bool {
        let router = bluetooth.virtualMicrophone
        if router.isUsingDirectPushMic { return true }
        return router.suppressSpeakerEchoDuringVoice && !router.outputPointedToVirtualMic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if bluetooth.virtualMicrophone.outputPointedToVirtualMic {
                RemoteOutputEchoWarningBanner(router: bluetooth.virtualMicrophone)
            }

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
                threeStepHealthBar
                dualModeCardsRow
                voiceHeroAndWaveformCard
            case .devices:
                RemoteVirtualMicrophoneSettings(router: bluetooth.virtualMicrophone)
                RemoteCard(padding: 14) {
                    HStack {
                        Text("虚拟声卡只需配置一次，完成后切回语音工作台按住遥控器语音键说话即可。")
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

    // MARK: - 3-Step Green-Light Health Strip

    private var threeStepHealthBar: some View {
        RemoteCard(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("语音环境三步绿灯体检", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    if lanRelay.isForwardingToRemoteMac {
                        RemoteStatusPill(
                            title: "双机语音实时转发至远端 Mac",
                            symbol: "macbook.and.ipad",
                            tint: RemotePalette.turquoise
                        )
                    }
                }

                HStack(spacing: 10) { healthSteps }
            }
        }
    }

    @ViewBuilder
    private var healthSteps: some View {
        healthStepPill(
            step: "1. 遥控器麦克风",
            status: micChannelReady ? "已连接并监听" : (bluetooth.connectedDeviceID != nil ? "待开启监听" : "待连接语音蓝牙"),
            ready: micChannelReady,
            buttonTitle: bluetooth.connectedDeviceID == nil ? "扫描连接" : "立即开启"
        ) {
            if bluetooth.connectedDeviceID == nil {
                onOpenConnection()
            } else if bluetooth.canEnableVoiceMode && !bluetooth.voiceModeEnabled {
                bluetooth.toggleVoiceMode()
            }
        }

        healthStepPill(
            step: "2. 语音应用通道",
            status: virtualDeviceReady && voiceShortcutReady
                ? (bluetooth.virtualMicrophone.isUsingDirectPushMic ? "MoteFlow Mic 直推已就绪" : "BlackHole + 热键已就绪")
                : (!virtualDeviceReady ? "可选：装 MoteFlow Mic 或离线" : "待绑定唤起热键"),
            ready: virtualDeviceReady && voiceShortcutReady,
            buttonTitle: !virtualDeviceReady ? "配置声卡" : "绑定热键"
        ) {
            if !virtualDeviceReady {
                section = .devices
            } else {
                onOpenVoiceBinding()
            }
        }

        healthStepPill(
            step: "3. 屏幕共享防回音",
            status: bluetooth.virtualMicrophone.isUsingDirectPushMic
                ? "纯输入直推 · 零回声"
                : (antiEchoReady ? "说话自动静音扬声器" : "点击一键修复防回音"),
            ready: antiEchoReady,
            buttonTitle: "一键开启"
        ) {
            if bluetooth.virtualMicrophone.outputPointedToVirtualMic {
                bluetooth.virtualMicrophone.switchDefaultOutputAwayFromVirtualMic()
            }
            bluetooth.virtualMicrophone.suppressSpeakerEchoDuringVoice = true
        }
    }

    private func healthStepPill(
        step: String,
        status: String,
        ready: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(ready ? RemotePalette.positive : RemotePalette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(step).font(.system(size: 12, weight: .semibold))
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ready ? RemotePalette.positive : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !ready {
                Button(buttonTitle, action: action)
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ready ? RemotePalette.positive.opacity(0.05) : Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - Dual Scenario Mode Cards

    private var dualModeCardsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            aiAssistantModeCard
            offlineZeroDriverModeCard
        }
    }

    private var aiAssistantModeCard: some View {
        let ready = virtualDeviceReady && voiceShortcutReady && hidCapture.executeHardwareActions
        return RemoteCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "sparkles.tv.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(RemotePalette.indigo, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模式 A · 接入豆包等 AI 语音工具（推荐）")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("通过虚拟声卡把遥控器声音实时喂给豆包，平时不占系统麦克风")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        section = .devices
                    } label: {
                        Label(virtualDeviceReady ? "调整虚拟声卡" : "1. 安装/启用 BlackHole", systemImage: "mic.badge.plus")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: !virtualDeviceReady))

                    Button {
                        onOpenVoiceBinding()
                    } label: {
                        Label(voiceShortcutReady ? "修改语音热键" : "2. 绑定豆包快捷键", systemImage: "keyboard")
                    }
                    .buttonStyle(RemoteActionButtonStyle(emphasized: virtualDeviceReady && !voiceShortcutReady))

                    if ready {
                        Label("已就绪", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RemotePalette.positive)
                    }
                }
            }
        }
    }

    private var offlineZeroDriverModeCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(RemotePalette.turquoise, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模式 B · 零驱动离线语音转文字（免装声卡）")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("无需安装任何音频驱动，调用 macOS 原生离线识别把录音转成文字")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        section = .transcript
                        if let data = bluetooth.waveFileData() {
                            transcriber.recognize(waveData: data)
                        }
                    } label: {
                        Label("打开离线转文字面板", systemImage: "sparkles")
                    }
                    .buttonStyle(RemoteActionButtonStyle())

                    Text("双机互联时若受控机未装声卡，也会自动回退此模式直接打字上屏")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Live Waveform & Collapsible Acoustic Stats

    private var voiceHeroAndWaveformCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    voiceHeroSummary
                    Spacer(minLength: 8)
                    RemoteMicrophoneVisual(isActive: bluetooth.isRecording, audioLevel: bluetooth.audioLevel)
                }

                RemoteWaveform(level: bluetooth.audioLevel, active: bluetooth.isRecording)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(RemotePalette.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Spacer()
                    Button(showProtocolDetails ? "收起声学指标" : "展开底层声学指标") {
                        showProtocolDetails.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }

                if showProtocolDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { audioMetrics }
                        Text("协议状态：\(bluetooth.protocolDetails)")
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
        VStack(alignment: .leading, spacing: 11) {
            RemoteStatusPill(
                title: bluetooth.isRecording ? "正在接收遥控器语音…" :
                    (bluetooth.voiceModeEnabled ? "待机就绪 · 按住遥控器语音键说话" : "语音监听尚未开启"),
                symbol: bluetooth.isRecording ? "record.circle" : "waveform",
                tint: bluetooth.isRecording ? RemotePalette.positive : RemotePalette.indigo
            )
            Text("按住遥控器说话，松开即停。")
                .font(.system(size: 23, weight: .bold, design: .rounded))
            Text(bluetooth.voiceStatus)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Text("当前系统输入：\(bluetooth.virtualMicrophone.systemInputName) · 输出：\(bluetooth.virtualMicrophone.systemOutputName)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Button {
                    if bluetooth.connectedDeviceID == nil {
                        onOpenConnection()
                    } else {
                        bluetooth.toggleVoiceMode()
                    }
                } label: {
                    Label(
                        bluetooth.connectedDeviceID == nil
                            ? "扫描连接语音遥控器"
                            : (bluetooth.voiceModeEnabled ? "暂停语音监听" : "开启语音监听"),
                        systemImage: bluetooth.voiceModeEnabled ? "pause.circle" : "mic.circle.fill"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: !bluetooth.voiceModeEnabled))
            }
        }
    }

    private var transcriptCard: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    RemoteSectionTitle(
                        title: "本机离线语音转文字",
                        subtitle: "全程在 Mac 本地引擎完成识别，录音不会上传云端",
                        symbol: "text.bubble"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(title: "零驱动离线引擎", symbol: "lock.shield", tint: RemotePalette.positive)
                }

                HStack(spacing: 10) {
                    Picker("识别语言", selection: $transcriber.language) {
                        Text("简体中文").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    Spacer()

                    if transcriber.isProcessing {
                        Button("停止识别") { transcriber.cancel() }
                            .buttonStyle(RemoteActionButtonStyle())
                    } else {
                        Button {
                            if let data = bluetooth.waveFileData() {
                                transcriber.recognize(waveData: data)
                            }
                        } label: {
                            Label("转写最近一次遥控录音", systemImage: "sparkles")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                        .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if transcriber.transcript.isEmpty {
                        Text("按住遥控器语音键说一句话，松开后点击「转写最近一次遥控录音」即可将文字显示在此处…")
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
                        Label("复制识别文字", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(transcriber.transcript.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var audioMetrics: some View {
        RemoteMetric(title: "音频包数", value: "\(bluetooth.audioPacketCount)", symbol: "waveform.path", tint: RemotePalette.indigo)
        RemoteMetric(title: "解码帧数", value: "\(bluetooth.decodedFrameCount)", symbol: "waveform.badge.mic", tint: RemotePalette.turquoise)
        RemoteMetric(title: "累计数据", value: ByteCountFormatter.string(fromByteCount: Int64(bluetooth.audioByteCount), countStyle: .binary), symbol: "externaldrive", tint: RemotePalette.indigo)
        RemoteMetric(title: "丢帧计数", value: "\(bluetooth.droppedFrameCount)", symbol: "exclamationmark.circle", tint: bluetooth.droppedFrameCount == 0 ? RemotePalette.positive : RemotePalette.amber)
    }
}
