import AudioToolbox
import Combine
import CoreAudio
import Foundation
import SwiftUI

struct RemoteVirtualAudioDevice: Identifiable, Equatable {
    let id: String // Stable CoreAudio device UID, not the transient device ID.
    let name: String
}

/// ATVV PCM -> selected macOS loopback OUTPUT -> application's loopback INPUT.
/// Mac output always remains unchanged. With explicit user consent, the
/// system-default INPUT can also be switched for apps that follow it.
@MainActor
final class RemoteVirtualMicrophoneRouter: ObservableObject {
    @Published private(set) var devices: [RemoteVirtualAudioDevice] = []
    @Published private(set) var physicalInputs: [RemoteVirtualAudioDevice] = []
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
    @Published private(set) var systemInputName = "未读取系统输入设备"
    @Published private(set) var selectedIsDefaultInput = false
    @Published private(set) var inputStatus = "系统默认麦克风尚未配置"
    @Published private(set) var isVoiceInputTemporarilySwitched = false
    var canRestoreManualInput: Bool { manualPreviousInputUID != nil }
    @Published private(set) var isRouting = false
    @Published private(set) var status = "等待检查虚拟音频设备"
    @Published private(set) var forwardedFrames = 0

    private static let uidKey = "GoogleRemote.virtualMicOutputUID.v1"
    private static let enabledKey = "GoogleRemote.virtualMicEnabled.v1"
    private static let switchInputKey = "GoogleRemote.virtualMicAutoInput.v1"
    private static let outputRate = ATVVVirtualMicPCM.outputRate
    private var queue: AudioQueueRef?
    private var queuedFrames = 0
    private var started = false
    private var sourceRate = 8_000
    private var lastStatusUpdate = Date.distantPast
    /// Persisted only in memory; never silently modify the Mac's default
    /// input on a future launch to recover from a stale UserDefaults value.
    private var temporaryPreviousInputUID: String?
    private var manualPreviousInputUID: String?

    init(defaults: UserDefaults = .standard) {
        selectedUID = defaults.string(forKey: Self.uidKey) ?? ""
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        // Newly configured installations should never permanently switch the
        // default system microphone just because BlackHole is installed.
        autoSwitchInputForVoice = defaults.object(forKey: Self.switchInputKey) as? Bool ?? true
        refreshDevices()
    }

    /// Preferred one-click configuration. The input stays with other apps
    /// while idle; only the remote voice session temporarily uses BlackHole.
    func configureOnDemandInput() {
        guard isEnabled && devices.contains(where: { $0.id == selectedUID }) else {
            inputStatus = "先启用虚拟麦克风路由并选择可用设备。"
            return
        }
        autoSwitchInputForVoice = true
        if manualPreviousInputUID != nil {
            restoreManuallySelectedInput()
        }
        refreshInputState()
        inputStatus = selectedIsDefaultInput
            ? "已开启按键式切换，但系统当前仍选择 BlackHole。请在下方选回平时使用的麦克风。"
            : "已启用按键式切换：平时使用「\(systemInputName)」，只在说话时切到 BlackHole。"
    }

