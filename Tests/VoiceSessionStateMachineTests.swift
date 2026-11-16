import XCTest
@testable import ATVVCore

final class VoiceSessionStateMachineTests: XCTestCase {
    func testLocalHoldSessionPreventsDuplicateStartAndReleasesCleanly() {
        var fsm = VoiceSessionStateMachine()
        XCTAssertEqual(fsm.phase, .idle)

        let started = fsm.beginLocalOrForwardedSession(
            forwardingToRemote: false,
            hasVoiceShortcut: true,
            trigger: .hold
        )
        XCTAssertTrue(started)
        XCTAssertEqual(fsm.phase, .localVirtualMic(holdingShortcut: true))

        // Duplicate START_SEARCH while holding must be rejected
        let duplicate = fsm.beginLocalOrForwardedSession(
            forwardingToRemote: false,
            hasVoiceShortcut: true,
            trigger: .hold
        )
        XCTAssertFalse(duplicate)

        let effect = fsm.endLocalOrForwardedSession()
        XCTAssertEqual(effect, .stopLocalVoice(releaseShortcutHold: true, restoreVirtualMic: true))
        XCTAssertEqual(fsm.phase, .idle)
    }

    func testForwardedRemoteSessionSuppressesDuplicateStartAndReleasesEchoSuppression() {
        var fsm = VoiceSessionStateMachine()
        XCTAssertTrue(
            fsm.beginLocalOrForwardedSession(
                forwardingToRemote: true,
                hasVoiceShortcut: true,
                trigger: .tap
            )
        )
        XCTAssertTrue(fsm.isForwardingRemotely)
        XCTAssertFalse(
            fsm.beginLocalOrForwardedSession(
                forwardingToRemote: true,
                hasVoiceShortcut: true,
                trigger: .tap
            ),
            "Repeated voiceStart from HID + BLE must not double-fire tap shortcuts on Mac B"
        )

        let endEffect = fsm.endLocalOrForwardedSession()
        XCTAssertEqual(
            endEffect,
            .stopForwardedVoice(releaseShortcutHold: true, releaseEchoSuppression: true)
        )
        XCTAssertFalse(fsm.isActive)
    }

    func testIncomingRemoteSessionFallsBackToLocalTranscriptionOnlyWithEnoughSamples() {
        var fsm = VoiceSessionStateMachine()
        fsm.beginIncomingRemoteSession(
            hasVirtualMic: false,
            hasTargetShortcut: true,
            trigger: .hold
        )
        XCTAssertEqual(fsm.phase, .receivingRemoteForLocalTranscription)

        let tooShort = fsm.endIncomingRemoteSession(recordedSamples: 400)
        XCTAssertEqual(
            tooShort,
            .finishIncomingRemoteVoice(
                releaseShortcutHold: false,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: false
            )
        )

        fsm.beginIncomingRemoteSession(
            hasVirtualMic: false,
            hasTargetShortcut: false,
            trigger: .tap
        )
        let validSpeech = fsm.endIncomingRemoteSession(recordedSamples: 8_000)
        XCTAssertEqual(
            validSpeech,
            .finishIncomingRemoteVoice(
                releaseShortcutHold: false,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: true
            )
        )
    }
}
