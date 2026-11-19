import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct RemoteVirtualAudioDevice: Identifiable, Equatable {
    let id: String // Stable CoreAudio device UID, not the transient device ID.
    let name: String
}

/// ATVV PCM -> selected macOS loopback OUTPUT -> application's loopback INPUT.
/// Uses safe on-demand push-to-talk input switching (temporarily switching to
/// BlackHole only while holding the voice key, then restoring the built-in mic)
/// so users never permanently strand WeChat/meeting apps on a virtual mic.
@MainActor
final class RemoteVirtualMicrophoneRouter: ObservableObject {
    @Published private(set) var devices: [RemoteVirtualAudioDevice] = []
    @Published private(set) var physicalInputs: [RemoteVirtualAudioDevice] = []
    @Published private(set) var physicalOutputs: [RemoteVirtualAudioDevice] = []
    @Published var selectedUID: String {
        didSet {
            finishVoiceInputWindow()
            UserDefaults.standard.set(selectedUID, forKey: Self.uidKey)
            if isRouting { endSession() }
            refreshInputState()
        }
    }
    @Published var isEnabled: Bool {
        didSet {
            if !isEnabled { finishVoiceInputWindow() }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { endSession() }
        }
    }
    @Published var autoSwitchInputForVoice: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchInputForVoice, forKey: Self.switchInputKey)
            if !autoSwitchInputForVoice { finishVoiceInputWindow() }
        }
    }
    @Published var suppressSpeakerEchoDuringVoice: Bool {
        didSet {
            UserDefaults.standard.set(suppressSpeakerEchoDuringVoice, forKey: Self.echoSuppressKey)
            if !suppressSpeakerEchoDuringVoice {
                releaseSpeakerEchoSuppressionImmediately()
            }
        }
    }
    @Published var inputRestoreDelaySeconds: Double {
        didSet {
            UserDefaults.standard.set(inputRestoreDelaySeconds, forKey: Self.restoreDelayKey)
        }
    }
    @Published private(set) var systemInputName = "未读取系统输入设备"
    @Published private(set) var systemOutputName = "未读取系统输出设备"
    @Published private(set) var selectedIsDefaultInput = false
    @Published private(set) var outputPointedToVirtualMic = false
    @Published private(set) var inputStatus = "系统默认麦克风尚未配置"
    @Published private(set) var isVoiceInputTemporarilySwitched = false
    @Published private(set) var isRouting = false
    @Published private(set) var outputStarted = false
    @Published private(set) var lastSessionOutputStarted = false
    @Published private(set) var status = "等待检查虚拟音频设备"
    @Published private(set) var forwardedFrames = 0

    /// True when routing to MoteFlow's input-only `MoteFlowMic.driver` (zero AudioQueue output -> zero Screen Sharing echo).
    var isUsingDirectPushMic: Bool {
        MoteFlowMicDriverManager.isDirectPushDevice(selectedUID)
    }

    private static let uidKey = "GoogleRemote.virtualMicOutputUID.v1"
    private static let enabledKey = "GoogleRemote.virtualMicEnabled.v1"
    private static let switchInputKey = "GoogleRemote.virtualMicAutoInput.v1"
    private static let echoSuppressKey = "MoteFlow.suppressSpeakerEchoDuringVoice.v1"
    private static let restoreDelayKey = "MoteFlow.virtualMicRestoreGrace.v1"
    private static let preferredPhysicalInputKey = "MoteFlow.preferredIdleInputUID.v1"
    static let defaultRestoreDelaySeconds = 1.0
    private static let outputRate = ATVVVirtualMicPCM.outputRate

    private let echoSuppressor = SpeakerEchoSuppressor()
    private var queue: AudioQueueRef?
    private var directPushDeviceID: AudioDeviceID?
    private var drainDisposeTask: Task<Void, Never>?
    private var queuedFrames = 0
    private var started = false
    private var sourceRate = 8_000
    private var lastStatusUpdate = Date.distantPast
    private var temporaryPreviousInputUID: String?
    private var preferredPhysicalInputUID: String?
    private var pendingInputRestoration: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        selectedUID = defaults.string(forKey: Self.uidKey) ?? ""
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        autoSwitchInputForVoice = defaults.object(forKey: Self.switchInputKey) as? Bool ?? true
        suppressSpeakerEchoDuringVoice = defaults.object(forKey: Self.echoSuppressKey) as? Bool ?? true
        let storedGrace = defaults.object(forKey: Self.restoreDelayKey) as? Double
        inputRestoreDelaySeconds = min(3, max(0, storedGrace ?? Self.defaultRestoreDelaySeconds))
        preferredPhysicalInputUID = defaults.string(forKey: Self.preferredPhysicalInputKey)
        refreshDevices()
    }

    @discardableResult
    func ensureReadyForIncomingRemoteVoice() -> Bool {
        if devices.isEmpty || !devices.contains(where: { $0.id == selectedUID }) {
            refreshDevices()
        }
        guard !devices.isEmpty else { return false }
        if selectedUID.isEmpty || !devices.contains(where: { $0.id == selectedUID }) {
            if let preferred = devices.first(where: { MoteFlowMicDriverManager.isDirectPushDevice($0.id) })
                ?? devices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") })
                ?? devices.first {
                selectedUID = preferred.id
            }
        }
        if !isEnabled {
            isEnabled = true
        }
        return devices.contains(where: { $0.id == selectedUID })
    }

    func switchDefaultOutputAwayFromVirtualMic() {
        refreshDevices()
        guard let target = physicalOutputs.first(where: {
            let low = $0.name.lowercased()
            return low.contains("扬声器") || low.contains("speaker") || low.contains("mac")
        }) ?? physicalOutputs.first,
              let targetID = CoreAudioDeviceQuery.idForUID(target.id) else {
            inputStatus = "未找到可切换的实体扬声器输出设备，请在「系统设置 → 声音 → 输出」手动更改。"
            return
        }
        let result = CoreAudioDeviceQuery.setDefaultOutputID(targetID)
        refreshInputState()
        if result == noErr {
            inputStatus = "已将系统声音输出切回「\(target.name)」，BlackHole 仅用于麦克风通道，消除屏幕共享回音。"
        } else {
            inputStatus = "切换系统声音输出失败（CoreAudio \(result)）。"
        }
    }

    // MARK: - Anti-Echo Speaker Suppression Delegation

    func engageSpeakerEchoSuppression() {
        // Input-only MoteFlowMic.driver produces zero audio output streams,
        // so speakers never need to be muted during speech.
        guard !isUsingDirectPushMic else { return }
        echoSuppressor.engage(
            enabled: suppressSpeakerEchoDuringVoice,
            defaultOutputID: CoreAudioDeviceQuery.defaultOutputID(),
            virtualMicUID: selectedUID
        )
    }

    func scheduleSpeakerEchoSuppressionRelease(delayMilliseconds: Int = 260) {
        echoSuppressor.scheduleRelease(delayMilliseconds: delayMilliseconds)
    }

    func releaseSpeakerEchoSuppressionImmediately() {
        echoSuppressor.releaseImmediately()
    }

    // MARK: - Safe On-Demand Input Routing & Restoration

    func chooseIdleSystemInput(_ uid: String) {
        guard !isVoiceInputTemporarilySwitched && !isRouting &&
              selectedIsDefaultInput &&
              physicalInputs.contains(where: { $0.id == uid }),
              let target = CoreAudioDeviceQuery.idForUID(uid),
              CoreAudioDeviceQuery.inputSupportsCapture(target) else {
            inputStatus = "当前正在语音采集，或目标不是可用的麦克风，无法修改。"
            return
        }
        let result = CoreAudioDeviceQuery.setDefaultInputID(target)
        refreshInputState()
        if result == noErr && !selectedIsDefaultInput {
            preferredPhysicalInputUID = uid
            UserDefaults.standard.set(uid, forKey: Self.preferredPhysicalInputKey)
            inputStatus = "空闲麦克风已恢复为「\(systemInputName)」；语音键按下时自动切换。"
        } else {
            inputStatus = "恢复系统麦克风失败（CoreAudio \(result)）。"
        }
    }

    func refreshInputState() {
        if let out = CoreAudioDeviceQuery.defaultOutputID() {
            let outName = CoreAudioDeviceQuery.deviceString(out, selector: kAudioObjectPropertyName) ?? "未知输出"
            let outUID = CoreAudioDeviceQuery.deviceString(out, selector: kAudioDevicePropertyDeviceUID) ?? ""
            systemOutputName = outName
            let low = outName.lowercased()
            outputPointedToVirtualMic = (!selectedUID.isEmpty && outUID == selectedUID) ||
                low.contains("blackhole") || low.contains("loopback")
        } else {
            systemOutputName = "未检测到输出设备"
            outputPointedToVirtualMic = false
        }

        guard let current = CoreAudioDeviceQuery.defaultInputID() else {
            systemInputName = "无法读取系统默认麦克风"
            selectedIsDefaultInput = false
            return
        }
        systemInputName = CoreAudioDeviceQuery.deviceString(current, selector: kAudioObjectPropertyName) ??
            "未知输入设备"
        selectedIsDefaultInput =
            CoreAudioDeviceQuery.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID
        if let uid = CoreAudioDeviceQuery.deviceString(current, selector: kAudioDevicePropertyDeviceUID),
           physicalInputs.contains(where: { $0.id == uid }),
           uid != selectedUID {
            preferredPhysicalInputUID = uid
            UserDefaults.standard.set(uid, forKey: Self.preferredPhysicalInputKey)
        }
    }

    private func recoveryInputUID() -> String? {
        if let preferredPhysicalInputUID,
           physicalInputs.contains(where: { $0.id == preferredPhysicalInputUID }),
           let id = CoreAudioDeviceQuery.idForUID(preferredPhysicalInputUID),
           CoreAudioDeviceQuery.inputSupportsCapture(id) {
            return preferredPhysicalInputUID
        }
        let builtIn = physicalInputs.filter {
            let name = $0.name.lowercased()
            return name.contains("macbook") || name.contains("built-in") ||
                   name.contains("内建") || name.contains("内置")
        }
        if builtIn.count == 1 { return builtIn[0].id }
        return physicalInputs.count == 1 ? physicalInputs[0].id : nil
    }

    func prepareVoiceInputWindow() {
        pendingInputRestoration?.cancel()
        pendingInputRestoration = nil
        engageSpeakerEchoSuppression()

        guard autoSwitchInputForVoice && isEnabled, !isVoiceInputTemporarilySwitched,
              let targetID = CoreAudioDeviceQuery.idForUID(selectedUID),
              CoreAudioDeviceQuery.inputSupportsCapture(targetID),
              let previous = CoreAudioDeviceQuery.defaultInputID() else { return }
        if previous == targetID {
            if temporaryPreviousInputUID == nil, let recovered = recoveryInputUID() {
                temporaryPreviousInputUID = recovered
                isVoiceInputTemporarilySwitched = true
                inputStatus = "检测到系统原本已选 BlackHole；松开语音键后将自动恢复实体麦克风。"
            }
            refreshInputState()
            return
        }
        guard let oldUID = CoreAudioDeviceQuery.deviceString(previous, selector: kAudioDevicePropertyDeviceUID)
        else { return }
        let result = CoreAudioDeviceQuery.setDefaultInputID(targetID)
        refreshInputState()
        if result == noErr && selectedIsDefaultInput {
            temporaryPreviousInputUID = oldUID
            isVoiceInputTemporarilySwitched = true
            inputStatus = "说话中：临时切换至 BlackHole，松开后自动恢复「\(CoreAudioDeviceQuery.deviceString(previous, selector: kAudioObjectPropertyName) ?? "原麦克风")」。"
        } else {
            inputStatus = "自动切换麦克风失败（CoreAudio \(result)）；请检查 BlackHole 设备。"
        }
    }

    func scheduleVoiceInputRestoration() {
        scheduleSpeakerEchoSuppressionRelease()
        guard temporaryPreviousInputUID != nil else { return }
        pendingInputRestoration?.cancel()
        let delay = min(3, max(0, inputRestoreDelaySeconds))
        guard delay > 0 else {
            finishVoiceInputWindow()
            return
        }
        inputStatus = "录音已停止，\(String(format: "%.2f", delay)) 秒后恢复原麦克风（豆包收尾转写中）"
        pendingInputRestoration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.finishVoiceInputWindow()
        }
    }

    func finishVoiceInputWindow() {
        releaseSpeakerEchoSuppressionImmediately()
        pendingInputRestoration?.cancel()
        pendingInputRestoration = nil
        guard let oldUID = temporaryPreviousInputUID else { return }
        temporaryPreviousInputUID = nil
        isVoiceInputTemporarilySwitched = false
        guard let current = CoreAudioDeviceQuery.defaultInputID(),
              CoreAudioDeviceQuery.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID,
              let original = CoreAudioDeviceQuery.idForUID(oldUID),
              CoreAudioDeviceQuery.inputSupportsCapture(original) else {
            refreshInputState()
            inputStatus = "原麦克风未自动恢复：设备已变化或已断开，请手动确认输入设置。"
            return
        }
        let result = CoreAudioDeviceQuery.setDefaultInputID(original)
        refreshInputState()
        inputStatus = result == noErr
            ? "语音结束：已恢复系统麦克风「\(systemInputName)」。"
            : "恢复原麦克风失败（CoreAudio \(result)）。"
    }

    func refreshDevices() {
        let ids = CoreAudioDeviceQuery.allDeviceIDs()
        guard !ids.isEmpty else {
            devices = []
            status = "没有找到音频设备"
            return
        }
        devices = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = CoreAudioDeviceQuery.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = CoreAudioDeviceQuery.deviceString(id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let lower = name.lowercased()
            guard MoteFlowMicDriverManager.isDirectPushDevice(uid) ||
                  lower.contains("moteflow mic") ||
                  lower.contains("blackhole") || lower.contains("loopback") ||
                  lower.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }.sorted { lhs, rhs in
            let lhsDirect = MoteFlowMicDriverManager.isDirectPushDevice(lhs.id)
            let rhsDirect = MoteFlowMicDriverManager.isDirectPushDevice(rhs.id)
            if lhsDirect != rhsDirect { return lhsDirect }
            return lhs.name < rhs.name
        }
        physicalInputs = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = CoreAudioDeviceQuery.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = CoreAudioDeviceQuery.deviceString(id, selector: kAudioDevicePropertyDeviceUID),
                  CoreAudioDeviceQuery.inputSupportsCapture(id) else { return nil }
            let lowered = name.lowercased()
            guard !MoteFlowMicDriverManager.isDirectPushDevice(uid),
                  !lowered.contains("moteflow mic"),
                  !lowered.contains("blackhole"), !lowered.contains("loopback"),
                  !lowered.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }
        physicalOutputs = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = CoreAudioDeviceQuery.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = CoreAudioDeviceQuery.deviceString(id, selector: kAudioDevicePropertyDeviceUID),
                  CoreAudioDeviceQuery.outputSupportsPlayback(id) else { return nil }
            let lowered = name.lowercased()
            guard !MoteFlowMicDriverManager.isDirectPushDevice(uid),
                  !lowered.contains("moteflow mic"),
                  !lowered.contains("blackhole"), !lowered.contains("loopback"),
                  !lowered.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }
        if selectedUID.isEmpty, let preferred = devices.first(where: { MoteFlowMicDriverManager.isDirectPushDevice($0.id) }) ?? devices.first {
            selectedUID = preferred.id
        }
        refreshInputState()
        if devices.isEmpty {
            status = "未检测到 BlackHole 等虚拟麦克风。请先安装驱动，再点「刷新设备」。"
        } else if selectedUID.isEmpty {
            status = "已检测到虚拟音频设备，请选择一个设备并启用路由。"
        } else if !devices.contains(where: { $0.id == selectedUID }) {
            status = "之前选择的虚拟设备已断开，请重新选择。"
        } else if !isRouting {
            status = isEnabled ? "虚拟麦克风已就绪，等待遥控器开始语音会话。" :
                "设备已检测到；开启路由后才会发送遥控器音频。"
        }
    }

    // MARK: - Direct-Push (MoteFlowMic.driver) & AudioQueue (BlackHole Fallback) Streaming

    func beginSession(sourceRate: Int) {
        drainDisposeTask?.cancel()
        drainDisposeTask = nil
        endSession()
        guard isEnabled else { return }
        guard let selected = devices.first(where: { $0.id == selectedUID }) else {
            status = "没有选中可用的虚拟音频设备；ATVV 正常录音，但不会送往豆包。"
            return
        }
        guard sourceRate == 8_000 || sourceRate == 16_000 else {
            status = "暂不支持 \(sourceRate) Hz 的遥控器音频格式"
            return
        }
        self.sourceRate = sourceRate

        if MoteFlowMicDriverManager.isDirectPushDevice(selected.id) {
            guard let deviceID = CoreAudioDeviceQuery.idForUID(selected.id) else {
                status = "未找到已加载的 MoteFlow Mic 设备，请刷新或重新安装驱动。"
                return
            }
            let resetStatus = MoteFlowMicDriverManager.resetBuffer(deviceID: deviceID)
            guard resetStatus == noErr else {
                status = "无法连接 MoteFlow Mic 驱动通道（CoreAudio \(resetStatus)）。"
                return
            }
            directPushDeviceID = deviceID
            queuedFrames = 0
            forwardedFrames = 0
            started = true
            outputStarted = true
            lastSessionOutputStarted = true
            isRouting = true
            status = "正在零回声直推语音到「\(selected.name)」（纯输入无输出流）"
            return
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: Double(Self.outputRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var created: AudioQueueRef?
        let makeStatus = AudioQueueNewOutput(
            &format,
            { _, audioQueue, buffer in
                _ = AudioQueueFreeBuffer(audioQueue, buffer)
            },
            nil, nil, nil, 0, &created
        )
        guard makeStatus == noErr, let created else {
            status = "CoreAudio 输出初始化失败：\(makeStatus)"
            return
        }
        var unmanagedUID = Unmanaged.passUnretained(selected.id as CFString)
        let routeStatus = withUnsafePointer(to: &unmanagedUID) {
            AudioQueueSetProperty(
                created,
                kAudioQueueProperty_CurrentDevice,
                $0,
                UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            )
        }
        guard routeStatus == noErr else {
            _ = AudioQueueDispose(created, true)
            status = "无法连接虚拟音频输出「\(selected.name)」：\(routeStatus)"
            return
        }
        queue = created
        queuedFrames = 0
        forwardedFrames = 0
        started = false
        outputStarted = false
        lastSessionOutputStarted = false
        isRouting = true
        status = "已连接「\(selected.name)」输出队列，等待首帧语音播放…"
    }

    func write(samples: [Int16], sampleRate: Int) {
        guard isEnabled, !samples.isEmpty else { return }
        if isUsingDirectPushMic {
            if !isRouting || directPushDeviceID == nil || sourceRate != sampleRate {
                beginSession(sourceRate: sampleRate)
            }
            guard isRouting, let deviceID = directPushDeviceID else { return }
            let stereo = ATVVVirtualMicPCM.stereo48k(samples: samples, sourceRate: sampleRate)
            let pushStatus = MoteFlowMicDriverManager.pushStereo48kPCM(deviceID: deviceID, samples: stereo)
            guard pushStatus == noErr else {
                status = "直推 PCM 到 MoteFlow Mic 失败：\(pushStatus)"
                endSession()
                return
            }
            let frames = stereo.count / 2
            queuedFrames += frames
            forwardedFrames += frames
            if Date().timeIntervalSince(lastStatusUpdate) >= 1 {
                lastStatusUpdate = Date()
                status = "已向 MoteFlow Mic 零回声直推 \(forwardedFrames / 48_000) 秒 PCM"
            }
            return
        }

        if !isRouting || queue == nil || sourceRate != sampleRate {
            beginSession(sourceRate: sampleRate)
        }
        guard isRouting, let queue else { return }
        let stereo = ATVVVirtualMicPCM.stereo48k(samples: samples, sourceRate: sampleRate)
        let byteCount = stereo.count * MemoryLayout<Int16>.stride
        guard byteCount > 0, byteCount <= Int(UInt32.max) else { return }
        var buffer: AudioQueueBufferRef?
        let allocated = AudioQueueAllocateBuffer(queue, UInt32(byteCount), &buffer)
        guard allocated == noErr, let buffer else {
            status = "虚拟麦克风缓冲分配失败：\(allocated)"
            return
        }
        stereo.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                memcpy(buffer.pointee.mAudioData, source, byteCount)
            }
        }
        buffer.pointee.mAudioDataByteSize = UInt32(byteCount)
        let enqueued = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard enqueued == noErr else {
            _ = AudioQueueFreeBuffer(queue, buffer)
            status = "无法向虚拟麦克风送出音频：\(enqueued)"
            return
        }
        let frames = stereo.count / 2
        queuedFrames += frames
        forwardedFrames += frames
        if !started && queuedFrames >= 2_400 {
            let startedStatus = AudioQueueStart(queue, nil)
            if startedStatus == noErr {
                started = true
                outputStarted = true
                lastSessionOutputStarted = true
                status = "正在实时向虚拟麦克风输出遥控器语音（48 kHz / 双声道）"
            } else {
                status = "虚拟麦克风播放启动失败：\(startedStatus)"
                endSession()
            }
        }
        if started && Date().timeIntervalSince(lastStatusUpdate) >= 1 {
            lastStatusUpdate = Date()
            status = "已向虚拟音频播放队列提交 \(forwardedFrames / 48_000) 秒 PCM"
        }
    }

    func endSessionGracefully() {
        if let deviceID = directPushDeviceID {
            directPushDeviceID = nil
            queuedFrames = 0
            started = false
            outputStarted = false
            isRouting = false
            status = "语音会话收尾中，正在等待应用读取末尾缓冲…"
            drainDisposeTask?.cancel()
            drainDisposeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                _ = MoteFlowMicDriverManager.resetBuffer(deviceID: deviceID)
                if self?.isRouting == false {
                    self?.status = "语音会话已结束，MoteFlow Mic 直推已停止。"
                }
            }
            return
        }
        guard let activeQueue = queue else {
            endSession()
            return
        }
        if queuedFrames > 0 && !started {
            _ = AudioQueueStart(activeQueue, nil)
        }
        _ = AudioQueueFlush(activeQueue)
        queue = nil
        queuedFrames = 0
        started = false
        outputStarted = false
        isRouting = false
        status = "语音会话收尾中，正在排空末尾音频缓冲…"
        drainDisposeTask?.cancel()
        drainDisposeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            _ = AudioQueueStop(activeQueue, true)
            _ = AudioQueueDispose(activeQueue, true)
            if self?.isRouting == false {
                self?.status = "语音会话已结束，虚拟麦克风输出已停止。"
            }
        }
    }

    func endSession() {
        if let deviceID = directPushDeviceID {
            _ = MoteFlowMicDriverManager.resetBuffer(deviceID: deviceID)
            directPushDeviceID = nil
        }
        if let queue {
            _ = AudioQueueStop(queue, true)
            _ = AudioQueueDispose(queue, true)
        }
        queue = nil
        queuedFrames = 0
        started = false
        outputStarted = false
        if isRouting {
            isRouting = false
            status = "语音会话已结束，虚拟麦克风输出已停止。"
        }
    }

    func restoreInputOnShutdown() {
        releaseSpeakerEchoSuppressionImmediately()
        finishVoiceInputWindow()
    }
}
