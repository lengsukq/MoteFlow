import Foundation
import XCTest
@testable import ATVVCore

@MainActor
final class RemoteActionLibraryTests: XCTestCase {
    private var exampleKey: RemoteShortcut {
        RemoteShortcut(keyCode: 40, keyLabel: "K",
                       command: false, shift: false, option: false, control: false)
    }

    func testSingleKeyAndLongPressAreIndependent() {
        let suite = "GoogleRemote.test-gestures.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { XCTFail(); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteBindingStore(defaults: defaults)
        XCTAssertTrue(store.setShortcut(exampleKey, for: .home, gesture: .tap))
        XCTAssertTrue(store.setShortcut(exampleKey, for: .home, gesture: .longPress))
        store.setOutputHold(2.0, for: .home, gesture: .tap)
        store.setLongPressThreshold(1.2, for: .home)

        let reloaded = RemoteBindingStore(defaults: defaults)
        XCTAssertEqual(reloaded.action(for: .home, gesture: .tap).effectiveHoldSeconds, 2.0)
        XCTAssertEqual(reloaded.action(for: .home, gesture: .longPress).effectiveHoldSeconds, 0.08)
        XCTAssertEqual(reloaded.binding(for: .home).effectiveThreshold, 1.2)
        XCTAssertEqual(RemotePressClassifier.gesture(duration: 0.9, threshold: 1.2), .tap)
        XCTAssertEqual(RemotePressClassifier.gesture(duration: 1.2, threshold: 1.2), .longPress)
        reloaded.reset(.home, gesture: .tap)
        XCTAssertEqual(reloaded.action(for: .home, gesture: .tap).kind, .none)
        XCTAssertEqual(reloaded.action(for: .home, gesture: .longPress).kind, .keyboardShortcut)
        XCTAssertEqual(reloaded.configuredCount, 1)
    }

    func testUnifiedActionLibraryPersistsAndReferencesLiveSteps() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleRemote-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ActionLibrary.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = RemoteLibraryStore(storageURL: file)
        XCTAssertEqual(library.actions.count, 1)
        XCTAssertEqual(library.action(RemoteLibraryStore.chatGPTPresetID)?.steps.map(\.kind),
                       [.openApp, .wait, .keyboard])
        let id = UUID()
        let action = RemoteLibraryAction(id: id, name: "示例动作", steps: [
            RemoteActionStep(kind: .keyboard, shortcut: exampleKey, holdSeconds: 0.7),
            RemoteActionStep(kind: .wait, waitSeconds: 0.25),
            RemoteActionStep(kind: .script, scriptLanguage: .bash, scriptSource: "printf '%s' ok")
        ])
        XCTAssertTrue(library.save(action), library.error ?? "")
        XCTAssertEqual(library.actions.count, 2)
        XCTAssertEqual(library.action(id)?.steps.count, 3)

        let shortcutReference = RemoteAction(kind: .libraryAction, presetID: id)
        XCTAssertEqual(library.description(for: shortcutReference), "示例动作")
        XCTAssertEqual(library.steps(for: shortcutReference)?.count, 3)

        var updated = action
        updated.steps[0].shortcut = RemoteShortcut(keyCode: 36, keyLabel: "↩",
            command: false, shift: false, option: false, control: false)
        XCTAssertTrue(library.save(updated))
        XCTAssertEqual(library.steps(for: shortcutReference)?.first?.shortcut?.keyCode, 36)

        let reloaded = RemoteLibraryStore(storageURL: file)
        XCTAssertEqual(reloaded.actions.count, 2)
        XCTAssertEqual(reloaded.steps(for: shortcutReference)?.count, 3)
        reloaded.delete(id)
        XCTAssertNil(reloaded.steps(for: shortcutReference))
        XCTAssertEqual(RemoteLibraryStore(storageURL: file).actions.count, 1)
    }

    func testUnifiedLibraryRejectsEmptyAndRecursiveActions() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleRemote-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ActionLibrary.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = RemoteLibraryStore(storageURL: file)
        XCTAssertFalse(library.save(RemoteLibraryAction(name: "空", steps: [])))
        XCTAssertFalse(library.save(RemoteLibraryAction(name: "未录制", steps: [
            RemoteActionStep(kind: .keyboard)
        ])))
        XCTAssertTrue(library.save(RemoteLibraryAction(name: "脚本", steps: [
            RemoteActionStep(kind: .script, scriptLanguage: .zsh,
                             scriptSource: "echo hello")
        ])))
        XCTAssertEqual(library.actions.count, 2)
    }

    func testOpenApplicationActionsAreReusableAndValidated() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleRemote-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ActionLibrary.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = RemoteLibraryStore(storageURL: file)
        let action = RemoteLibraryAction(name: "打开 Safari", steps: [
            RemoteActionStep(kind: .openApp,
                             applicationBundleID: "com.apple.Safari",
                             applicationName: "Safari")
        ])
        XCTAssertTrue(library.save(action), library.error ?? "")
        let ref = RemoteAction(kind: .libraryAction, presetID: action.id)
        XCTAssertEqual(library.steps(for: ref)?.first?.applicationBundleID, "com.apple.Safari")
        XCTAssertEqual(RemoteLibraryStore(storageURL: file).action(action.id)?.steps, action.steps)
        XCTAssertFalse(library.save(RemoteLibraryAction(name: "无效启动", steps: [
            RemoteActionStep(kind: .openApp, applicationBundleID: "/bin/bash")
        ])))
    }
}