    func chooseIdleSystemInput(_ uid: String) {
        guard !isVoiceInputTemporarilySwitched && !isRouting &&
              selectedIsDefaultInput &&
              physicalInputs.contains(where: { $0.id == uid }),
              let target = Self.idForUID(uid), Self.inputSupportsCapture(target) else {
            inputStatus = "当前正在语音采集，或目标不是可用的麦克风，无法修改。"
            return
        }
        let result = Self.setDefaultInputID(target)
        refreshInputState()
        if result == noErr && !selectedIsDefaultInput {
            manualPreviousInputUID = nil
            inputStatus = "空闲麦克风已恢复为「\(systemInputName)」；语音键按下时自动切换。"
        } else {
            inputStatus = "恢复系统麦克风失败（CoreAudio \(result)）。"
        }
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &property, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func setDefaultInputID(_ id: AudioDeviceID) -> OSStatus {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &property, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    private static func inputSupportsCapture(_ id: AudioDeviceID) -> Bool {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            memory.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func idForUID(_ uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        return ids.first { deviceString($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    func refreshInputState() {
        guard let current = Self.defaultInputID() else {
            systemInputName = "无法读取系统默认麦克风"
            selectedIsDefaultInput = false
            return
        }
        systemInputName = Self.deviceString(current, selector: kAudioObjectPropertyName) ??
            "未知输入设备"
        selectedIsDefaultInput =
            Self.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID
    }

    /// One-click, explicitly user-initiated input selection. Does not touch
    /// the output device or another application's private microphone setting.
    func useSelectedAsDefaultInput() {
        guard isEnabled else {
            inputStatus = "请先开启遥控器实时音频路由，再切换系统麦克风。"
            return
        }
        guard let selected = devices.first(where: { $0.id == selectedUID }),
              let targetID = Self.idForUID(selectedUID),
              Self.inputSupportsCapture(targetID) else {
            inputStatus = "目标虚拟设备未加载，或不支持麦克风输入。请先刷新设备。"
            return
        }
        guard let previous = Self.defaultInputID() else {
            inputStatus = "无法查询原来的麦克风，已取消切换。"
            return
        }
        if previous == targetID {
            refreshInputState()
            inputStatus = "系统默认麦克风已是「\(selected.name)」，无须重复设置。"
            return
        }
        let oldUID = Self.deviceString(previous, selector: kAudioDevicePropertyDeviceUID)
        let result = Self.setDefaultInputID(targetID)
        refreshInputState()
        if result == noErr && selectedIsDefaultInput {
            manualPreviousInputUID = oldUID
            inputStatus = "已将系统默认麦克风设为「\(selected.name)」；豆包需设为「系统默认」。"
        } else {
            inputStatus = "切换系统输入失败（CoreAudio \(result)），可能是设备不可用或权限受限。"
        }
    }

    /// Called BEFORE sending Doubao's hotkey, so it picks up the new input.
    func prepareVoiceInputWindow() {
        guard autoSwitchInputForVoice && isEnabled, !isVoiceInputTemporarilySwitched,
              let targetID = Self.idForUID(selectedUID),
              Self.inputSupportsCapture(targetID),
              let previous = Self.defaultInputID() else { return }
        if previous == targetID { refreshInputState(); return }
        guard let oldUID = Self.deviceString(previous, selector: kAudioDevicePropertyDeviceUID)
        else { return }
        let result = Self.setDefaultInputID(targetID)
        refreshInputState()
        if result == noErr && selectedIsDefaultInput {
            temporaryPreviousInputUID = oldUID
            isVoiceInputTemporarilySwitched = true
            inputStatus = "语音已启用：临时切换至 BlackHole，结束时恢复「\(Self.deviceString(previous, selector: kAudioObjectPropertyName) ?? "原麦克风")」。"
        } else {
            inputStatus = "自动切换麦克风失败（CoreAudio \(result)）；请检查 BlackHole 设备。"
        }
    }

    /// Restores only if the current input is still the device WE installed:
    /// never undo an independent switch made by the user or another app.
    func finishVoiceInputWindow() {
        guard let oldUID = temporaryPreviousInputUID else { return }
        temporaryPreviousInputUID = nil
        isVoiceInputTemporarilySwitched = false
        guard let current = Self.defaultInputID(),
              Self.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID,
              let original = Self.idForUID(oldUID),
              Self.inputSupportsCapture(original) else {
            refreshInputState()
            inputStatus = "原麦克风未自动恢复：设备已变化或已断开，请手动确认输入设置。"
            return
        }
        let result = Self.setDefaultInputID(original)
        refreshInputState()
        inputStatus = result == noErr
            ? "语音结束：已恢复系统麦克风「\(systemInputName)」。"
            : "恢复原麦克风失败（CoreAudio \(result)）。"
    }

    func restoreManuallySelectedInput() {
        guard let saved = manualPreviousInputUID else { return }
        manualPreviousInputUID = nil
        guard let current = Self.defaultInputID(),
              Self.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID,
              let previous = Self.idForUID(saved) else {
            refreshInputState()
            inputStatus = "默认输入已被其他操作更改，未覆盖当前设备。"
            return
        }
        let result = Self.setDefaultInputID(previous)
        refreshInputState()
        inputStatus = result == noErr ? "已恢复「\(systemInputName)」。" :
            "恢复麦克风失败（CoreAudio \(result)）。"
    }

    /// Only known loopback device names are offered, preventing accidental
    /// playback of users' private dictation through physical speakers.
    func refreshDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &byteSize) == noErr else {
            devices = []
            status = "无法读取 CoreAudio 设备清单"
            return
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(byteSize) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &byteSize, &ids) == noErr else {
            devices = []
            status = "没有找到音频设备"
            return
        }
        devices = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = Self.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = Self.deviceString(id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            let lower = name.lowercased()
            guard lower.contains("blackhole") || lower.contains("loopback") ||
                  lower.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }
        physicalInputs = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = Self.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = Self.deviceString(id, selector: kAudioDevicePropertyDeviceUID),
                  Self.inputSupportsCapture(id) else { return nil }
            let lowered = name.lowercased()
            guard !lowered.contains("blackhole"), !lowered.contains("loopback"),
                  !lowered.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }
        // A single installed virtual microphone should never force another
        // round-trip through settings just to choose the obvious device.
        if selectedUID.isEmpty, devices.count == 1, let first = devices.first {
            selectedUID = first.id
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

    private static func deviceString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value as String
    }

    func beginSession(sourceRate: Int) {
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
        var deviceUID = selected.id as CFString
        let routeStatus = withUnsafePointer(to: &deviceUID) {
            AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice,
                                  $0, UInt32(MemoryLayout<CFString>.size))
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
        isRouting = true
        status = "已连接「\(selected.name)」，等待音频预缓冲；请在豆包中将麦克风选为此设备。"
    }

    func write(samples: [Int16], sampleRate: Int) {
        guard isRouting, let queue, !samples.isEmpty else { return }
        guard sourceRate == sampleRate else {
            beginSession(sourceRate: sampleRate)
            return
        }
        // Shared, unit-tested ATVV mono to BlackHole stereo converter.
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
        if !started && queuedFrames >= 4_800 { // ~100 ms pre-roll.
            let startedStatus = AudioQueueStart(queue, nil)
            if startedStatus == noErr {
                started = true
                status = "正在实时向虚拟麦克风输出遥控器语音（48 kHz / 双声道）"
            } else {
                status = "虚拟麦克风播放启动失败：\(startedStatus)"
                endSession()
            }
        }
        if started && Date().timeIntervalSince(lastStatusUpdate) >= 1 {
            lastStatusUpdate = Date()
            status = "已输出 \(forwardedFrames / 48_000) 秒遥控器音频到虚拟麦克风"
        }
    }

    func endSession() {
        if let queue {
            _ = AudioQueueStop(queue, true)
            _ = AudioQueueDispose(queue, true)
        }
        queue = nil
        queuedFrames = 0
        started = false
        if isRouting {
            isRouting = false
            status = "语音会话已结束，虚拟麦克风输出已停止。"
        }
    }

    func restoreInputOnShutdown() {
        finishVoiceInputWindow()
    }
}

/// Shared in Settings and Voice; no need to change the Mac's default output.
struct RemoteVirtualMicrophoneSettings: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BlackHoleDriverManagementCard(router: router)
            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    RemoteSectionTitle(title: "遥控器虚拟麦克风",
                                       subtitle: "ATVV PCM → BlackHole 输出 → 豆包麦克风输入",
                                       symbol: "waveform")
                    Spacer(minLength: 0)
                    Button("刷新设备", systemImage: "arrow.clockwise") {
                        router.refreshDevices()
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                }
                if router.devices.isEmpty {
                    Label("没有发现 BlackHole 等虚拟音频驱动。需要先安装 BlackHole 2ch。",
                          systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(RemotePalette.amber)
                    Link("BlackHole 官方安装说明", destination:
                            URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
                        .font(.system(size: 12))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 9)], spacing: 9) {
                        ForEach(router.devices) { device in
                            RemoteVisualOption(
                                title: device.name,
                                subtitle: "专用音频输出 → 同名麦克风输入",
                                symbol: "waveform.badge.mic",
                                selected: router.selectedUID == device.id,
                                compact: true,
                                action: { router.selectedUID = device.id }
                            )
                        }
                    }
                    Toggle("把遥控器语音实时送到所选虚拟麦克风", isOn: $router.isEnabled)
                        .toggleStyle(.switch)
                        .disabled(router.selectedUID.isEmpty ||
                                  !router.devices.contains(where: { $0.id == router.selectedUID }))
                }
                HStack(spacing: 9) {
                    Image(systemName: router.isRouting ? "waveform" : "info.circle")
                        .foregroundStyle(router.isRouting ? RemotePalette.positive : RemotePalette.indigo)
                    Text(router.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !router.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.circle")
                                .foregroundStyle(RemotePalette.indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("系统当前麦克风：\(router.systemInputName)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(router.selectedIsDefaultInput
                                     ? "已指向当前虚拟麦克风"
                                     : "豆包跟随系统默认输入时，将使用这个设备")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        Button {
                            router.configureOnDemandInput()
                        } label: {
                            Label("一键启用按需语音输入",
                                  systemImage: "mic.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: !router.autoSwitchInputForVoice))
                        .disabled(!router.isEnabled || router.selectedUID.isEmpty)
                        Toggle("仅在按语音键时切换到 BlackHole，结束后恢复原麦克风",
                               isOn: $router.autoSwitchInputForVoice)
                            .toggleStyle(.switch)
                            .disabled(!router.isEnabled || router.selectedUID.isEmpty)
                        if router.selectedIsDefaultInput && !router.isVoiceInputTemporarilySwitched &&
                           !router.isRouting {
                            Label("当前系统默认输入仍为 BlackHole。平时建议切回内建或其他实体麦克风，以免影响别的语音软件。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(RemotePalette.amber)
                                .fixedSize(horizontal: false, vertical: true)
                            if router.canRestoreManualInput {
                                Button("恢复之前使用的麦克风") {
                                    router.restoreManuallySelectedInput()
                                }
                                .buttonStyle(RemoteActionButtonStyle())
                            } else if !router.physicalInputs.isEmpty {
                                Text("选择平时使用的麦克风：")
                                    .font(.system(size: 11, weight: .medium))
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 8)],
                                          spacing: 8) {
                                    ForEach(router.physicalInputs) { device in
                                        RemoteVisualOption(
                                            title: device.name,
                                            subtitle: "恢复为空闲输入设备",
                                            symbol: "mic",
                                            selected: false,
                                            compact: true,
                                            action: { router.chooseIdleSystemInput(device.id) }
                                        )
                                    }
                                }
                            }
                        }
                        Text(router.inputStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(RemotePalette.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                }
                Text("待机时不会打开 BlackHole 音频输出，也不会占用音频通知；只有遥控器语音会话才启动音频。建议豆包设置为「跟随系统默认麦克风」；如果豆包固定了独立麦克风，需在豆包内修改一次。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
