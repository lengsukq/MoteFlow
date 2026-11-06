import Foundation
import XCTest
@testable import ATVVCore

final class ATVVCoreTests: XCTestCase {
    func testCommandByteOrderAndCapabilities() {
        XCTAssertEqual([UInt8](ATVV.micOpen()), [0x0C, 0x00, 0x01])
        XCTAssertEqual([UInt8](ATVV.micOpen(codec: 0x0002)), [0x0C, 0x00, 0x02])
        XCTAssertEqual([UInt8](ATVV.getCapabilities), [0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])

        let legacy = ATVVCapabilities(response: Data([0x0B,0x00,0x04,0x00,0x01,0x00,0x86,0x00,0x14]))
        XCTAssertEqual(legacy?.version, 4)
        XCTAssertEqual(legacy?.frameSize, 134)
        XCTAssertEqual(legacy?.isLegacy, true)
        XCTAssertEqual(legacy?.supports8k, true)

        let modern = ATVVCapabilities(response: Data([0x0B,0x01,0x00,0x03,0x03,0x00,0x14,0x00,0x00]))
        XCTAssertEqual(modern?.version, 0x0100)
        XCTAssertEqual(modern?.isLegacy, false)
        XCTAssertEqual(modern?.supports16k, true)
        XCTAssertEqual(modern?.frameSize, 20)
        XCTAssertNil(ATVVCapabilities(response: Data([0x0B, 0x00])))
    }

    func testLegacyDecoderAndFragmentReassembly() throws {
        var bytes = [UInt8](repeating: 0, count: 134)
        bytes[1] = 0x02
        let frame = try ATVVLegacyDecoder.decode(bytes)
        XCTAssertEqual(frame.sequence, 2)
        XCTAssertEqual(frame.samples.count, 257)
        XCTAssertTrue(frame.samples.allSatisfy { $0 == 0 })

        var assembler = ATVVLegacyAssembler()
        XCTAssertTrue(assembler.append(Data(bytes.prefix(20))).isEmpty)
        XCTAssertTrue(assembler.append(Data(bytes[20..<100])).isEmpty)
        let assembled = assembler.append(Data(bytes[100...]))
        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled.first?.sequence, 2)

        bytes[1] = 0x04
        XCTAssertEqual(assembler.append(Data(bytes)).count, 1)
        XCTAssertEqual(assembler.droppedSequenceCount, 1)
        XCTAssertThrowsError(try ATVVLegacyDecoder.decode([0]))
    }

    func testV1RequiresSyncAndProducesContinuousSamples() {
        var decoder = ATVVV1StreamDecoder()
        XCTAssertNil(decoder.decode(Data([0x00])))
        XCTAssertFalse(decoder.synchronize(control: Data([0x0A])))
        XCTAssertTrue(decoder.synchronize(control: Data([0x0A,0x02,0x00,0x09,0x00,0x00,0x00])))
        XCTAssertEqual(decoder.syncSequence, 9)
        let output = decoder.decode(Data(repeating: 0, count: 20))
        XCTAssertEqual(output?.count, 40)
        XCTAssertTrue(output?.allSatisfy { $0 == 0 } ?? false)
        decoder.reset()
        XCTAssertNil(decoder.decode(Data([0x00])))
    }

    func testWAVHeaderAndLEPayload() {
        let wav = [UInt8](WaveFile.pcm16(samples: [0x0102, -2], rate: 8_000))
        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav[24..<28].map { $0 }, [0x40,0x1F,0x00,0x00])
        XCTAssertEqual(Array(wav.suffix(4)), [0x02,0x01,0xFE,0xFF])
    }
}
