import CoreBluetooth
import Foundation

// ATVV (Android TV Voice over BLE) uses dedicated GATT characteristics, not macOS microphone input.
enum ATVV {
    private static let tail = "-5A21-4F05-BC7D-AF01F617B664"
    static let service = CBUUID(string: "AB5E0001" + tail)
    static let command = CBUUID(string: "AB5E0002" + tail)
    static let audio = CBUUID(string: "AB5E0003" + tail)
    static let control = CBUUID(string: "AB5E0004" + tail)

    // Host advertises up to v1.0, 8k and 16k ADPCM; older remotes can negotiate v0.4.
    static let getCapabilities = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    static let micClose = Data([0x0D])
    static let micCloseV1 = Data([0x0D, 0xFF]) // v1.0 close any active stream

    static func micOpen(codec: UInt16 = 0x0001) -> Data {
        Data([0x0C, UInt8((codec >> 8) & 0xFF), UInt8(codec & 0xFF)])
    }

    static func extendMicrophone() -> Data { Data([0x0E, 0x00]) }
}

/// ATVV's notify subscription is a transport prerequisite, not microphone
/// capture. The remote must see audio + control notifications enabled before
/// it can negotiate or accept MIC_OPEN. Only MIC_OPEN/AUDIO_START consume the
/// remote's voice stream and start feeding PCM to an audio output device.
enum ATVVTransportPolicy {
    static func mustKeepAudioNotificationsReady(voiceModeEnabled: Bool) -> Bool {
        voiceModeEnabled
    }

    static func canNegotiate(audioSubscribed: Bool, controlSubscribed: Bool) -> Bool {
        audioSubscribed && controlSubscribed
    }

    static func shouldEndOnStop(
        isRecording: Bool, openingMic: Bool, hasPendingSearch: Bool
    ) -> Bool {
        // Some remotes send a stale AUDIO_STOP while MIC_OPEN is pending.
        // Treat only an established stream as stoppable by an ATVV 0x00.
        // Actual key-up via HID can still cancel a pending mic open.
        isRecording
    }
}

/// Stateless packet converter for the 8/16 kHz mono ADPCM-decoded speech
/// samples to the 48 kHz, two-channel PCM input expected by BlackHole 2ch.
/// Kept in ATVVCore so audio conversion is testable without macOS hardware.
enum ATVVVirtualMicPCM {
    static let outputRate = 48_000

    static func stereo48k(samples: [Int16], sourceRate: Int) -> [Int16] {
        guard (sourceRate == 8_000 || sourceRate == 16_000), !samples.isEmpty else { return [] }
        let ratio = outputRate / sourceRate
        var output: [Int16] = []
        output.reserveCapacity(samples.count * ratio * 2)
        for index in samples.indices {
            let first = Double(samples[index])
            let second = Double(samples[min(index + 1, samples.count - 1)])
            for position in 0..<ratio {
                let interpolated = first + (second - first) * Double(position) / Double(ratio)
                let value = Int16(max(-32768, min(32767, Int(interpolated.rounded()))))
                output.append(value)
                output.append(value)
            }
        }
        return output
    }
}

/// ATVV v1.0 transports headerless ADPCM chunks. A CTL SYNC (0x0A) supplies
/// the initial predictor and step index, after which the decoder is stateful.
/// Audio received before the first valid SYNC cannot be reconstructed safely.
struct ATVVV1StreamDecoder {
    private var predictor = 0
    private var stepIndex = 0
    private(set) var isSynchronized = false
    private(set) var syncSequence: UInt16?

    mutating func reset() {
        predictor = 0
        stepIndex = 0
        isSynchronized = false
        syncSequence = nil
    }

    mutating func synchronize(control: Data) -> Bool {
        let bytes = [UInt8](control)
        guard bytes.count >= 7, bytes[0] == 0x0A, bytes[6] <= 88 else { return false }
        syncSequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        predictor = Int(Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5])))
        stepIndex = Int(bytes[6])
        isSynchronized = true
        return true
    }

    mutating func decode(_ payload: Data) -> [Int16]? {
        guard isSynchronized else { return nil }
        var samples = [Int16]()
        samples.reserveCapacity(payload.count * 2)
        for byte in payload {
            for nibble in [byte >> 4, byte & 0x0F] {
                let step = ATVVLegacyDecoder.stepTable[stepIndex]
                var delta = step >> 3
                if nibble & 1 != 0 { delta += step >> 2 }
                if nibble & 2 != 0 { delta += step >> 1 }
                if nibble & 4 != 0 { delta += step }
                predictor += nibble & 8 != 0 ? -delta : delta
                predictor = max(-32768, min(32767, predictor))
                stepIndex = max(0, min(88, stepIndex + ATVVLegacyDecoder.indexTable[Int(nibble & 7)]))
                samples.append(Int16(predictor))
            }
        }
        return samples
    }
}

struct ATVVCapabilities {
    let version: UInt16
    let codecMask: UInt16
    let frameSize: Int?

