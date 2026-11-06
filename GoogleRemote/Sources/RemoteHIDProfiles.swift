import Foundation

/// Shareable, versioned HID map. No Bluetooth UUID, serial, MAC address,
/// username, absolute path, or script/shortcut data is included.
struct RemoteHIDDeviceIdentity: Codable, Equatable {
    let vendorID: Int
    let productID: Int
    let productName: String
    let transport: String

    func matches(_ other: RemoteHIDDeviceIdentity) -> Bool {
        vendorID == other.vendorID &&
        productID == other.productID &&
        productName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(other.productName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame &&
        transport.caseInsensitiveCompare(other.transport) == .orderedSame
    }
}

struct RemoteHIDProfileEntry: Codable, Equatable {
    let key: RemoteKey
    let reportID: UInt8
    let code: UInt16

    var buttonCode: RemoteHIDButtonCode {
        RemoteHIDButtonCode(reportID: reportID, code: code)
    }
}

enum RemoteHIDProfileError: LocalizedError {
    case version
    case format
    case invalidDevice
    case duplicateKey
    case duplicateCode
    case invalidCode
    case noEntries

    var errorDescription: String? {
        switch self {
        case .version: "映射文件版本不支持"
        case .format: "HID 报告格式不匹配"
        case .invalidDevice: "缺少有效的遥控器型号或 USB VID/PID 信息"
        case .duplicateKey: "同一个遥控器按钮重复出现"
        case .duplicateCode: "两个遥控器按钮使用了相同的 HID 编码"
        case .invalidCode: "HID 编码不能是 0（0 表示松开）"
        case .noEntries: "当前没有已学习的按键可导出"
        }
    }
}

struct RemoteHIDProfile: Codable, Equatable {
    static let currentVersion = 1
    static let supportedFormat = "g9n9n-hid-report-2byte-le"

    let schemaVersion: Int
    let reportFormat: String
    let device: RemoteHIDDeviceIdentity
    let createdAt: Date
    let entries: [RemoteHIDProfileEntry]

    init(device: RemoteHIDDeviceIdentity,
         codes: [RemoteKey: RemoteHIDButtonCode],
         createdAt: Date = Date()) {
        self.schemaVersion = Self.currentVersion
        self.reportFormat = Self.supportedFormat
        self.device = device
        self.createdAt = createdAt
        self.entries = RemoteKey.allCases.compactMap { key in
            codes[key].map { RemoteHIDProfileEntry(key: key, reportID: $0.reportID, code: $0.code) }
        }
    }

    func validatedCodes() throws -> [RemoteKey: RemoteHIDButtonCode] {
        guard schemaVersion == Self.currentVersion else { throw RemoteHIDProfileError.version }
        guard reportFormat == Self.supportedFormat else { throw RemoteHIDProfileError.format }
        guard (0...0xFFFF).contains(device.vendorID),
              (0...0xFFFF).contains(device.productID),
              (device.vendorID != 0 || device.productID != 0),
              !device.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !device.transport.isEmpty else { throw RemoteHIDProfileError.invalidDevice }
        guard !entries.isEmpty else { throw RemoteHIDProfileError.noEntries }
        var result: [RemoteKey: RemoteHIDButtonCode] = [:]
        var rawCodes: Set<RemoteHIDButtonCode> = []
        for entry in entries {
            guard entry.code != 0 else { throw RemoteHIDProfileError.invalidCode }
            guard result[entry.key] == nil else { throw RemoteHIDProfileError.duplicateKey }
            guard rawCodes.insert(entry.buttonCode).inserted else {
                throw RemoteHIDProfileError.duplicateCode
            }
            result[entry.key] = entry.buttonCode
        }
        return result
    }

    func exportData() throws -> Data {
        _ = try validatedCodes()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func importData(_ data: Data) throws -> RemoteHIDProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(RemoteHIDProfile.self, from: data)
        _ = try profile.validatedCodes()
        return profile
    }
}

enum RemoteHIDProfileResolver {
    /// Local overrides win over built-in defaults. A code collision evicts
    /// the previous default instead of mapping one physical key to two buttons.
    static func merged(defaults: [RemoteKey: RemoteHIDButtonCode],
                       overrides: [RemoteKey: RemoteHIDButtonCode]) -> [RemoteKey: RemoteHIDButtonCode] {
        var result = defaults
        for key in RemoteKey.allCases {
            guard let code = overrides[key] else { continue }
            for (oldKey, oldCode) in result where oldKey != key && oldCode == code {
                result.removeValue(forKey: oldKey)
            }
            result[key] = code
        }
        return result
    }
}

/// Verified G9N9N profile captured and exported from a real Chromecast Remote.
/// The microphone/assistant key is intentionally absent: its press is observed
/// through ATVV control events, not the regular 2-byte HID Report format.
enum RemoteHIDDefaultProfiles {
    static let profiles: [RemoteHIDProfile] = [
        RemoteHIDProfile(
            device: RemoteHIDDeviceIdentity(
                vendorID: 6353, productID: 37968,
                productName: "Chromecast Remote", transport: "Bluetooth Low Energy"
            ),
            codes: [
                .up: RemoteHIDButtonCode(reportID: 1, code: 3),
                .down: RemoteHIDButtonCode(reportID: 1, code: 4),
                .left: RemoteHIDButtonCode(reportID: 1, code: 5),
                .right: RemoteHIDButtonCode(reportID: 1, code: 6),
                .select: RemoteHIDButtonCode(reportID: 1, code: 7),
                .back: RemoteHIDButtonCode(reportID: 1, code: 11),
                .home: RemoteHIDButtonCode(reportID: 1, code: 10),
                .mute: RemoteHIDButtonCode(reportID: 1, code: 8),
                .youtube: RemoteHIDButtonCode(reportID: 1, code: 14),
                .netflix: RemoteHIDButtonCode(reportID: 1, code: 15),
                .power: RemoteHIDButtonCode(reportID: 1, code: 1),
                .input: RemoteHIDButtonCode(reportID: 1, code: 17),
                .volumeUp: RemoteHIDButtonCode(reportID: 1, code: 12),
                .volumeDown: RemoteHIDButtonCode(reportID: 1, code: 13)
            ],
            createdAt: Date(timeIntervalSince1970: 1_793_924_198)
        )
    ]

    static func verifiedCodes(for device: RemoteHIDDeviceIdentity) -> [RemoteKey: RemoteHIDButtonCode] {
        guard let profile = profiles.first(where: { $0.device.matches(device) }),
              let codes = try? profile.validatedCodes() else { return [:] }
        return codes
    }
}
