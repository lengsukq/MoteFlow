import XCTest
@testable import ATVVCore

final class RemoteHIDReportDecoderTests: XCTestCase {
    func testObservedGoogleRemoteReportPressAndRelease() {
        let press = RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x01, 0x0C, 0x00])
        XCTAssertEqual(press, RemoteHIDButtonCode(reportID: 1, code: 12))
        let release = RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x01, 0x00, 0x00])
        XCTAssertEqual(release, RemoteHIDButtonCode(reportID: 1, code: 0))
        XCTAssertEqual(RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x01, 0x0D, 0x00])?.code, 13)
    }

    func testOtherFormatsRemainUnknownInsteadOfWrongMapping() {
        XCTAssertNil(RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x02, 0x0C, 0x00]))
        XCTAssertNil(RemoteHIDReportDecoder.decode(reportID: 1, bytes: []))
        XCTAssertNil(RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x01]))
        XCTAssertNil(RemoteHIDReportDecoder.decode(reportID: 1, bytes: [0x01, 0x00, 0x00, 0x00]))
        XCTAssertEqual(RemoteHIDReportDecoder.decode(reportID: 2, bytes: [0x34, 0x12])?.code, 0x1234)
    }
}