    var isLegacy: Bool { version < 0x0100 }
    var displayVersion: String { "\(version >> 8).\(version & 0xFF)" }
    var supports8k: Bool { codecMask & 0x0001 != 0 }
    var supports16k: Bool { codecMask & 0x0002 != 0 }

    init?(response: Data) {
        let bytes = [UInt8](response)
        guard bytes.count >= 6, bytes[0] == 0x0B else { return nil }
        version = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        if version < 0x0100 {
            guard bytes.count >= 9 else { return nil }
            codecMask = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
            frameSize = Int(bytes[5]) << 8 | Int(bytes[6])
        } else {
            // 1.0 encodes the codec bitmap in a single byte; following fields differ from 0.4.
            codecMask = UInt16(bytes[3])
            frameSize = bytes.count >= 7 ? (Int(bytes[5]) << 8 | Int(bytes[6])) : nil
        }
    }
}

struct ATVDecodedFrame {
    let sequence: UInt16
    let samples: [Int16]
}

enum ATVAudioError: Error, LocalizedError {
    case wrongFrameSize(Int)
    case invalidStepIndex(Int)

    var errorDescription: String? {
        switch self {
        case .wrongFrameSize(let count): "ATVV v0.4 音频帧长度应为 134，实际为 \(count)"
        case .invalidStepIndex(let index): "ATVV ADPCM 步长索引非法：\(index)"
        }
    }
}

// This decoder supports the 134-byte *v0.4* frame layout only.
// v1.0 frames have a different stream format and must not be decoded as v0.4.
enum ATVVLegacyDecoder {
    fileprivate static let stepTable: [Int] = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,
        73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,
        408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,
        1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,
        5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,
        18500,20350,22385,24623,27086,29794,32767
    ]
    fileprivate static let indexTable = [-1,-1,-1,-1,2,4,6,8]

    static func decode(_ bytes: [UInt8]) throws -> ATVDecodedFrame {
        guard bytes.count == 134 else { throw ATVAudioError.wrongFrameSize(bytes.count) }
        let sequence = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let predictorBits = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        var predictor = Int(Int16(bitPattern: predictorBits))
        var index = Int(bytes[5])
        guard (0...88).contains(index) else { throw ATVAudioError.invalidStepIndex(index) }
        var samples: [Int16] = [Int16(predictor)]
        samples.reserveCapacity(257)

        for byte in bytes[6...] {
            for nibble in [byte >> 4, byte & 0x0F] {
                let step = stepTable[index]
                var difference = step >> 3
                if nibble & 1 != 0 { difference += step >> 2 }
                if nibble & 2 != 0 { difference += step >> 1 }
                if nibble & 4 != 0 { difference += step }
                predictor += (nibble & 8 != 0) ? -difference : difference
                predictor = max(-32768, min(32767, predictor))
                index = max(0, min(88, index + indexTable[Int(nibble & 7)]))
                samples.append(Int16(predictor))
            }
        }
        return ATVDecodedFrame(sequence: sequence, samples: samples)
    }
}

// BLE may deliver a 134-byte frame in one notification or in several smaller fragments.
struct ATVVLegacyAssembler {
    private var pending = [UInt8]()
    private(set) var droppedSequenceCount = 0
    private var previousSequence: UInt16?

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        previousSequence = nil
        droppedSequenceCount = 0
    }

    mutating func append(_ payload: Data) -> [ATVDecodedFrame] {
        pending.append(contentsOf: payload)
        // Bound a malformed stream to avoid unbounded allocation.
        if pending.count > 134 * 50 { reset(); return [] }
        var frames: [ATVDecodedFrame] = []
        while pending.count >= 134 {
            let frameBytes = Array(pending.prefix(134))
            pending.removeFirst(134)
            guard let frame = try? ATVVLegacyDecoder.decode(frameBytes) else {
                // Invalid data: don't guess audio. Recovery requires a new session boundary.
                reset()
                break
            }
            if let previousSequence {
                let expected = previousSequence &+ 1
                if frame.sequence != expected {
                    let distance = Int(frame.sequence &- expected)
                    if distance <= 1000 { droppedSequenceCount += distance }
                }
            }
            previousSequence = frame.sequence
            frames.append(frame)
        }
        return frames
    }
}

enum WaveFile {
    static func pcm16(samples: [Int16], rate: Int) -> Data {
        var output = Data()
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        func appendLE16(_ number: UInt16) {
            output.append(UInt8(truncatingIfNeeded: number))
            output.append(UInt8(truncatingIfNeeded: number >> 8))
        }
        func appendLE32(_ number: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                output.append(UInt8(truncatingIfNeeded: number >> shift))
            }
        }
        output.append(contentsOf: Array("RIFF".utf8))
        appendLE32(dataSize + 36)
        output.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE32(16)
        appendLE16(1)
        appendLE16(1)
        appendLE32(UInt32(rate))
        appendLE32(UInt32(rate * 2))
        appendLE16(2)
        appendLE16(16)
        output.append(contentsOf: Array("data".utf8))
        appendLE32(dataSize)
        for sample in samples { appendLE16(UInt16(bitPattern: sample)) }
        return output
    }
}
