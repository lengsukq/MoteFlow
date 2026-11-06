import Foundation

/// A visual/semantic model is separate from a verified HID report map. A
/// device's matching VID/PID alone never proves its voice transport or key map.
enum RemoteDeviceModel: String, Codable, CaseIterable, Identifiable {
    case googleG9N9N = "google-g9n9n"
    case xiaomiRemote2 = "xiaomi-rc001"
    case xiaomiRemote2Pro = "xiaomi-rc003"
    case generic = "generic-remote"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .googleG9N9N: "Chromecast Voice Remote"
        case .xiaomiRemote2: "小米蓝牙遥控器 2"
        case .xiaomiRemote2Pro: "小米蓝牙遥控器 2 Pro"
        case .generic: "通用遥控器"
        }
    }
    var modelLabel: String {
        switch self {
        case .googleG9N9N: "Google · G9N9N"
        case .xiaomiRemote2: "Xiaomi · RC001"
        case .xiaomiRemote2Pro: "Xiaomi · RC003"
        case .generic: "手动学习"
        }
    }
    var keys: [RemoteKey] {
        switch self {
        case .googleG9N9N:
            return [.up, .down, .left, .right, .select, .back, .assistant,
                    .home, .mute, .youtube, .netflix, .power, .input, .volumeUp, .volumeDown]
        case .xiaomiRemote2, .xiaomiRemote2Pro:
            return [.power, .assistant, .up, .down, .left, .right, .select,
                    .back, .home, .menu, .volumeUp, .volumeDown, .tv]
        case .generic:
            return [.up, .down, .left, .right, .select, .back,
                    .home, .menu, .assistant, .volumeUp, .volumeDown, .power]
        }
    }
    var description: String {
        switch self {
        case .googleG9N9N: "G9N9N · 已有真实 HID 采样与 ATVV 语音实现"
        case .xiaomiRemote2: "RC001 · 内置外观与按键布局，实体 HID 需校验"
        case .xiaomiRemote2Pro: "RC003 · 独立硬件型号，语音协议需真机验证"
        case .generic: "按键布局可操作，实体键需逐个学习"
        }
    }
    var suggestedKeys: [RemoteKey] { keys }
    var hasVerifiedGoogleHID: Bool { self == .googleG9N9N }
}

/// These are conservative standard keyboard/consumer HID usages observed in
/// external Xiaomi remote references. Their presence in a report still needs
/// direct user-hardware validation; never reuse Chromecast's report offsets.
enum XiaomiHIDUsageMapper {
    static func key(usagePage: Int, usage: Int) -> RemoteKey? {
        switch usagePage {
        case 0x07:
            switch usage {
            case 0x52: .up
            case 0x51: .down
            case 0x50: .left
            case 0x4F: .right
            case 0x28: .select
            case 0x29: .back
            case 0x4A: .home
            case 0x65: .menu
            case 0x66: .power
            case 0x3E: .assistant
            default: nil
            }
        case 0x0C:
            switch usage {
            case 0xE9: .volumeUp
            case 0xEA: .volumeDown
            case 0x224: .back
            case 0x30: .power
            default: nil
            }
        default: nil
        }
    }
}

enum RemoteDeviceProfileRegistry {
    static let builtIn: [RemoteDeviceModel] = RemoteDeviceModel.allCases
    static let xiaomiVID = 0x2717
    static let remote2PID = 0x32B8
    static let remote2ProCandidatePID = 0x32B0

    /// Xiaomi matching needs both an exact vendor+product combination and a
    /// non-keyboard, remote-like product name. Unknown devices are not seized.
    static func identify(vendorID: Int, productID: Int, productName: String) -> RemoteDeviceModel? {
        let name = productName.lowercased()
        if vendorID == xiaomiVID {
            guard !name.contains("keyboard") && !name.contains("mouse") &&
                  !name.contains("trackpad") else { return nil }
            if productID == remote2PID { return .xiaomiRemote2 }
            if productID == remote2ProCandidatePID { return .xiaomiRemote2Pro }
        }
        let remoteLike = name.contains("remote") || name.contains("chromecast") ||
            name.contains("g9n9n")
        if (vendorID == 0x18D1 && remoteLike) ||
            (name.contains("chromecast") || name.contains("google tv remote") ||
             name.contains("g9n9n")) &&
             !name.contains("keyboard") && !name.contains("mouse") {
            return .googleG9N9N
        }
        return nil
    }
}
