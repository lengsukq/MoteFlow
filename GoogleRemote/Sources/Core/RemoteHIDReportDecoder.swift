import Foundation

/// A button code is learned from an actual remote report, not guessed from
/// Consumer Control usages or a currently selected UI label.
struct RemoteHIDButtonCode: Codable, Hashable, Equatable {
    let reportID: UInt8
    let code: UInt16
}

enum RemoteHIDReportDecoder {
    /// The G9N9N sample observed on this Mac:
    /// REPORT id=1 bytes=01 0C 00 -> code 12 (press)
    /// REPORT id=1 bytes=01 00 00 -> zero (release).
    /// Only decode this exact shape; other layouts remain raw diagnostics
    /// rather than misidentified key events.
    static func decode(reportID: Int, bytes: [UInt8]) -> RemoteHIDButtonCode? {
        guard (0...255).contains(reportID) else { return nil }
        let payload: [UInt8]
        if bytes.count == 3 && bytes[0] == UInt8(reportID) {
            payload = Array(bytes.dropFirst())
        } else if bytes.count == 2 {
            payload = bytes
        } else {
            return nil
        }
        let value = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        return RemoteHIDButtonCode(reportID: UInt8(reportID), code: value)
    }
}
