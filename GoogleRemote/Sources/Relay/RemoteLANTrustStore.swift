import Foundation

/// Single-responsibility store managing paired Dual-Mac trust records,
/// session-paused auto-connect exclusions, rate-limiting, and candidate selection.
@MainActor
final class RemoteLANTrustStore {
    private let defaults: UserDefaults
    private let trustedPeersKey: String
    private let lastConnectedPeerKey: String

    private(set) var trustedPeers: [RemoteTrustedPeer] = []
    private(set) var pausedAutoConnectPeerIDs: Set<String> = []
    private var lastAutoConnectAttemptByPeer: [String: Date] = [:]

    init(
        defaults: UserDefaults,
        trustedPeersKey: String = "MoteFlow.lanRelay.trustedPeers.v1",
        lastConnectedPeerKey: String = "MoteFlow.lanRelay.lastConnectedPeerID.v1"
    ) {
        self.defaults = defaults
        self.trustedPeersKey = trustedPeersKey
        self.lastConnectedPeerKey = lastConnectedPeerKey
        if let data = defaults.data(forKey: trustedPeersKey),
           let saved = try? JSONDecoder().decode([RemoteTrustedPeer].self, from: data) {
            trustedPeers = saved
        }
    }

    func isTrusted(_ peerID: String) -> Bool {
        trustedPeers.contains(where: { $0.id == peerID })
    }

    func trustedPeer(id: String) -> RemoteTrustedPeer? {
        trustedPeers.first(where: { $0.id == id })
    }

    func rememberLastConnectedPeer(_ peerID: String) {
        pausedAutoConnectPeerIDs.remove(peerID)
        defaults.set(peerID, forKey: lastConnectedPeerKey)
    }

    func pauseForCurrentSession(_ peerID: String) {
        pausedAutoConnectPeerIDs.insert(peerID)
    }

    func unpausePeer(_ peerID: String) {
        pausedAutoConnectPeerIDs.remove(peerID)
    }

    func clearAllSessionPauses(resetAttemptTimers: Bool = false) {
        pausedAutoConnectPeerIDs.removeAll()
        if resetAttemptTimers {
            lastAutoConnectAttemptByPeer.removeAll()
        }
    }

    func canAttemptAutoConnect(peerID: String, now: Date = Date(), cooldownSeconds: TimeInterval) -> Bool {
        if let lastTry = lastAutoConnectAttemptByPeer[peerID],
           now.timeIntervalSince(lastTry) < cooldownSeconds {
            return false
        }
        lastAutoConnectAttemptByPeer[peerID] = now
        return true
    }

    func upsert(id: String, name: String, secretHex: String, host: String?, port: UInt16) {
        let existingDate = trustedPeers.first(where: { $0.id == id })?.pairedAt ?? Date()
        let record = RemoteTrustedPeer(
            id: id,
            name: name,
            sharedSecretHex: secretHex,
            lastHost: host,
            lastPort: port,
            pairedAt: existingDate
        )
        if let index = trustedPeers.firstIndex(where: { $0.id == id }) {
            trustedPeers[index] = record
        } else {
            trustedPeers.append(record)
        }
        persist()
    }

    func remove(_ id: String) {
        trustedPeers.removeAll { $0.id == id }
        pausedAutoConnectPeerIDs.remove(id)
        if defaults.string(forKey: lastConnectedPeerKey) == id {
            defaults.removeObject(forKey: lastConnectedPeerKey)
        }
        persist()
    }

    func selectPreferredCandidate(
        from discoveredPeers: [RemoteDiscoveredPeer],
        ignoreSessionPause: Bool = false
    ) -> RemoteDiscoveredPeer? {
        let eligible = discoveredPeers.filter { peer in
            isTrusted(peer.id) && (ignoreSessionPause || !pausedAutoConnectPeerIDs.contains(peer.id))
        }
        guard !eligible.isEmpty else { return nil }
        if let lastID = defaults.string(forKey: lastConnectedPeerKey),
           let preferred = eligible.first(where: { $0.id == lastID }) {
            return preferred
        }
        return eligible.max { lhs, rhs in
            let lDate = trustedPeer(id: lhs.id)?.pairedAt ?? .distantPast
            let rDate = trustedPeer(id: rhs.id)?.pairedAt ?? .distantPast
            return lDate < rDate
        }
    }

    func orderedSubnetFallbackCandidates(localIPs: [String]) -> [RemoteTrustedPeer] {
        guard !localIPs.isEmpty else { return [] }
        return trustedPeers
            .filter { !pausedAutoConnectPeerIDs.contains($0.id) }
            .sorted { $0.pairedAt > $1.pairedAt }
            .filter { trusted in
                guard let host = trusted.lastHost else { return false }
                return localIPs.contains { RemoteLANPortValidator.sameIPv4Subnet($0, host) }
            }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(trustedPeers) {
            defaults.set(data, forKey: trustedPeersKey)
        }
    }
}
