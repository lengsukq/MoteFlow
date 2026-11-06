import AppKit
import SwiftUI

enum RemoteVoiceSection: String, CaseIterable, Identifiable {
    case live, devices, transcript
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "语音工作台"
        case .devices: "麦克风设备"
        case .transcript: "录音转写"
        }
    }

    var subtitle: String {
        switch self {
        case .live: "实时状态与语音测试"
        case .devices: "BlackHole 与音频路由"
        case .transcript: "WAV 文件与本地识别"
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
    @ObservedObject var transcriber: NativeVoiceTranscriber
    let onImport: () -> Void
    let onExport: () -> Void
    let onOpenConnection: () -> Void
    let onOpenVoiceBinding: () -> Void
    let onOpenSettings: () -> Void
    @Binding var section: RemoteVoiceSection

    private var voiceShortcutReady: Bool {
        // ATVV uses long-press shortcut first, then the legacy tap fallback.
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

    private var voiceReadiness: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    RemoteSectionTitle(
                        title: "语音输入准备检查",
                        subtitle: "按连接 → 接收 → 音频路由 → 豆包热键的顺序逐项完成",
                        symbol: "checklist"
                    )
                    Spacer(minLength: 5)
                    RemoteStatusPill(
                        title: "\(completionCount)/6 项已配置",
                        symbol: completionCount == 6 ? "checkmark.circle" : "circle.dotted",
                        tint: completionCount == 6 ? RemotePalette.positive : RemotePalette.indigo
                    )
                }
                ProgressView(value: Double(completionCount), total: 6)
                    .tint(completionCount == 6 ? RemotePalette.positive : RemotePalette.indigo)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                    readinessRow(
                        "遥控器 BLE", detail: bluetooth.connectedDeviceID != nil
                            ? "蓝牙语音链路已连接" : "需要连接 ATVV 遥控器",
                        symbol: "bluetooth", ready: bluetooth.connectedDeviceID != nil,
                        actionTitle: "去连接", action: onOpenConnection
                    )
                    readinessRow(
                        "ATVV 语音接收", detail: bluetooth.voiceModeEnabled
                            ? "语音通知已订阅" : "未启用 ATVV 接收",
                        symbol: "waveform", ready: bluetooth.voiceModeEnabled,
                        actionTitle: bluetooth.canEnableVoiceMode ? "启用" : "查看连接",
                        action: {
                            if bluetooth.canEnableVoiceMode { bluetooth.toggleVoiceMode() }
                            else { onOpenConnection() }
                        }
                    )
                    readinessRow(
                        "虚拟麦克风路由", detail: virtualDeviceReady
                            ? "驱动已检测并启用，尚待音频验证" : "需要加载、选择并启用 BlackHole",
                        symbol: "mic", ready: virtualDeviceReady,
                        actionTitle: "设置设备", action: { section = .devices }
                    )
                    readinessRow(
                        "系统麦克风", detail: inputReady
                            ? "已选择虚拟输入或语音时自动切换"
                            : "需要指定 BlackHole 或启用自动切换",
                        symbol: "mic.badge.plus", ready: inputReady,
                        actionTitle: "配置输入", action: { section = .devices }
                    )
                    readinessRow(
                        "语音键快捷键", detail: voiceShortcutReady
                            ? "语音助手已关联单键或组合键"
                            : "未给语音助手设置有效的豆包快捷键",
                        symbol: "keyboard", ready: voiceShortcutReady,
                        actionTitle: "绑定按键", action: onOpenVoiceBinding
                    )
                    readinessRow(
                        "动作执行", detail: hidCapture.executeHardwareActions
                            ? "允许实体事件触发已绑定动作"
                            : "实体按键执行功能尚未开启",
                        symbol: "bolt", ready: hidCapture.executeHardwareActions,
                        actionTitle: "运行设置", action: onOpenSettings
                    )
                }
                Label(
                    completionCount == 6
                    ? "准备配置已齐全。现在按实体语音键说话，观察下方音频波形与虚拟输出；豆包能否转写仍需实测。"
                    : "以上是配置检查，不是端到端录音成功证明。请完成未就绪项后实际测试。",
                    systemImage: "info.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readinessRow(
        _ title: String, detail: String, symbol: String, ready: Bool,
        actionTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ready ? RemotePalette.positive : RemotePalette.indigo)
                .frame(width: 34, height: 34)
                .background((ready ? RemotePalette.positive : RemotePalette.indigo).opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 5)
            if !ready {
                Button(actionTitle, action: action)
                    .buttonStyle(RemoteActionButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RemoteCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 9)], spacing: 9) {
                        ForEach(RemoteVoiceSection.allCases) { item in
                            RemoteVisualOption(
                                title: item.title, subtitle: item.subtitle,
                                symbol: item.symbol, selected: section == item,
                                compact: true, action: { section = item }
                            )
                        }
                    }
                    Label("语音测试与设备安装分开管理；麦克风配置只需完成一次。",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if section == .live {
                voiceReadiness
            RemoteCard(padding: 0) {
                ZStack {
                    LinearGradient(colors: [RemotePalette.indigo.opacity(0.11), RemotePalette.turquoise.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            voiceIntroduction
                            Spacer(minLength: 8)
                            RemoteMicrophoneVisual(isActive: bluetooth.isRecording, audioLevel: bluetooth.audioLevel)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            voiceIntroduction
                            RemoteMicrophoneVisual(isActive: bluetooth.isRecording, audioLevel: bluetooth.audioLevel)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            RemoteCard {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .top, spacing: 14) {
                        RemoteSectionTitle(title: "实时音频", subtitle: "来自遥控器的 ATVV 音频流",
                                           symbol: "waveform.path")
                        Spacer(minLength: 4)
                        if bluetooth.isRecording {
                            RemoteStatusPill(title: "正在接收", symbol: "record.circle", tint: RemotePalette.positive)
                        } else if bluetooth.audioChannelActive {
                            RemoteStatusPill(title: "正在开启麦克风", symbol: "hourglass",
                                             tint: RemotePalette.amber)
                        } else {
                            RemoteStatusPill(title: "待机 · 麦克风已关闭", symbol: "pause.circle",
                                             tint: .secondary)
                        }
                    }

                    RemoteWaveform(level: bluetooth.audioLevel, active: bluetooth.isRecording)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(RemotePalette.indigo.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { audioMetrics }
                        VStack(spacing: 10) { audioMetrics }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Label("语音链路诊断（来自实际音频数据）", systemImage: "stethoscope")
                            .font(.system(size: 12, weight: .semibold))
                        Text(pipelineDiagnostic)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Label("PCM 入队 \(bluetooth.virtualMicrophone.forwardedFrames / 48_000) 秒",
                                  systemImage: "waveform")
                            Label(bluetooth.virtualMicrophone.outputStarted ? "CoreAudio 已启动" :
                                    bluetooth.virtualMicrophone.isRouting ? "等待 CoreAudio 启动" :
                                    bluetooth.virtualMicrophone.lastSessionOutputStarted ?
                                        "上次 CoreAudio 已启动" : "上次输出未启动",
                                  systemImage: "speaker.wave.2")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        Text("系统输入：\(bluetooth.virtualMicrophone.systemInputName) · \(bluetooth.virtualMicrophone.status)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RemotePalette.indigo.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(RemotePalette.indigo)
                        Text("待机时仅监听语音键，不占用音频通道。按实体语音键才开始录音，松开、停止或超时即释放；结束后可导出 WAV。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            onExport()
                        } label: {
                            Label("导出 WAV", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)
                    }
                }
            }
            } else if section == .devices {
                RemoteVirtualMicrophoneSettings(router: bluetooth.virtualMicrophone)
                RemoteCard {
                    VStack(alignment: .leading, spacing: 10) {
                        RemoteSectionTitle(
                            title: "设备配置完成之后",
                            subtitle: "自动路由只能确认已开启，是否能转写仍需实际说话测试",
                            symbol: "arrow.turn.down.right"
                        )
                        Button {
                            section = .live
                        } label: {
                            Label("返回语音工作台，验证音频输入", systemImage: "waveform")
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                }
            } else {
            RemoteCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        RemoteSectionTitle(title: "语音转文字", subtitle: "使用 macOS 原生语音识别 · 本机优先",
                                           symbol: "text.bubble")
                        Spacer(minLength: 8)
                        RemoteStatusPill(title: "仅本地识别", symbol: "lock.shield", tint: RemotePalette.positive)
                    }

                    HStack(spacing: 12) {
                        Picker("识别语言", selection: $transcriber.language) {
                            Text("简体中文").tag("zh-CN")
                            Text("English").tag("en-US")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 230)
                        Spacer(minLength: 4)
                        Button {
                            onImport()
                        } label: {
                            Label("导入 WAV", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                        .disabled(transcriber.isProcessing)

                        if transcriber.isProcessing {
                            Button("取消识别") { transcriber.cancel() }
                                .buttonStyle(RemoteActionButtonStyle())
                        } else {
                            Button {
                                if let data = bluetooth.waveFileData() {
                                    transcriber.recognize(waveData: data)
                                }
                            } label: {
                                Label("识别录音", systemImage: "sparkles")
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(!bluetooth.canSaveWave || bluetooth.isRecording)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if transcriber.isProcessing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "text.alignleft") }
                            Text(transcriber.status)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        ZStack(alignment: .topLeading) {
                            if transcriber.transcript.isEmpty {
                                Text("识别结果会出现在这里，也可以直接编辑文字…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $transcriber.transcript)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .frame(minHeight: 132)
                        }
                        .background(.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.06)))
                    }

                    HStack(alignment: .center, spacing: 10) {
                        Label("不会自动粘贴或发送到 Codex / Claude Code", systemImage: "hand.raised")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
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
        }
    }

    private var voiceIntroduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            RemoteStatusPill(title: "ATVV VOICE", symbol: "waveform", tint: RemotePalette.indigo)
            Text("声音，变成文字。")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            Text(bluetooth.voiceStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(bluetooth.protocolDetails)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button {
                bluetooth.toggleVoiceMode()
            } label: {
                Label(bluetooth.voiceModeEnabled ? "停止语音键监听" : "启用语音键监听",
                      systemImage: bluetooth.voiceModeEnabled ? "stop.circle" : "mic.circle")
            }
            .buttonStyle(RemoteActionButtonStyle(emphasized: !bluetooth.voiceModeEnabled))
            .disabled(!bluetooth.canEnableVoiceMode)
            .help(bluetooth.canEnableVoiceMode ? "切换 ATVV 语音通知" : "请先在设备总览中连接支持 ATVV 的遥控器")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pipelineDiagnostic: String {
        let router = bluetooth.virtualMicrophone
        if !bluetooth.voiceModeEnabled {
            return "ATVV 尚未启用；请先连接遥控器并开启语音键监听。"
        }
        if bluetooth.audioChannelActive && !bluetooth.isRecording {
            return "语音键请求已触发，等待 AUDIO_START。请在连接诊断中查找 MIC_OPEN / CAPS_RESP。"
        }
        if bluetooth.isRecording && bluetooth.audioPacketCount == 0 {
            return "已收到 AUDIO_START，但还没有音频通知。请检查遥控器 → CoreBluetooth 链路。"
        }
        if bluetooth.audioPacketCount > 0 && bluetooth.decodedFrameCount == 0 {
            return "蓝牙音频已收到，但 PCM 解码未成功。请核对 ATVV 版本、SYNC 与帧尺寸。"
        }
        if bluetooth.decodedFrameCount > 0 && router.forwardedFrames == 0 {
            return "PCM 解码成功，但尚未写入虚拟麦克风。请检查路由开关和 BlackHole 状态。"
        }
        if router.forwardedFrames > 0 &&
           !router.outputStarted && !router.lastSessionOutputStarted {
            return "PCM 已进入输出队列，但本次 CoreAudio 未成功启动；请检查 100ms 预缓冲或输出报错。"
        }
        if router.forwardedFrames > 0 && !router.selectedIsDefaultInput &&
           router.autoSwitchInputForVoice && bluetooth.isRecording {
            return "PCM 已提交至 BlackHole，但系统输入未切到该设备。请检查输入切换。"
        }
        if router.forwardedFrames > 0 {
            return "已提交 PCM 到 BlackHole 输出队列。若豆包仍无声音，需验证该队列播放及豆包是否真正采集该输入，不能仅凭入队认定音频已送达。"
        }
        return "待机中。按住语音键后观察音频通知、解码块和虚拟输出是否依次增加。"
    }

    @ViewBuilder
    private var audioMetrics: some View {
        RemoteMetric(title: "音频通知", value: "\(bluetooth.audioPacketCount)",
                     symbol: "waveform.path", tint: RemotePalette.indigo)
        RemoteMetric(title: "解码块", value: "\(bluetooth.decodedFrameCount)",
                     symbol: "waveform.badge.mic", tint: RemotePalette.turquoise)
        RemoteMetric(title: "数据量", value: ByteCountFormatter.string(fromByteCount: Int64(bluetooth.audioByteCount), countStyle: .binary),
                     symbol: "externaldrive", tint: RemotePalette.indigo)
        RemoteMetric(title: "疑似丢帧", value: "\(bluetooth.droppedFrameCount)",
                     symbol: "exclamationmark.circle", tint: bluetooth.droppedFrameCount == 0 ? RemotePalette.positive : RemotePalette.amber)
    }
}
