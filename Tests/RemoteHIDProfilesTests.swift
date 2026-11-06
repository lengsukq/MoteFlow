import Foundation
import XCTest
@testable import ATVVCore

final class RemoteHIDProfilesTests: XCTestCase {
    private let device = RemoteHIDDeviceIdentity(
        vendorID: 0x18D1, productID: 0x1234,
        productName: "Chromecast Voice Remote",
        transport: "Bluetooth"
    )
    private let up = RemoteHIDButtonCode(reportID: 1, code: 12)
    private let down = RemoteHIDButtonCode(reportID: 1, code: 13)

    func testShippedGoogleRemoteDefaultProfileMatchesUserExportExactly() throws {
        let exportedModel = RemoteHIDDeviceIdentity(
            vendorID: 6353, productID: 37968,
            productName: "Chromecast Remote", transport: "Bluetooth Low Energy"
        )
        let expected: [RemoteKey: RemoteHIDButtonCode] = [
            .up: .init(reportID: 1, code: 3),
            .down: .init(reportID: 1, code: 4),
            .left: .init(reportID: 1, code: 5),
            .right: .init(reportID: 1, code: 6),
            .select: .init(reportID: 1, code: 7),
            .back: .init(reportID: 1, code: 11),
            .home: .init(reportID: 1, code: 10),
            .mute: .init(reportID: 1, code: 8),
            .youtube: .init(reportID: 1, code: 14),
            .netflix: .init(reportID: 1, code: 15),
            .power: .init(reportID: 1, code: 1),
            .input: .init(reportID: 1, code: 17),
            .volumeUp: .init(reportID: 1, code: 12),
            .volumeDown: .init(reportID: 1, code: 13)
        ]
        XCTAssertEqual(RemoteHIDDefaultProfiles.verifiedCodes(for: exportedModel), expected)
        XCTAssertNil(RemoteHIDDefaultProfiles.verifiedCodes(for: exportedModel)[.assistant])
        XCTAssertEqual(RemoteHIDDefaultProfiles.verifiedCodes(for: exportedModel).count, 14)
        let differentPID = RemoteHIDDeviceIdentity(
            vendorID: 6353, productID: 37969,
            productName: "Chromecast Remote", transport: "Bluetooth Low Energy"
        )
        XCTAssertTrue(RemoteHIDDefaultProfiles.verifiedCodes(for: differentPID).isEmpty)
        XCTAssertNoThrow(try RemoteHIDDefaultProfiles.profiles[0].validatedCodes())
    }

    func testExportImportPreservesVerifiedMappingAndIdentity() throws {
        let profile = RemoteHIDProfile(
            device: device,
            codes: [.up: up, .down: down],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try profile.exportData()
        let decoded = try RemoteHIDProfile.importData(data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(try decoded.validatedCodes(), [.up: up, .down: down])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("schemaVersion"))
        XCTAssertTrue(json.contains("reportID"))
        XCTAssertFalse(json.contains("bluetoothUUID"))
        XCTAssertFalse(json.contains("scriptPath"))
    }

    func testDefaultModelMatchingRejectsDifferentDevice() {
        XCTAssertTrue(device.matches(device))
        XCTAssertTrue(device.matches(.init(
            vendorID: 0x18D1, productID: 0x1234,
            productName: " chromecast voice remote ", transport: "bluetooth"
        )))
        XCTAssertFalse(device.matches(.init(
            vendorID: 0x18D1, productID: 0x1235,
            productName: "Chromecast Voice Remote", transport: "Bluetooth"
        )))
        let zeroPID = RemoteHIDDeviceIdentity(
            vendorID: 0x18D1, productID: 0,
            productName: "Chromecast Remote", transport: "Bluetooth"
        )
        XCTAssertNoThrow(try RemoteHIDProfile(device: zeroPID, codes: [.up: up]).exportData())
    }

    func testFactoryAndUserOverridesAreSeparateAndConflictSafe() {
        let defaults: [RemoteKey: RemoteHIDButtonCode] = [.up: up, .down: down]
        XCTAssertEqual(RemoteHIDProfileResolver.merged(defaults: defaults, overrides: [:]), defaults)
        let customized = RemoteHIDProfileResolver.merged(
            defaults: defaults,
            overrides: [.right: up]
        )
        XCTAssertNil(customized[.up])
        XCTAssertEqual(customized[.right], up)
        XCTAssertEqual(customized[.down], down)
        XCTAssertEqual(RemoteHIDProfileResolver.merged(defaults: defaults, overrides: [:]), defaults)
    }

    func testRejectsEmptyAndDuplicateCodes() throws {
        let empty = RemoteHIDProfile(device: device, codes: [:])
        XCTAssertThrowsError(try empty.exportData())

        let valid = RemoteHIDProfile(device: device, codes: [.up: up, .down: down])
        let data = try valid.exportData()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        var repeated = entries[0]
        repeated["key"] = "left"
        entries.append(repeated)
        raw["entries"] = entries
        let duplicate = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(try RemoteHIDProfile.importData(duplicate))

        var invalid = raw
        invalid["schemaVersion"] = 42
        XCTAssertThrowsError(try RemoteHIDProfile.importData(JSONSerialization.data(withJSONObject: invalid)))
    }
}
