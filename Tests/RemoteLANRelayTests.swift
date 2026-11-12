import Foundation
import XCTest
@testable import ATVVCore

@MainActor
final class RemoteLANRelayTests: XCTestCase {
    func testSharedPortValidationSubnetAndEndpointParsing() {
        XCTAssertEqual(RemoteLANPortValidator.defaultPort, 49_280)
        XCTAssertNil(RemoteLANPortValidator.validatedPort(80))
        XCTAssertNil(RemoteLANPortValidator.validatedPort(70_000))
        XCTAssertEqual(RemoteLANPortValidator.validatedPort(49_280), 49_280)

        let plainIP = RemoteLANPortValidator.parseEndpoint("192.168.1.32", fallbackPort: 49_280)
        XCTAssertEqual(plainIP?.host, "192.168.1.32")
        XCTAssertEqual(plainIP?.port, 49_280)

        let explicitPort = RemoteLANPortValidator.parseEndpoint("10.0.0.8:51234", fallbackPort: 49_280)
        XCTAssertEqual(explicitPort?.host, "10.0.0.8")
        XCTAssertEqual(explicitPort?.port, 51_234)

        let ipv6 = RemoteLANPortValidator.parseEndpoint("[fe80::1]:49280", fallbackPort: 50_000)
        XCTAssertEqual(ipv6?.host, "fe80::1")
        XCTAssertEqual(ipv6?.port, 49_280)

        XCTAssertTrue(RemoteLANPortValidator.sameIPv4Subnet("192.168.31.10", "192.168.31.205"))
        XCTAssertFalse(RemoteLANPortValidator.sameIPv4Subnet("192.168.31.10", "192.168.32.205"))

        XCTAssertNil(RemoteLANPortValidator.parseEndpoint("   ", fallbackPort: 49_280))
        XCTAssertNil(RemoteLANPortValidator.parseEndpoint("192.168.1.5:99", fallbackPort: 49_280))
    }

    func testPairingVerificationCodeMutualHMACAndGlareTieBreaker() {
        let secret = RemoteLANAuth.randomHex(byteCount: 32)
        let cNonce = RemoteLANAuth.randomHex(byteCount: 16)
        let sNonce = RemoteLANAuth.randomHex(byteCount: 16)

        let codeOnMacA = RemoteLANAuth.verificationCode(
            clientID: "mac-a",
            serverID: "mac-b",
            clientNonce: cNonce,
            serverNonce: sNonce,
            secretHex: secret
        )
        let codeOnMacB = RemoteLANAuth.verificationCode(
            clientID: "mac-a",
            serverID: "mac-b",
            clientNonce: cNonce,
            serverNonce: sNonce,
            secretHex: secret.uppercased()
        )
        XCTAssertEqual(codeOnMacA, codeOnMacB)
        XCTAssertEqual(codeOnMacA.count, 7, "6 digits with a middle space, e.g. '482 915'")

        let clientProof = RemoteLANAuth.computeHMAC(
            secretHex: secret,
            role: "CLIENT",
            clientID: "mac-a",
            serverID: "mac-b",
            clientNonce: cNonce,
            serverNonce: sNonce
        )
        let serverProof = RemoteLANAuth.computeHMAC(
            secretHex: secret,
            role: "SERVER",
            clientID: "mac-a",
            serverID: "mac-b",
            clientNonce: cNonce,
            serverNonce: sNonce
        )
        XCTAssertNotNil(clientProof)
        XCTAssertNotNil(serverProof)
        XCTAssertFalse(RemoteLANAuth.constantTimeEquals(clientProof!, serverProof!),
                       "Client and server proofs must use distinct role tags to prevent reflection")
        XCTAssertTrue(RemoteLANAuth.constantTimeEquals(clientProof!, clientProof!.uppercased()))

        // Asymmetric auto-connect delay prevents simultaneous TCP glare between two paired Macs
        let primaryDelay = RemoteLANAuth.autoConnectDelaySeconds(localPeerID: "0001-mac", remotePeerID: "9999-mac")
        let secondaryDelay = RemoteLANAuth.autoConnectDelaySeconds(localPeerID: "9999-mac", remotePeerID: "0001-mac")
        XCTAssertLessThan(primaryDelay, secondaryDelay)
    }

