import AudioToolbox
import CoreAudio
import Foundation

/// Single-responsibility collaborator that temporarily mutes physical/system speakers
/// during active remote voice dictation (preventing macOS Screen Sharing echo loops)
/// while strictly refusing to mute virtual microphone loopback devices (e.g. BlackHole).
@MainActor
final class SpeakerEchoSuppressor {
    private enum SavedAttenuation {
        case hardwareMute(deviceID: AudioDeviceID)
        case virtualVolume(deviceID: AudioDeviceID, previousVolume: Float32)
    }

    private var savedState: SavedAttenuation?
    private var restoreTask: Task<Void, Never>?

    var isSuppressed: Bool {
        savedState != nil
    }

    func engage(enabled: Bool, defaultOutputID: AudioDeviceID?, virtualMicUID: String) {
        restoreTask?.cancel()
        restoreTask = nil
        guard enabled, savedState == nil, let outID = defaultOutputID else { return }

        let outUID = CoreAudioDeviceQuery.deviceString(outID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let outName = (CoreAudioDeviceQuery.deviceString(outID, selector: kAudioObjectPropertyName) ?? "").lowercased()
        guard outUID != virtualMicUID,
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
                    savedState = .hardwareMute(deviceID: outID)
                    return
                }
            } else if currentMute == 1 {
                return
            }
        }

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
                    savedState = .virtualVolume(deviceID: outID, previousVolume: currentVol)
                }
            }
        }
    }

    func scheduleRelease(delayMilliseconds: Int = 260) {
        guard savedState != nil else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.releaseImmediately()
        }
    }

    func releaseImmediately() {
        restoreTask?.cancel()
        restoreTask = nil
        guard let saved = savedState else { return }
        savedState = nil

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
}

/// Low-level CoreAudio property query helper shared across hardware audio collaborators.
enum CoreAudioDeviceQuery {
    static func defaultInputID() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device
        ) == noErr, device != 0 else { return nil }
        return device
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device
        ) == noErr, device != 0 else { return nil }
        return device
    }

    static func setDefaultInputID(_ id: AudioDeviceID) -> OSStatus {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
    }

    static func setDefaultOutputID(_ id: AudioDeviceID) -> OSStatus {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
    }

    static func streamSupportsChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
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

    static func inputSupportsCapture(_ id: AudioDeviceID) -> Bool {
        streamSupportsChannels(id, scope: kAudioObjectPropertyScopeInput)
    }

    static func outputSupportsPlayback(_ id: AudioDeviceID) -> Bool {
        streamSupportsChannels(id, scope: kAudioObjectPropertyScopeOutput)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
              ) == noErr else { return [] }
        return ids
    }

    static func idForUID(_ uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allDeviceIDs().first { deviceString($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    static func deviceString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
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
}
