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

    func testGoogleFactoryProfileDirectionsTapOnceAndLongPressContinuous() {
        let defaults = RemoteBindingStore.factoryActionBindings(for: .googleG9N9N)
        let directions: [(RemoteKey, UInt16)] = [
            (.up, 126), (.down, 125), (.left, 123), (.right, 124)
        ]
        for (key, code) in directions {
            guard let mapping = defaults[key] else {
                XCTFail("Missing factory mapping for \(key)")
                continue
            }
            let tap = mapping.action(for: .tap)
            let hold = mapping.action(for: .longPress)
            XCTAssertEqual(tap.kind, .keyboardShortcut)
            XCTAssertEqual(tap.shortcut?.keyCode, code)
            XCTAssertEqual(tap.effectiveHoldMode, .timed)
            XCTAssertEqual(hold.kind, .keyboardShortcut)
            XCTAssertEqual(hold.shortcut?.keyCode, code)
            XCTAssertEqual(hold.effectiveHoldMode, .physical)
            XCTAssertEqual(mapping.effectiveThreshold, 0.35)
            XCTAssertTrue(RemoteKeyRepeatPolicy.shouldRepeat(hold.shortcut!))
        }
        XCTAssertEqual(defaults[.select]?.shortcut?.keyCode, 36)
        XCTAssertEqual(defaults[.back]?.shortcut?.keyCode, 53)
        XCTAssertEqual(defaults.count, 8, "Only navigation and clipboard side keys should be preassigned")
        XCTAssertEqual(defaults[.volumeUp]?.action(for: .tap).systemAction, .copy)
        XCTAssertEqual(defaults[.volumeUp]?.action(for: .longPress).systemAction, .selectAllAndCopy)
        XCTAssertEqual(defaults[.volumeDown]?.action(for: .tap).systemAction, .paste)
        XCTAssertEqual(defaults[.volumeDown]?.action(for: .longPress).systemAction, .selectAllAndPaste)
        XCTAssertNil(defaults[.power])
        XCTAssertNil(defaults[.assistant])
        XCTAssertNil(defaults[.youtube])
    }

    func testGoogleSideClipboardActionsAreAtomicOrderedNativeCommands() {
        XCTAssertEqual(RemoteSystemAction.copy.executionSequence, [.copy])
        XCTAssertEqual(RemoteSystemAction.paste.executionSequence, [.paste])
        XCTAssertEqual(RemoteSystemAction.selectAllAndCopy.executionSequence,
                       [.selectAll, .copy])
        XCTAssertEqual(RemoteSystemAction.selectAllAndPaste.executionSequence,
                       [.selectAll, .paste])
        XCTAssertTrue(RemoteSystemAction.selectAllAndCopy.usesAccessibilityMenu)
        XCTAssertTrue(RemoteSystemAction.selectAllAndPaste.usesAccessibilityMenu)
        XCTAssertNil(RemoteSystemAction.selectAllAndCopy.screenshotArguments)
    }

    func testSideKeysMigrateOnlyWhenUnmappedAndDoNotClobberCustomActions() throws {
        let suite = "MoteFlow.side-key-migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = [
            RemoteKey.home: RemoteBinding(kind: .keyboardShortcut, shortcut: shortcut),
            .volumeUp: RemoteBinding(kind: .systemAction, systemAction: .undo)
        ]
        defaults.set(try JSONEncoder().encode(
            [RemoteDeviceModel.googleG9N9N.id: previous]
        ), forKey: "MoteFlow.remoteModels.v1")
        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .tap).systemAction, .undo)
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .longPress).kind, .none)
        XCTAssertEqual(store.action(for: .volumeDown, gesture: .tap).systemAction, .paste)
        XCTAssertEqual(store.action(for: .volumeDown, gesture: .longPress).systemAction,
                       .selectAllAndPaste)
        XCTAssertEqual(store.action(for: .home, gesture: .tap).shortcut, shortcut)

        XCTAssertTrue(store.saveAsNamedProfile("之前的侧键"))
        let savedID = store.activeProfileID!
        XCTAssertTrue(store.applyGoogleSideKeyClipboardPreset())
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .tap).systemAction, .copy)
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .longPress).systemAction,
                       .selectAllAndCopy)
        XCTAssertTrue(store.hasUnsavedNamedChanges)
        XCTAssertEqual(store.activeNamedProfile?.bindings[.volumeUp]?.systemAction, .undo)
        XCTAssertEqual(RemoteBindingStore(defaults: defaults)
            .action(for: .volumeDown, gesture: .longPress).systemAction, .selectAllAndPaste)
        XCTAssertTrue(store.applyNamedProfile(savedID))
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .tap).systemAction, .undo)
        store.applyFactoryMapping()
        XCTAssertEqual(store.action(for: .volumeUp, gesture: .tap).systemAction, .copy)
        XCTAssertEqual(store.action(for: .volumeDown, gesture: .longPress).systemAction,
                       .selectAllAndPaste)
    }

    func testSideKeyMigrationNeverReaddsKeysAfterUserClearsThem() {
        let suite = "MoteFlow.side-key-clear.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        store.reset(.volumeUp)
        let reloaded = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(reloaded.action(for: .volumeUp, gesture: .tap).kind, .none)
        XCTAssertEqual(reloaded.action(for: .volumeUp, gesture: .longPress).kind, .none)
        XCTAssertEqual(reloaded.action(for: .volumeDown, gesture: .tap).systemAction, .paste)
        reloaded.selectModel(.xiaomiRemote2)
        XCTAssertFalse(reloaded.applyGoogleSideKeyClipboardPreset())
    }

    func testNamedMappingProfilesAreSeparateSnapshotsAndFactoryCanAlwaysRestore() {
        let suite = "MoteFlow.mapping-profiles.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(store.activeModel, .googleG9N9N)
        XCTAssertEqual(store.configuredCount, 8)
        XCTAssertNil(store.activeNamedProfile)

        store.setLongPressThreshold(0.8, for: .up)
        XCTAssertTrue(store.saveAsNamedProfile(" 我的客厅 "), store.profileError ?? "")
        let id = store.activeProfileID!
        XCTAssertEqual(store.activeNamedProfile?.name, "我的客厅")
        XCTAssertFalse(store.hasUnsavedNamedChanges)
        XCTAssertFalse(store.saveAsNamedProfile("我的客厅"))
        XCTAssertFalse(store.saveAsNamedProfile("   "))
        XCTAssertEqual(store.profilesForActiveModel.count, 1)

        store.setLongPressThreshold(1.1, for: .up)
        XCTAssertTrue(store.hasUnsavedNamedChanges)
        let reloadedDirty = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(reloadedDirty.activeProfileID, id)
        XCTAssertTrue(reloadedDirty.hasUnsavedNamedChanges)
        XCTAssertEqual(reloadedDirty.binding(for: .up).effectiveThreshold, 1.1)
        XCTAssertEqual(reloadedDirty.activeNamedProfile?.bindings[.up]?.effectiveThreshold, 0.8)

        store.applyFactoryMapping()
        XCTAssertNil(store.activeProfileID)
        XCTAssertEqual(store.binding(for: .up).effectiveThreshold, 0.35)
        XCTAssertEqual(store.profilesForActiveModel.count, 1)
        XCTAssertTrue(store.applyNamedProfile(id))
        XCTAssertEqual(store.binding(for: .up).effectiveThreshold, 0.8)
        store.setLongPressThreshold(0.6, for: .up)
        XCTAssertTrue(store.updateActiveNamedProfile())
        XCTAssertFalse(store.hasUnsavedNamedChanges)
        XCTAssertEqual(RemoteBindingStore(defaults: defaults)
            .activeNamedProfile?.bindings[.up]?.effectiveThreshold, 0.6)

        XCTAssertTrue(store.renameNamedProfile(id, to: "日常遥控"))
        XCTAssertEqual(store.activeNamedProfile?.name, "日常遥控")
        XCTAssertTrue(store.deleteNamedProfile(id))
        XCTAssertNil(store.activeNamedProfile)
        XCTAssertEqual(store.binding(for: .up).effectiveThreshold, 0.6,
                       "Deleting a snapshot should not erase the current working copy")
        store.applyFactoryMapping()
        XCTAssertEqual(store.binding(for: .up).effectiveThreshold, 0.35,
                       "Factory remains immutable after arbitrary custom edits")
        XCTAssertTrue(store.profilesForActiveModel.isEmpty)
    }

    func testNamedProfilesDoNotLeakBetweenRemoteModels() {
        let suite = "MoteFlow.model-profiles.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        store.applyFactoryMapping()
        XCTAssertTrue(store.saveAsNamedProfile("通用方案"))
        let googleID = store.activeProfileID!
        store.selectModel(.xiaomiRemote2)
        XCTAssertNil(store.activeProfileID)
        XCTAssertTrue(store.profilesForActiveModel.isEmpty)
        XCTAssertFalse(store.applyNamedProfile(googleID))
        XCTAssertTrue(store.saveAsNamedProfile("通用方案"))
        let xiaomiID = store.activeProfileID!
        XCTAssertNotEqual(xiaomiID, googleID)
        store.selectModel(.googleG9N9N)
        XCTAssertEqual(store.activeProfileID, googleID)
        XCTAssertEqual(store.profilesForActiveModel.count, 1)
        store.applyFactoryMapping()
        XCTAssertNil(store.activeProfileID)
        store.selectModel(.xiaomiRemote2)
        XCTAssertEqual(store.activeProfileID, xiaomiID)
        XCTAssertEqual(store.profilesForActiveModel.count, 1)
        XCTAssertEqual(RemoteBindingStore(defaults: defaults).activeProfileID, xiaomiID)
    }

    func testMacShortcutCatalogContainsExpectedSystemShortcuts() {
        XCTAssertEqual(MacShortcutPreset.all.count, 22)
        XCTAssertEqual(Set(MacShortcutPreset.all.map(\.id)).count, MacShortcutPreset.all.count)
        XCTAssertEqual(MacShortcutPreset.popular.count, 6)
        XCTAssertEqual(MacShortcutPreset.popular.map(\.id), MacShortcutPreset.popularIDs)

        func preset(_ id: String) -> RemoteShortcut {
            guard let shortcut = MacShortcutPreset.all.first(where: { $0.id == id })?.shortcut else {
                XCTFail("Missing macOS shortcut preset \(id)")
                return RemoteShortcut(keyCode: 0, keyLabel: "", command: false,
                                      shift: false, option: false, control: false)
            }
            return shortcut
        }
        XCTAssertEqual(preset("screenshot.area").keyCode, 21)
        XCTAssertEqual(preset("screenshot.area").display, "⌘⇧4")
        XCTAssertEqual(preset("screenshot.full").display, "⌘⇧3")
        XCTAssertEqual(preset("screenshot.toolbar").display, "⌘⇧5")
        XCTAssertEqual(preset("screenshot.area.clipboard").display, "⌘⇧⌃4")
        XCTAssertEqual(preset("clipboard.copy").display, "⌘C")
        XCTAssertEqual(preset("clipboard.paste").display, "⌘V")
        XCTAssertEqual(preset("clipboard.cut").display, "⌘X")
        XCTAssertEqual(preset("editing.undo").display, "⌘Z")
        XCTAssertEqual(preset("editing.redo").display, "⌘⇧Z")
        XCTAssertEqual(preset("windows.close").display, "⌘W")
        XCTAssertEqual(preset("system.spotlight").display, "⌘Space")
        XCTAssertEqual(preset("system.lock").display, "⌘⌃Q")
        XCTAssertEqual(Set(MacShortcutPreset.all.map(\.shortcut)).count,
                       MacShortcutPreset.all.count, "Every preset should have a distinct key combination")
    }

    func testMacPresetBindingUsesNormalIndependentPersistentShortcutMapping() {
        let suite = "MoteFlow.mac-presets.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        let copy = MacShortcutPreset.all.first { $0.id == "clipboard.copy" }!.shortcut
        let area = MacShortcutPreset.all.first { $0.id == "screenshot.area" }!.shortcut
        XCTAssertTrue(store.setShortcut(copy, for: .home, gesture: .tap))
        XCTAssertTrue(store.setShortcut(area, for: .home, gesture: .longPress))
        let saved = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(saved.action(for: .home, gesture: .tap).shortcut, copy)
        XCTAssertEqual(saved.action(for: .home, gesture: .longPress).shortcut, area)
        XCTAssertEqual(saved.action(for: .home, gesture: .tap).kind, .keyboardShortcut)
        XCTAssertEqual(saved.conflictingKey(for: copy, excluding: .back, gesture: .tap), .home)
        XCTAssertFalse(saved.setShortcut(copy, for: .back, gesture: .tap))
        XCTAssertEqual(saved.action(for: .home, gesture: .tap).shortcut, copy)
    }

    func testNativeSystemActionsDoNotDependOnShortcutCombinations() {
        let nativeIDs: [String: RemoteSystemAction] = [
            "screenshot.area": .screenshotArea,
            "screenshot.full": .screenshotFull,
            "screenshot.toolbar": .screenshotToolbar,
            "screenshot.area.clipboard": .screenshotAreaClipboard,
            "screenshot.full.clipboard": .screenshotFullClipboard,
            "clipboard.copy": .copy,
            "clipboard.paste": .paste,
            "clipboard.cut": .cut,
            "editing.undo": .undo,
            "editing.redo": .redo,
            "editing.selectall": .selectAll
        ]
        for (id, intent) in nativeIDs {
            XCTAssertEqual(MacShortcutPreset.all.first(where: { $0.id == id })?.nativeAction, intent)
        }
        XCTAssertNil(MacShortcutPreset.all.first { $0.id == "system.spotlight" }?.nativeAction)
        XCTAssertNil(MacShortcutPreset.all.first { $0.id == "windows.close" }?.nativeAction)
        XCTAssertEqual(RemoteSystemAction.screenshotArea.screenshotArguments, ["-i", "-s", "-p"])
        XCTAssertEqual(RemoteSystemAction.screenshotFull.screenshotArguments, ["-p"])
        XCTAssertEqual(RemoteSystemAction.screenshotToolbar.screenshotArguments, ["-i", "-U", "-p"])
        XCTAssertEqual(RemoteSystemAction.screenshotFullClipboard.screenshotArguments, ["-c"])
        XCTAssertNil(RemoteSystemAction.copy.screenshotArguments)
        XCTAssertTrue(RemoteSystemAction.paste.usesAccessibilityMenu)
        XCTAssertFalse(RemoteSystemAction.screenshotArea.usesAccessibilityMenu)
        XCTAssertTrue(RemoteSystemAction.copy.menuTitles.contains("复制"))
    }

    func testNativeActionsPersistAcrossGesturesWithoutMigratingLegacyShortcuts() throws {
        let suite = "MoteFlow.native-actions.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        let key = RemoteKey.back
        XCTAssertTrue(store.setShortcut(shortcut, for: key, gesture: .tap))
        store.setSystemAction(.screenshotArea, for: key, gesture: .longPress)
        let saved = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(saved.action(for: key, gesture: .tap).shortcut, shortcut)
        XCTAssertEqual(saved.action(for: key, gesture: .tap).kind, .keyboardShortcut)
        XCTAssertEqual(saved.action(for: key, gesture: .longPress).kind, .systemAction)
        XCTAssertEqual(saved.action(for: key, gesture: .longPress).systemAction, .screenshotArea)
        saved.setSystemAction(.copy, for: key, gesture: .tap)
        XCTAssertNil(saved.action(for: key, gesture: .tap).shortcut)
        XCTAssertEqual(RemoteBindingStore(defaults: defaults).action(
            for: key, gesture: .tap
        ).systemAction, .copy)
        let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data(
            #"{"kind":"keyboardShortcut","shortcut":{"keyCode":8,"keyLabel":"C","command":true,"shift":false,"option":false,"control":false}}"#.utf8
        ))
        XCTAssertNil(legacy.systemAction)
    }

    func testPhysicalHoldRepeatPolicySupportsDeleteButNotModifierShortcuts() {
        let delete = RemoteShortcut(keyCode: 51, keyLabel: "Delete",
                                    command: false, shift: false, option: false, control: false)
        XCTAssertTrue(RemoteKeyRepeatPolicy.shouldRepeat(delete))
        var shiftedDelete = delete
        shiftedDelete.shift = true
        XCTAssertTrue(RemoteKeyRepeatPolicy.shouldRepeat(shiftedDelete))
        var commandDelete = delete
        commandDelete.command = true
        XCTAssertFalse(RemoteKeyRepeatPolicy.shouldRepeat(commandDelete))
        var optionDelete = delete
        optionDelete.option = true
        XCTAssertFalse(RemoteKeyRepeatPolicy.shouldRepeat(optionDelete))
        var controlDelete = delete
        controlDelete.control = true
        XCTAssertFalse(RemoteKeyRepeatPolicy.shouldRepeat(controlDelete))
        let commandOnly = RemoteShortcut(keyCode: 55, keyLabel: "Command",
                                         command: false, shift: false, option: false, control: false)
        XCTAssertFalse(RemoteKeyRepeatPolicy.shouldRepeat(commandOnly))
    }

    func testPhysicalHoldRepeatTimingHonorsSystemPreferencesSafely() {
        let suite = "MoteFlow.test.repeat-preferences.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(18, forKey: "InitialKeyRepeat")
        defaults.set(3, forKey: "KeyRepeat")
        XCTAssertEqual(RemoteKeyRepeatPolicy.initialDelay(defaults: defaults), 0.3, accuracy: 0.0001)
        XCTAssertEqual(RemoteKeyRepeatPolicy.repeatInterval(defaults: defaults), 0.05, accuracy: 0.0001)
        defaults.set(0, forKey: "KeyRepeat")
        XCTAssertEqual(RemoteKeyRepeatPolicy.repeatInterval(defaults: defaults), 0.025, accuracy: 0.0001)
    }

    func testInitialCommitATVVCommandFramesRemainCompatible() {
        XCTAssertEqual(ATVV.getCapabilities, Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03]))
        XCTAssertEqual(ATVV.micOpen(codec: 0x0001), Data([0x0C, 0x00, 0x01]))
        XCTAssertEqual(ATVV.micOpen(codec: 0x0002), Data([0x0C, 0x00, 0x02]))
        XCTAssertEqual(ATVV.micClose, Data([0x0D]))
    }

    func testATVVIdleKeepsPassiveNotificationsButNeverStartsMic() {
        XCTAssertTrue(ATVVTransportPolicy.mustKeepAudioNotificationsReady(voiceModeEnabled: true))
        XCTAssertFalse(ATVVTransportPolicy.mustKeepAudioNotificationsReady(voiceModeEnabled: false))
        XCTAssertFalse(ATVVTransportPolicy.canNegotiate(audioSubscribed: false, controlSubscribed: true))
        XCTAssertFalse(ATVVTransportPolicy.canNegotiate(audioSubscribed: true, controlSubscribed: false))
        XCTAssertTrue(ATVVTransportPolicy.canNegotiate(audioSubscribed: true, controlSubscribed: true))
    }

    func testATVVStaleStopDoesNotInstantlyEndFirstMicrophonePress() {
        // A stale 0x00 may arrive after START_SEARCH but before AUDIO_START,
        // or while MIC_OPEN is still being acknowledged. Neither should kill
        // the synthetic Doubao hold on the first press.
        XCTAssertFalse(ATVVTransportPolicy.shouldEndOnStop(
            isRecording: false, openingMic: false, hasPendingSearch: false))
        XCTAssertFalse(ATVVTransportPolicy.shouldEndOnStop(
            isRecording: false, openingMic: false, hasPendingSearch: true))
        XCTAssertFalse(ATVVTransportPolicy.shouldEndOnStop(
            isRecording: false, openingMic: true, hasPendingSearch: false))
        XCTAssertTrue(ATVVTransportPolicy.shouldEndOnStop(
            isRecording: true, openingMic: false, hasPendingSearch: false))
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
        store.resetAll() // Explicitly start with an empty workspace, not factory mapping.
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
