import XCTest
@testable import ATVVCore

final class ATVVVirtualMicPCMTests: XCTestCase {
    func testEightKilohertzMonoBecomesStereoFortyEightKilohertz() {
        let samples: [Int16] = [0, 600, 1200]
        let result = ATVVVirtualMicPCM.stereo48k(samples: samples, sourceRate: 8_000)
        XCTAssertEqual(result.count, samples.count * 6 * 2)
        for index in stride(from: 0, to: result.count, by: 2) {
            XCTAssertEqual(result[index], result[index + 1], "左右声道必须同步")
        }
        XCTAssertEqual(result[0], 0)
        XCTAssertEqual(result[2], 100)
        XCTAssertEqual(result[12], 600)
        XCTAssertEqual(result[24], 1200)
    }

    func testSixteenKilohertzMonoBecomesStereoFortyEightKilohertz() {
        let result = ATVVVirtualMicPCM.stereo48k(samples: [-300, 0, 300], sourceRate: 16_000)
        XCTAssertEqual(result.count, 3 * 3 * 2)
        XCTAssertEqual(result[0], -300)
        XCTAssertEqual(result[2], -200)
        XCTAssertEqual(result[4], -100)
        XCTAssertEqual(result[6], 0)
    }

    func testSilenceAndFullScaleAreNotDistorted() {
        XCTAssertEqual(Set(ATVVVirtualMicPCM.stereo48k(samples: [0, 0], sourceRate: 8_000)), [0])
        let fullScale = ATVVVirtualMicPCM.stereo48k(samples: [.min, .max], sourceRate: 16_000)
        XCTAssertEqual(fullScale.first, Int16.min)
        XCTAssertEqual(fullScale.last, Int16.max)
    }

    func testUnknownSampleRatesProduceNoAudio() {
        XCTAssertTrue(ATVVVirtualMicPCM.stereo48k(samples: [42], sourceRate: 44_100).isEmpty)
        XCTAssertTrue(ATVVVirtualMicPCM.stereo48k(samples: [], sourceRate: 8_000).isEmpty)
    }
}