    func testRemoteMappingFollowSourceResolvesSymmetricallyAcrossHostAndReceiver() {
        // On Host Mac (localIsReceiver = false):
        // - Follow Local Mac -> senderMapping (use Host's own mapping)
        // - Follow Remote Mac -> receiverMapping (let Remote Mac use its own mapping)
        XCTAssertEqual(
            RemoteMappingFollowSource.followLocalMac.resolvedDispatchMode(localIsReceiver: false),
            .senderMapping
        )
        XCTAssertEqual(
            RemoteMappingFollowSource.followRemoteMac.resolvedDispatchMode(localIsReceiver: false),
            .receiverMapping
        )

        // On Receiver Mac (localIsReceiver = true):
        // - Follow Remote Mac -> senderMapping (use the remote Host Mac's mapping)
        // - Follow Local Mac -> receiverMapping (use this Receiver Mac's own mapping)
        XCTAssertEqual(
            RemoteMappingFollowSource.followRemoteMac.resolvedDispatchMode(localIsReceiver: true),
            .senderMapping
        )
        XCTAssertEqual(
            RemoteMappingFollowSource.followLocalMac.resolvedDispatchMode(localIsReceiver: true),
            .receiverMapping
        )

        // Round-trip consistency
        for mode in RemoteRelayDispatchMode.allCases {
            for isReceiver in [false, true] {
                let source = RemoteMappingFollowSource.from(dispatchMode: mode, localIsReceiver: isReceiver)
                XCTAssertEqual(source.resolvedDispatchMode(localIsReceiver: isReceiver), mode)
            }
        }
    }

    func testOneClickConfigSyncMergeAndOverwriteWithScriptSanitization() throws {
        let suiteA = "MoteFlow.syncA.\(UUID().uuidString)"
        let suiteB = "MoteFlow.syncB.\(UUID().uuidString)"
        guard let defaultsA = UserDefaults(suiteName: suiteA),
              let defaultsB = UserDefaults(suiteName: suiteB) else {
            XCTFail("Cannot create isolated UserDefaults suites")
            return
        }
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let libA = RemoteLibraryStore(storageURL: tempDir.appendingPathComponent("libA.json"))
        let libB = RemoteLibraryStore(storageURL: tempDir.appendingPathComponent("libB.json"))
        let storeA = RemoteBindingStore(defaults: defaultsA)
        let storeB = RemoteBindingStore(defaults: defaultsB)

        // Configure custom action & bindings on Mac A (source Mac)
        let customActionID = UUID()
        let spaceShortcut = RemoteShortcut(keyCode: 49, keyLabel: "Space", command: true, shift: false, option: false, control: false)
        XCTAssertTrue(libA.save(RemoteLibraryAction(
            id: customActionID,
            name: "打开浏览器并新建标签",
            steps: [
                RemoteActionStep(kind: .openApp, applicationBundleID: "com.apple.Safari", applicationName: "Safari"),
                RemoteActionStep(kind: .keyboard, shortcut: spaceShortcut, holdSeconds: 0.08)
            ]
        )))
        // Pure script action on Mac A should NOT cross LAN
        let unsafeScriptActionID = UUID()
        XCTAssertTrue(libA.save(RemoteLibraryAction(
            id: unsafeScriptActionID,
            name: "本地危险脚本",
            steps: [RemoteActionStep(kind: .script, scriptLanguage: .bash, scriptSource: "echo secret")]
        )))

        let homeShortcutOnA = RemoteShortcut(keyCode: 4, keyLabel: "H", command: true, shift: true, option: false, control: false)
        let muteShortcutOnA = RemoteShortcut(keyCode: 46, keyLabel: "M", command: true, shift: false, option: true, control: false)
        _ = storeA.setShortcut(homeShortcutOnA, for: .home, gesture: .tap, replaceConflict: true)
        _ = storeA.setShortcut(muteShortcutOnA, for: .mute, gesture: .tap, replaceConflict: true)
        storeA.setLibraryAction(customActionID, for: .tv, gesture: .tap)
        _ = storeA.saveAsNamedProfile("办公演示方案")

        // Mac B already has its own custom `.home` binding, while `.mute` and `.tv` are empty
        let localHomeOnB = RemoteShortcut(keyCode: 35, keyLabel: "P", command: true, shift: false, option: false, control: false)
        _ = storeB.setShortcut(localHomeOnB, for: .home, gesture: .tap, replaceConflict: true)
        storeB.reset(.mute)
        storeB.reset(.tv)

        let snapshot = storeA.exportSyncSnapshot(peerName: "Mac Studio", library: libA)
        XCTAssertNil(snapshot.libraryActions.first(where: { $0.id == unsafeScriptActionID }),
                     "Script-only actions must be stripped from LAN sync snapshots")

        // 1. Test MERGE: keeps Mac B's existing `.home` binding, fills empty `.mute` & `.tv`, imports profile & safe library action
        let mergeResult = storeB.applySyncedSnapshot(snapshot, strategy: .merge, library: libB)
        XCTAssertEqual(storeB.action(for: .home, gesture: .tap).shortcut, localHomeOnB,
                       "Merge must NOT overwrite Mac B's existing configured key")
        XCTAssertEqual(storeB.action(for: .mute, gesture: .tap).shortcut, muteShortcutOnA,
                       "Merge must fill unconfigured keys from Mac A")
        XCTAssertEqual(storeB.action(for: .tv, gesture: .tap).presetID, customActionID)
        XCTAssertNotNil(libB.action(customActionID))
        XCTAssertNil(libB.action(unsafeScriptActionID))
        XCTAssertEqual(mergeResult.syncedProfileCount, 1)

        // 2. Test OVERWRITE: replaces Mac B's `.home` binding so both Macs match 1:1
        let overwriteResult = storeB.applySyncedSnapshot(snapshot, strategy: .overwrite, library: libB)
        XCTAssertEqual(storeB.action(for: .home, gesture: .tap).shortcut, homeShortcutOnA,
                       "Overwrite must replace Mac B's binding with Mac A's binding")
        XCTAssertGreaterThanOrEqual(overwriteResult.updatedKeyGestureCount, 1)
    }

