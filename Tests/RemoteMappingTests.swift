import Foundation
import XCTest
@testable import ATVVCore

@MainActor
final class RemoteMappingTests: XCTestCase {
    private let shortcut = RemoteShortcut(
        keyCode: 40, keyLabel: "K",
        command: true, shift: true, option: false, control: false
    )

    func testEveryPhysicalKeyHasAStableIdentity() {
        XCTAssertEqual(RemoteKey.allCases.count, 17)
        XCTAssertEqual(Set(RemoteKey.allCases.map(\.id)).count, 17)
        XCTAssertEqual(RemoteKey.assistant.title, "语音助手")
        XCTAssertEqual(shortcut.display, "⌘⇧K")
    }

    func testBuiltInRemoteInventoryAndStrictHardwareMatching() {
        XCTAssertEqual(RemoteDeviceProfileRegistry.builtIn.count, 4)
        XCTAssertEqual(RemoteDeviceProfileRegistry.identify(
            vendorID: 0x2717, productID: 0x32B8, productName: "RC001"
        ), .xiaomiRemote2)
        XCTAssertEqual(RemoteDeviceProfileRegistry.identify(
            vendorID: 0x2717, productID: 0x32B0, productName: "RC003"
        ), .xiaomiRemote2Pro)
        XCTAssertNil(RemoteDeviceProfileRegistry.identify(
            vendorID: 0x2717, productID: 0x32B8, productName: "Wireless Keyboard"
        ))
        XCTAssertNil(RemoteDeviceProfileRegistry.identify(
            vendorID: 0x2717, productID: 0x0123, productName: "Xiaomi Remote"
        ))
        XCTAssertNil(RemoteDeviceProfileRegistry.identify(
            vendorID: 0x2717, productID: 0x32B8, productName: "Mouse"
        ))
        XCTAssertTrue(RemoteDeviceModel.xiaomiRemote2.keys.contains(.menu))
        XCTAssertTrue(RemoteDeviceModel.xiaomiRemote2.keys.contains(.tv))
        XCTAssertFalse(RemoteDeviceModel.googleG9N9N.keys.contains(.menu))
        XCTAssertEqual(RemoteDeviceModel.googleG9N9N.keys.count, 15)
    }

    func testXiaomiHIDUsageCandidatesDoNotAssumeGoogleReportFormat() {
        XCTAssertEqual(XiaomiHIDUsageMapper.key(usagePage: 0x07, usage: 0x52), .up)
        XCTAssertEqual(XiaomiHIDUsageMapper.key(usagePage: 0x07, usage: 0x28), .select)
        XCTAssertEqual(XiaomiHIDUsageMapper.key(usagePage: 0x0C, usage: 0xE9), .volumeUp)
        XCTAssertNil(XiaomiHIDUsageMapper.key(usagePage: 0x01, usage: 0x52))
        XCTAssertNil(XiaomiHIDUsageMapper.key(usagePage: 0x07, usage: 0xFFFF))
    }

