import XCTest
@testable import ATVVCore

final class DoubaoShortcutTriggerTests: XCTestCase {
    func testBothTriggerModesHaveStablePersistedIdentifiers() {
        XCTAssertEqual(Set(DoubaoShortcutTrigger.allCases.map(\.rawValue)), Set(["tap", "hold"]))
        XCTAssertEqual(DoubaoShortcutTrigger(rawValue: "tap"), .tap)
        XCTAssertEqual(DoubaoShortcutTrigger(rawValue: "hold"), .hold)
        XCTAssertNil(DoubaoShortcutTrigger(rawValue: "unknown"))
        XCTAssertNotEqual(DoubaoShortcutTrigger.tap.title, DoubaoShortcutTrigger.hold.title)
    }
}
