import Foundation

/// Explicit value-type finite state machine governing local and Dual-Mac voice
/// sessions. Centralizing transitions prevents duplicate `voiceStart` packets,
/// leaked shortcut holds, or stuck speaker echo suppression when connections drop.
struct VoiceSessionStateMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case localVirtualMic(holdingShortcut: Bool)
        case localActionFallback
        case forwardingToRemoteMac
        case receivingRemoteVirtualMic(holdingShortcut: Bool)
        case receivingRemoteForLocalTranscription
    }

    enum EndEffect: Equatable, Sendable {
        case none
        case stopLocalVoice(releaseShortcutHold: Bool, restoreVirtualMic: Bool)
        case stopForwardedVoice(releaseShortcutHold: Bool, releaseEchoSuppression: Bool)
        case finishIncomingRemoteVoice(
            releaseShortcutHold: Bool,
            gracefullyDrainVirtualMic: Bool,
            transcribeRecordedWave: Bool
        )
    }

    private(set) var phase: Phase = .idle

    var isActive: Bool {
        phase != .idle
    }

    var isForwardingRemotely: Bool {
        phase == .forwardingToRemoteMac
    }

    /// Transitions when local physical remote initiates a voice session.
    /// Returns `false` if already forwarding or active in an incompatible phase
    /// (preventing duplicate `START_SEARCH` / `AUDIO_START` double-triggers).
    @discardableResult
    mutating func beginLocalOrForwardedSession(
        forwardingToRemote: Bool,
        hasVoiceShortcut: Bool,
        trigger: DoubaoShortcutTrigger
    ) -> Bool {
        if forwardingToRemote {
            guard phase != .forwardingToRemoteMac else { return false }
            phase = .forwardingToRemoteMac
            return true
        }
        switch phase {
        case .localVirtualMic, .receivingRemoteVirtualMic, .receivingRemoteForLocalTranscription:
            return false
        case .idle, .localActionFallback, .forwardingToRemoteMac:
            if hasVoiceShortcut {
                phase = .localVirtualMic(holdingShortcut: trigger == .hold)
            } else {
                phase = .localActionFallback
            }
            return true
        }
    }

    /// Transitions when this Mac receives `voiceStart` over LAN from a peer Mac.
    mutating func beginIncomingRemoteSession(
        hasVirtualMic: Bool,
        hasTargetShortcut: Bool,
        trigger: DoubaoShortcutTrigger
    ) {
        if hasVirtualMic && hasTargetShortcut {
            phase = .receivingRemoteVirtualMic(holdingShortcut: trigger == .hold)
        } else {
            phase = .receivingRemoteForLocalTranscription
        }
    }

    /// Transitions back to `.idle` when local/forwarded physical key releases or stream ends.
    mutating func endLocalOrForwardedSession() -> EndEffect {
        defer { phase = .idle }
        switch phase {
        case .idle:
            return .stopLocalVoice(releaseShortcutHold: true, restoreVirtualMic: true)
        case .localVirtualMic(let holding):
            return .stopLocalVoice(releaseShortcutHold: holding, restoreVirtualMic: true)
        case .localActionFallback:
            return .stopLocalVoice(releaseShortcutHold: false, restoreVirtualMic: true)
        case .forwardingToRemoteMac:
            return .stopForwardedVoice(releaseShortcutHold: true, releaseEchoSuppression: true)
        case .receivingRemoteVirtualMic(let holding):
            return .finishIncomingRemoteVoice(
                releaseShortcutHold: holding,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: false
            )
        case .receivingRemoteForLocalTranscription:
            return .finishIncomingRemoteVoice(
                releaseShortcutHold: false,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: true
            )
        }
    }

    /// Transitions back to `.idle` when an incoming remote LAN voice stream finishes.
    mutating func endIncomingRemoteSession(recordedSamples: Int, minimumSamples: Int = 1_200) -> EndEffect {
        let previous = phase
        phase = .idle
        switch previous {
        case .receivingRemoteVirtualMic(let holding):
            return .finishIncomingRemoteVoice(
                releaseShortcutHold: holding,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: false
            )
        case .receivingRemoteForLocalTranscription:
            return .finishIncomingRemoteVoice(
                releaseShortcutHold: false,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: recordedSamples > minimumSamples
            )
        default:
            return .finishIncomingRemoteVoice(
                releaseShortcutHold: true,
                gracefullyDrainVirtualMic: true,
                transcribeRecordedWave: false
            )
        }
    }

    mutating func reset() {
        phase = .idle
    }
}
