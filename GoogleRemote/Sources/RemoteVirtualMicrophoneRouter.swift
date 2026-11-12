import AudioToolbox
import Combine
import CoreAudio
import Foundation
import SwiftUI

struct RemoteVirtualAudioDevice: Identifiable, Equatable {
    let id: String // Stable CoreAudio device UID, not the transient device ID.
    let name: String
}

private enum SavedSpeakerAttenuation {
    case hardwareMute(deviceID: AudioDeviceID)
    case virtualVolume(deviceID: AudioDeviceID, previousVolume: Float32)
}

/// ATVV PCM -> selected macOS loopback OUTPUT -> application's loopback INPUT.
/// Includes automatic anti-echo speaker muting during active voice capture so
/// macOS Screen Sharing (屏幕共享) does not feed echoed voice back into the room.
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
    /// Automatically mutes the Mac's physical/system speaker output ONLY while holding
    /// the voice button, preventing Screen Sharing or speaker playback echo loops.
    @Published var suppressSpeakerEchoDuringVoice: Bool {
        didSet {
            UserDefaults.standard.set(suppressSpeakerEchoDuringVoice, forKey: Self.echoSuppressKey)
            if !suppressSpeakerEchoDuringVoice {
                releaseSpeakerEchoSuppressionImmediately()
            }
        }
    }
    /// Briefly retain the selected virtual input after key-up so dictation
    /// applications can finish flushing their final recognized syllables.
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
    var canRestoreManualInput: Bool { manualPreviousInputUID != nil }
    @Published private(set) var isRouting = false
    @Published private(set) var outputStarted = false
    @Published private(set) var lastSessionOutputStarted = false
    @Published private(set) var status = "等待检查虚拟音频设备"
    @Published private(set) var forwardedFrames = 0

    private static let uidKey = "GoogleRemote.virtualMicOutputUID.v1"
    private static let enabledKey = "GoogleRemote.virtualMicEnabled.v1"
    private static let switchInputKey = "GoogleRemote.virtualMicAutoInput.v1"
    private static let echoSuppressKey = "MoteFlow.suppressSpeakerEchoDuringVoice.v1"
    private static let restoreDelayKey = "MoteFlow.virtualMicRestoreGrace.v1"
    private static let preferredPhysicalInputKey = "MoteFlow.preferredIdleInputUID.v1"
    static let defaultRestoreDelaySeconds = 1.0
    private static let outputRate = ATVVVirtualMicPCM.outputRate

    private var queue: AudioQueueRef?
    private var drainDisposeTask: Task<Void, Never>?
    private var speakerRestoreTask: Task<Void, Never>?
    private var savedSpeakerState: SavedSpeakerAttenuation?
    private var queuedFrames = 0
    private var started = false
    private var sourceRate = 8_000
    private var lastStatusUpdate = Date.distantPast
    private var temporaryPreviousInputUID: String?
    private var manualPreviousInputUID: String?
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

    /// Ensures an installed virtual loopback audio device (such as BlackHole 2ch)
    /// is selected and enabled on the receiving Mac when forwarded LAN voice arrives.
    @discardableResult
    func ensureReadyForIncomingRemoteVoice() -> Bool {
        if devices.isEmpty || !devices.contains(where: { $0.id == selectedUID }) {
            refreshDevices()
        }
        guard !devices.isEmpty else { return false }
        if selectedUID.isEmpty || !devices.contains(where: { $0.id == selectedUID }) {
            if let preferred = devices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }) ?? devices.first {
                selectedUID = preferred.id
            }
        }
        if !isEnabled {
            isEnabled = true
        }
        return devices.contains(where: { $0.id == selectedUID })
    }

    /// Fixes the classic Screen Sharing echo trap where macOS Sound Output was
    /// accidentally set to BlackHole 2ch instead of physical speakers.
    func switchDefaultOutputAwayFromVirtualMic() {
        refreshDevices()
        guard let target = physicalOutputs.first(where: {
            let low = $0.name.lowercased()
            return low.contains("扬声器") || low.contains("speaker") || low.contains("mac")
        }) ?? physicalOutputs.first,
              let targetID = Self.idForUID(target.id) else {
            inputStatus = "未找到可切换的实体扬声器输出设备，请在「系统设置 → 声音 → 输出」手动更改。"
            return
        }
        let status = Self.setDefaultOutputID(targetID)
        refreshInputState()
        if status == noErr {
            inputStatus = "已将系统声音输出切回「\(target.name)」，BlackHole 仅用于麦克风通道，消除屏幕共享回音。"
        } else {
            inputStatus = "切换系统声音输出失败（CoreAudio \(status)）。"
        }
    }

    // MARK: - Anti-Echo Temporary Speaker Suppression (Screen Sharing Safe)

    /// Temporarily mutes the Mac's default speaker output (never BlackHole!) while
    /// speaking into the remote so Screen Sharing / speaker loopback cannot echo.
    func engageSpeakerEchoSuppression() {
        speakerRestoreTask?.cancel()
        speakerRestoreTask = nil
        guard suppressSpeakerEchoDuringVoice, savedSpeakerState == nil,
              let outID = Self.defaultOutputID() else { return }

        let outUID = Self.deviceString(outID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let outName = (Self.deviceString(outID, selector: kAudioObjectPropertyName) ?? "").lowercased()
        // NEVER mute the virtual microphone loopback device itself!
        guard outUID != selectedUID,
              !outName.contains("blackhole"),
              !outName.contains("loopback"),
              !outName.contains("virtual microphone") else {
            return
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(outID, &muteAddr),
           AudioObjectIsPropertySettable(outID, &muteAddr, &settable) == noErr,
           settable.boolValue {
            var currentMute: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(outID, &muteAddr, 0, nil, &size, &currentMute) == noErr,
               currentMute == 0 {
                var muted: UInt32 = 1
                if AudioObjectSetPropertyData(outID, &muteAddr, 0, nil, size, &muted) == noErr {
                    savedSpeakerState = .hardwareMute(deviceID: outID)
                    return
                }
            } else if currentMute == 1 {
                // Already muted by user; leave untouched.
                return
            }
        }

        // Fallback to VirtualMainVolume when HDMI/Virtual audio output has no hardware mute bit
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volSettable: DarwinBoolean = false
        if AudioObjectHasProperty(outID, &volAddr),
           AudioObjectIsPropertySettable(outID, &volAddr, &volSettable) == noErr,
           volSettable.boolValue {
            var currentVol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(outID, &volAddr, 0, nil, &size, &currentVol) == noErr,
               currentVol > 0.005 {
                var zero: Float32 = 0.0
                if AudioObjectSetPropertyData(outID, &volAddr, 0, nil, size, &zero) == noErr {
                    savedSpeakerState = .virtualVolume(deviceID: outID, previousVolume: currentVol)
                }
            }
        }
    }

    func scheduleSpeakerEchoSuppressionRelease(delayMilliseconds: Int = 260) {
        guard savedSpeakerState != nil else { return }
        speakerRestoreTask?.cancel()
        speakerRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.releaseSpeakerEchoSuppressionImmediately()
        }
    }

    func releaseSpeakerEchoSuppressionImmediately() {
        speakerRestoreTask?.cancel()
        speakerRestoreTask = nil
        guard let saved = savedSpeakerState else { return }
        savedSpeakerState = nil

        switch saved {
        case .hardwareMute(let deviceID):
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmuted: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &unmuted)

        case .virtualVolume(let deviceID, let previousVolume):
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var vol = previousVolume
            let size = UInt32(MemoryLayout<Float32>.size)
            _ = AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &vol)
        }
    }

    // MARK: - Input Routing & Restoration

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
            preferredPhysicalInputUID = uid
            UserDefaults.standard.set(uid, forKey: Self.preferredPhysicalInputKey)
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

    private static func defaultOutputID() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    private static func setDefaultOutputID(_ id: AudioDeviceID) -> OSStatus {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &property, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    private static func streamSupportsChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
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

    private static func inputSupportsCapture(_ id: AudioDeviceID) -> Bool {
        streamSupportsChannels(id, scope: kAudioObjectPropertyScopeInput)
    }

    private static func outputSupportsPlayback(_ id: AudioDeviceID) -> Bool {
        streamSupportsChannels(id, scope: kAudioObjectPropertyScopeOutput)
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
        if let out = Self.defaultOutputID() {
            let outName = Self.deviceString(out, selector: kAudioObjectPropertyName) ?? "未知输出"
            let outUID = Self.deviceString(out, selector: kAudioDevicePropertyDeviceUID) ?? ""
            systemOutputName = outName
            let low = outName.lowercased()
            outputPointedToVirtualMic = (!selectedUID.isEmpty && outUID == selectedUID) ||
                low.contains("blackhole") || low.contains("loopback")
        } else {
            systemOutputName = "未检测到输出设备"
            outputPointedToVirtualMic = false
        }

        guard let current = Self.defaultInputID() else {
            systemInputName = "无法读取系统默认麦克风"
            selectedIsDefaultInput = false
            return
        }
        systemInputName = Self.deviceString(current, selector: kAudioObjectPropertyName) ??
            "未知输入设备"
        selectedIsDefaultInput =
            Self.deviceString(current, selector: kAudioDevicePropertyDeviceUID) == selectedUID
        if let uid = Self.deviceString(current, selector: kAudioDevicePropertyDeviceUID),
           physicalInputs.contains(where: { $0.id == uid }),
           uid != selectedUID {
            preferredPhysicalInputUID = uid
            UserDefaults.standard.set(uid, forKey: Self.preferredPhysicalInputKey)
        }
    }

    private func recoveryInputUID() -> String? {
        if let preferredPhysicalInputUID,
           physicalInputs.contains(where: { $0.id == preferredPhysicalInputUID }),
           let id = Self.idForUID(preferredPhysicalInputUID),
           Self.inputSupportsCapture(id) {
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

    /// Called BEFORE sending Doubao's hotkey, so it picks up the new input and suppresses speaker echo.
    func prepareVoiceInputWindow() {
        pendingInputRestoration?.cancel()
        pendingInputRestoration = nil
        engageSpeakerEchoSuppression()

        guard autoSwitchInputForVoice && isEnabled, !isVoiceInputTemporarilySwitched,
              let targetID = Self.idForUID(selectedUID),
              Self.inputSupportsCapture(targetID),
              let previous = Self.defaultInputID() else { return }
        if previous == targetID {
            if temporaryPreviousInputUID == nil, let recovered = recoveryInputUID() {
                temporaryPreviousInputUID = recovered
                isVoiceInputTemporarilySwitched = true
                inputStatus = "检测到系统原本已选 BlackHole；松开语音键后恢复实体麦克风。"
            } else if temporaryPreviousInputUID == nil {
                inputStatus = "系统原本已选 BlackHole，未能确定原麦克风；请在设备页选择一次常用输入。"
            }
            refreshInputState()
            return
        }
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

    func scheduleVoiceInputRestoration() {
        scheduleSpeakerEchoSuppressionRelease()
        guard temporaryPreviousInputUID != nil else { return }
        pendingInputRestoration?.cancel()
        let delay = min(3, max(0, inputRestoreDelaySeconds))
        guard delay > 0 else {
            finishVoiceInputWindow()
            return
        }
        inputStatus = "遥控器录音已停止，\(String(format: "%.2f", delay)) 秒后恢复原麦克风（豆包转写收尾）"
        pendingInputRestoration = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
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
        physicalOutputs = ids.compactMap { id -> RemoteVirtualAudioDevice? in
            guard let name = Self.deviceString(id, selector: kAudioObjectPropertyName),
                  let uid = Self.deviceString(id, selector: kAudioDevicePropertyDeviceUID),
                  Self.outputSupportsPlayback(id) else { return nil }
            let lowered = name.lowercased()
            guard !lowered.contains("blackhole"), !lowered.contains("loopback"),
                  !lowered.contains("virtual microphone") else { return nil }
            return RemoteVirtualAudioDevice(id: uid, name: name)
        }
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
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }

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
        if !started && queuedFrames >= 2_400 { // ~50 ms low-latency pre-roll.
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

/// Shared in Settings and Voice; warns if System Output is pointed to BlackHole
/// and provides automatic Screen Sharing anti-echo speaker muting.
struct RemoteVirtualMicrophoneSettings: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if router.outputPointedToVirtualMic {
                RemoteCard(padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.exclamationmark.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(RemotePalette.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("检测到系统「声音输出」当前指向了 \(router.systemOutputName)")
                                .font(.system(size: 13, weight: .bold))
                            Text("这会导致「屏幕共享」把你对着遥控器说的话当成电脑外放传回另一台 Mac 产生强烈回音！BlackHole 只需作为麦克风通道，声音输出应切回实体扬声器。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("一键切回扬声器") {
                            router.switchDefaultOutputAwayFromVirtualMic()
                        }
                        .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                    }
                }
            }

            BlackHoleDriverManagementCard(router: router)

            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 10) {
                        RemoteSectionTitle(
                            title: "遥控器虚拟麦克风与防回音保护",
                            subtitle: "ATVV PCM → BlackHole 输出 → 豆包麦克风输入（内置屏幕共享防回音静音）",
                            symbol: "waveform"
                        )
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
                        Toggle("允许按语音键时使用虚拟麦克风（待机不占用）", isOn: $router.isEnabled)
                            .toggleStyle(.switch)
                            .disabled(router.selectedUID.isEmpty ||
                                      !router.devices.contains(where: { $0.id == router.selectedUID }))
                    }

                    Toggle("按住语音说话期间自动静音扬声器（消除 macOS 屏幕共享回音，松开即恢复）",
                           isOn: $router.suppressSpeakerEchoDuringVoice)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))

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
                                    Text("系统当前麦克风：\(router.systemInputName) · 当前声音输出：\(router.systemOutputName)")
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
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("松开语音键后，延迟恢复原麦克风")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer(minLength: 8)
                                    Text("\(router.inputRestoreDelaySeconds, specifier: "%.2f") 秒")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(RemotePalette.indigo)
                                }
                                Slider(value: $router.inputRestoreDelaySeconds,
                                       in: 0...3, step: 0.25)
                                    .disabled(!router.autoSwitchInputForVoice || !router.isEnabled)
                                Text("默认 1 秒。松开立即关闭音频输出，但暂时保留 BlackHole 作为输入，让豆包完成末尾转写；再次按键会取消这次恢复。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
                    Text("待机时不会打开 BlackHole 音频输出；开启上方「自动静音扬声器」后，使用屏幕共享远程控制 Mac mini 说话时也不会听到自己的延迟回音。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