    func testFirstRunXiaomiSeedDoesNotOverwriteGoogleMappings() {
        let suite = "MoteFlow.device-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalGoogle = RemoteProfile(bindings: [
            .home: RemoteBinding(kind: .keyboardShortcut, shortcut: shortcut)
        ])
        defaults.set(try! JSONEncoder().encode(originalGoogle), forKey: "GoogleRemote.keyBindings.v1")

        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store.activeModel, .googleG9N9N)
        XCTAssertEqual(store.binding(for: .home).shortcut, shortcut)
        store.selectModel(.xiaomiRemote2)
        XCTAssertEqual(store.activeModel, .xiaomiRemote2)
        XCTAssertEqual(store.configuredCount, 7)
        XCTAssertEqual(store.binding(for: .up).shortcut?.keyCode, 126)
        XCTAssertEqual(store.binding(for: .select).shortcut?.keyCode, 36)
        XCTAssertEqual(store.binding(for: .home).kind, .libraryAction)
        XCTAssertEqual(store.binding(for: .home).presetID, RemoteLibraryStore.chatGPTPresetID)
        let custom = RemoteShortcut(keyCode: 49, keyLabel: "Space", command: false,
                                    shift: false, option: false, control: false)
        XCTAssertTrue(store.setShortcut(custom, for: .menu))
        store.selectModel(.googleG9N9N)
        XCTAssertEqual(store.binding(for: .home).shortcut, shortcut)
        store.selectModel(.xiaomiRemote2)
        XCTAssertEqual(store.binding(for: .menu).shortcut, custom)
        XCTAssertEqual(RemoteBindingStore(defaults: defaults).activeModel, .xiaomiRemote2)
        store.resetAll()
        store.selectModel(.googleG9N9N)
        store.selectModel(.xiaomiRemote2)
        XCTAssertEqual(store.configuredCount, 0, "Reset a profile once; do not re-initialize deleted bindings")
        store.selectModel(.googleG9N9N)
        XCTAssertEqual(store.binding(for: .home).shortcut, shortcut)
    }

    func testConfigurationRoundTripAndConflictReplacement() {
        let suite = "GoogleRemote.mapping-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store.configuredCount, 0)

        XCTAssertTrue(store.setShortcut(shortcut, for: .assistant))
        XCTAssertEqual(store.binding(for: .assistant).summary, "⌘⇧K")
        XCTAssertEqual(store.configuredCount, 1)

        let reloaded = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .assistant).shortcut, shortcut)
        XCTAssertEqual(reloaded.conflictingKey(for: shortcut, excluding: .home), .assistant)
        XCTAssertFalse(reloaded.setShortcut(shortcut, for: .home))
        XCTAssertEqual(reloaded.configuredCount, 1)

        XCTAssertTrue(reloaded.setShortcut(shortcut, for: .home, replaceConflict: true))
        XCTAssertEqual(reloaded.binding(for: .assistant).kind, .none)
        XCTAssertEqual(reloaded.binding(for: .home).shortcut, shortcut)
        XCTAssertEqual(reloaded.configuredCount, 1)

        reloaded.setKind(.voiceInput, for: .home)
        XCTAssertNil(reloaded.binding(for: .home).shortcut)
        XCTAssertEqual(reloaded.binding(for: .home).kind, .voiceInput)

        reloaded.reset(.home)
        XCTAssertEqual(reloaded.configuredCount, 0)

        reloaded.setKind(.voiceInput, for: .assistant)
        reloaded.setKind(.keyboardShortcut, for: .back)
        XCTAssertEqual(reloaded.configuredCount, 2)
        reloaded.resetAll()
        XCTAssertEqual(RemoteBindingStore(defaults: defaults).configuredCount, 0)
    }

    func testShortcutIdentityIgnoresKeyboardLayoutLabel() {
        let alternateLabel = RemoteShortcut(
            keyCode: shortcut.keyCode, keyLabel: "Л",
            command: shortcut.command, shift: shortcut.shift,
            option: shortcut.option, control: shortcut.control
        )
        XCTAssertEqual(shortcut, alternateLabel)
        XCTAssertEqual(shortcut.hashValue, alternateLabel.hashValue)
    }

    func testLeftAndRightModifierKeysRemainDifferentShortcuts() throws {
        var left = RemoteShortcut(
            keyCode: 40, keyLabel: "K",
            command: true, shift: false, option: true, control: false
        )
        left.commandSide = .left
        left.optionSide = .left
        var right = left
        right.commandSide = .right
        right.optionSide = .right
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(left.display, "⌘左⌥左K")
        XCTAssertEqual(right.display, "⌘右⌥右K")
        XCTAssertEqual(left.pressedModifierKeyCodes, [55, 58])
        XCTAssertEqual(right.pressedModifierKeyCodes, [54, 61])
        XCTAssertEqual(try JSONDecoder().decode(RemoteShortcut.self, from: JSONEncoder().encode(right)), right)

        let suite = "GoogleRemote.sides.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertTrue(store.setShortcut(left, for: .home))
        XCTAssertNil(store.conflictingKey(for: right, excluding: .back))
        XCTAssertTrue(store.setShortcut(right, for: .back))
    }

    func testPhysicalModifierPositionsAndBothSides() {
        let original = RemoteShortcut(
            keyCode: 49, keyLabel: "Space",
            command: true, shift: true, option: true, control: false
        )
        let captured = original.withPhysicalModifierKeys([54, 55, 60, 61])
        XCTAssertEqual(captured.commandSide, .both)
        XCTAssertEqual(captured.optionSide, .right)
        XCTAssertEqual(captured.shiftSide, .right)
        XCTAssertEqual(captured.pressedModifierKeyCodes, [55, 54, 60, 61])
        XCTAssertEqual(RemoteModifier.location(of: 55)?.side, .left)
        XCTAssertEqual(RemoteModifier.location(of: 54)?.side, .right)
        XCTAssertEqual(RemoteModifier.location(of: 58)?.modifier, .option)
        XCTAssertNil(RemoteModifier.location(of: 40))
    }

    func testLegacyShortcutWithoutSideInformationRemainsCompatible() throws {
        let raw = Data(#"{"keyCode":40,"keyLabel":"K","command":true,"shift":false,"option":true,"control":false}"#.utf8)
        let legacy = try JSONDecoder().decode(RemoteShortcut.self, from: raw)
        XCTAssertNil(legacy.commandSide)
        XCTAssertNil(legacy.optionSide)
        XCTAssertEqual(legacy.display, "⌘⌥K")
        XCTAssertEqual(legacy.pressedModifierKeyCodes, [55, 58])
    }

    func testModifierOnlyShortcutNeedsNoSpaceKeyAndPreservesSide() throws {
        let left = RemoteShortcut(keyCode: 55, keyLabel: "左 Command",
                                  command: false, shift: false, option: false, control: false)
        let right = RemoteShortcut(keyCode: 54, keyLabel: "右 Command",
                                   command: false, shift: false, option: false, control: false)
        XCTAssertTrue(left.isModifierOnly)
        XCTAssertTrue(right.isModifierOnly)
        XCTAssertEqual(left.display, "⌘左")
        XCTAssertEqual(right.display, "⌘右")
        XCTAssertTrue(left.pressedModifierKeyCodes.isEmpty)
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(try JSONDecoder().decode(RemoteShortcut.self, from: JSONEncoder().encode(right)), right)
        let suite = "GoogleRemote.modifier-only.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertTrue(store.setShortcut(left, for: .assistant, gesture: .longPress))
        XCTAssertEqual(RemoteBindingStore(defaults: defaults).action(for: .assistant, gesture: .longPress).shortcut, left)
        XCTAssertTrue(store.setShortcut(right, for: .home))
    }

    func testSingleModifierReleaseRecordsAndModifierChordDoesNot() {
        var oneKey = RemoteModifierCaptureState()
        XCTAssertNil(oneKey.flagsChanged(keyCode: 55))
        XCTAssertEqual(oneKey.heldCodes, [55])
        XCTAssertEqual(oneKey.flagsChanged(keyCode: 55), 55)
        XCTAssertTrue(oneKey.heldCodes.isEmpty)

        var chord = RemoteModifierCaptureState()
        XCTAssertNil(chord.flagsChanged(keyCode: 55))
        XCTAssertNil(chord.flagsChanged(keyCode: 56))
        XCTAssertNil(chord.flagsChanged(keyCode: 56))
        XCTAssertNil(chord.flagsChanged(keyCode: 55))

        var withMainKey = RemoteModifierCaptureState()
        XCTAssertNil(withMainKey.flagsChanged(keyCode: 54))
        withMainKey.ordinaryKeyPressed()
        XCTAssertNil(withMainKey.flagsChanged(keyCode: 54))
    }
}