    func testStreamDeframerHandlesFragmentedFramesAndUnknownFutureMessages() throws {
        let shortcut = RemoteShortcut(
            keyCode: 124, keyLabel: "→",
            command: false, shift: false, option: false, control: false
        )
        let msg1 = RemoteLANWireMessage.ping(sentAtMs: 123_456.5)
        let msg2 = RemoteLANWireMessage.peerStateSync(dispatchMode: .receiverMapping, hasPhysicalRemote: true)
        let msg3 = RemoteLANWireMessage.forwardedAction(
            key: .right,
            gesture: .tap,
            mode: .senderMapping,
            senderModel: .googleG9N9N,
            shortcut: shortcut,
            holdSeconds: 0.08,
            systemAction: nil,
            librarySteps: nil
        )

        // Inject a synthetic unknown future enum JSON payload in between msg1 and msg2
        let unknownPayload = Data(#"{"futureMessageCase":{"version":99}}"#.utf8)
        var lengthBE = UInt32(unknownPayload.count).bigEndian
        var unknownFramed = Data()
        withUnsafeBytes(of: &lengthBE) { unknownFramed.append(contentsOf: $0) }
        unknownFramed.append(unknownPayload)

        let combined = try RemoteLANFrameCodec.encode(msg1) +
                       unknownFramed +
                       RemoteLANFrameCodec.encode(msg2) +
                       RemoteLANFrameCodec.encode(msg3)

        var deframer = RemoteLANFrameCodec.StreamDeframer()
        var received: [RemoteLANWireMessage] = []
        var offset = 0
        while offset < combined.count {
            let end = min(offset + 7, combined.count)
            let chunk = combined.subdata(in: offset..<end)
            received.append(contentsOf: try deframer.append(chunk))
            offset = end
        }
        XCTAssertEqual(received, [msg1, msg2, msg3])
    }

    func testForwardedStepsSanitizationStripsArbitraryShellScripts() {
        let steps: [RemoteActionStep] = [
            RemoteActionStep(kind: .openApp, applicationBundleID: "com.apple.Safari", applicationName: "Safari"),
            RemoteActionStep(kind: .wait, waitSeconds: 0.3),
            RemoteActionStep(kind: .script, scriptLanguage: .bash, scriptSource: "rm -rf /tmp/test"),
            RemoteActionStep(
                kind: .keyboard,
                shortcut: RemoteShortcut(keyCode: 17, keyLabel: "T", command: true, shift: false, option: false, control: false),
                holdSeconds: 0.08
            )
        ]
        let sanitized = RemoteLANForwardedStep.sanitizedSteps(from: steps)
        XCTAssertEqual(sanitized?.map(\.kind), [.openApp, .wait, .keyboard])
    }

    func testVoicePCMRoundTripPreservesSigned16BitSamples() {
        let samples: [Int16] = [-32768, -1024, -1, 0, 1, 1024, 32767]
        let encoded = RemoteLANPCMCodec.encodeSamples(samples)
        XCTAssertEqual(encoded.count, samples.count * 2)
        XCTAssertEqual(RemoteLANPCMCodec.decodeSamples(encoded), samples)
    }
}
