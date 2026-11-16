import Darwin
import Foundation
import Network

/// Dedicated single-responsibility LAN discovery engine combining Bonjour
/// (`_moteflow._tcp`) with a same-port UDP broadcast beacon so two Macs on the
/// same Wi-Fi/LAN find each other automatically within seconds.
@MainActor
final class RemoteLANDiscoveryService {
    var onPeerDiscovered: ((String, String, String?, UInt16, Bool) -> Void)?
    var onBonjourPeersSnapshot: ((Set<String>) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var bonjourEndpoints: [String: NWEndpoint] = [:]
    private var browser: NWBrowser?
    private var udpFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var beaconTask: Task<Void, Never>?

    func start(
        localPeerID: String,
        localPeerName: String,
        port: UInt16,
        localIPsProvider: @escaping () -> [String]
    ) {
        stop()
        startBonjourBrowser(localPeerID: localPeerID, fallbackPort: port)
        startUDPBeacon(
            localPeerID: localPeerID,
            localPeerName: localPeerName,
            port: port,
            localIPsProvider: localIPsProvider
        )
    }

    func stop() {
        browser?.cancel()
        browser = nil
        bonjourEndpoints.removeAll()
        beaconTask?.cancel()
        beaconTask = nil
        if let udpReadSource {
            udpReadSource.cancel()
            self.udpReadSource = nil
        } else if udpFD >= 0 {
            Darwin.close(udpFD)
            udpFD = -1
        }
    }

    func triggerImmediateScan(
        localPeerID: String,
        localPeerName: String,
        port: UInt16,
        localIPs: [String]
    ) {
        sendUDPBeaconBroadcast(
            localPeerID: localPeerID,
            localPeerName: localPeerName,
            port: port,
            localIPs: localIPs
        )
        browser?.cancel()
        startBonjourBrowser(localPeerID: localPeerID, fallbackPort: port)
    }

    static func currentLANIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.hasPrefix("169.254."), !addresses.contains(ip) {
                            addresses.append(ip)
                        }
                    }
                }
            }
            cursor = interface.ifa_next
        }
        return addresses
    }

    // MARK: - Bonjour

    private func startBonjourBrowser(localPeerID: String, fallbackPort: UInt16) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let nwBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: RemoteLANPortValidator.bonjourServiceType, domain: nil),
            using: params
        )
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var activeIDs: Set<String> = []
                for result in results {
                    guard case let .bonjour(txt) = result.metadata else { continue }
                    let dict = txt.dictionary
                    guard let peerID = dict["peerID"], peerID != localPeerID else { continue }
                    let name = dict["name"] ?? "Mac 设备"
                    let port = dict["port"].flatMap { UInt16($0) } ?? fallbackPort
                    activeIDs.insert(peerID)
                    self.bonjourEndpoints[peerID] = result.endpoint
                    self.onPeerDiscovered?(peerID, name, nil, port, true)
                }
                self.onBonjourPeersSnapshot?(activeIDs)
            }
        }
        nwBrowser.start(queue: .main)
        browser = nwBrowser
    }

    // MARK: - Same-Port UDP Broadcast Beacon

    private func startUDPBeacon(
        localPeerID: String,
        localPeerName: String,
        port: UInt16,
        localIPsProvider: @escaping () -> [String]
    ) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            return
        }
        udpFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.readUDPPackets(localPeerID: localPeerID)
            }
        }
        source.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.udpFD >= 0 else { return }
                Darwin.close(self.udpFD)
                self.udpFD = -1
            }
        }
        source.resume()
        udpReadSource = source

        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendUDPBeaconBroadcast(
                    localPeerID: localPeerID,
                    localPeerName: localPeerName,
                    port: port,
                    localIPs: localIPsProvider()
                )
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func sendUDPBeaconBroadcast(
        localPeerID: String,
        localPeerName: String,
        port: UInt16,
        localIPs: [String]
    ) {
        guard udpFD >= 0 else { return }
        let payload = RemoteLANBeaconPayload(
            peerID: localPeerID,
            peerName: localPeerName,
            tcpPort: port,
            sentAtMs: Date().timeIntervalSince1970 * 1000
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }

        var destinations: [String] = ["255.255.255.255"]
        for ip in localIPs {
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                let subnet = "\(parts[0]).\(parts[1]).\(parts[2]).255"
                if !destinations.contains(subnet) {
                    destinations.append(subnet)
                }
            }
        }

        for targetIP in destinations {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            guard inet_pton(AF_INET, targetIP, &dest.sin_addr) == 1 else { continue }
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = Darwin.sendto(
                            udpFD,
                            base,
                            data.count,
                            0,
                            sockPtr,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
        }
    }

    private func readUDPPackets(localPeerID: String) {
        guard udpFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var sender = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.recvfrom(udpFD, &buf, buf.count, 0, sockPtr, &senderLen)
                }
            }
            guard count > 0 else { break }
            let packet = Data(buf.prefix(count))
            guard let beacon = try? JSONDecoder().decode(RemoteLANBeaconPayload.self, from: packet),
                  beacon.magic == RemoteLANBeaconPayload.currentMagic,
                  beacon.peerID != localPeerID else { continue }

            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = sender.sin_addr
            guard inet_ntop(AF_INET, &addrCopy, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let senderIP = String(cString: ipBuffer)
            onPeerDiscovered?(
                beacon.peerID,
                beacon.peerName,
                senderIP,
                beacon.tcpPort,
                bonjourEndpoints[beacon.peerID] != nil
            )
        }
    }
}
