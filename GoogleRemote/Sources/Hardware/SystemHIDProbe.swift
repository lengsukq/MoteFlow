import Foundation
import IOKit.hid
import CoreGraphics

/// Apple's IOKit input monitoring decision. CGPreflightListenEventAccess()
/// is a secondary diagnostic signal, not the gate for IOHID enumeration.
enum InputMonitoringStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown(Int)

    var title: String {
        switch self {
        case .granted: "已授权"
        case .denied: "已拒绝"
        case .notDetermined: "尚未请求"
        case .unknown: "状态未知"
        }
    }

    var explanation: String {
        switch self {
        case .granted:
            "IOKit 输入监控权限已授权。可尝试枚举系统 HID，若打开仍失败需检查应用签名及其他系统保护。"
        case .denied:
            "系统已经拒绝当前 MoteFlow 的输入监控请求。请到「系统设置 → 隐私与安全性 → 输入监控」启用当前应用，然后完全退出重新打开。"
        case .notDetermined:
            "系统尚未登记输入监控决定。点击下方「申请权限」弹出系统请求；若未出现弹窗，可以在系统输入监控设置中手动添加。"
        case .unknown(let code):
            "IOKit 返回未知权限状态（\(code)），将尝试枚举并展示真实错误，不会假定未授权。"
        }
    }
}

struct HIDRemoteCandidate: Identifiable {
    let id: String
    let productName: String
    let vendorID: Int
    let productID: Int
    let transport: String

    /// Never seize arbitrary HID devices (especially the user's real keyboard/mouse).
    /// The target must have a Google vendor ID plus a remote-like name, or an
    /// unambiguous Chromecast / Google TV remote product name.
    var canSeize: Bool {
        let name = productName.lowercased()
        let unsafe = name.contains("keyboard") || name.contains("mouse") ||
            name.contains("trackpad") || name.contains("touchpad")
        return !unsafe && RemoteDeviceProfileRegistry.identify(
            vendorID: vendorID, productID: productID, productName: productName
        ) != nil
    }
}

struct HIDScanReport {
    let candidates: [HIDRemoteCandidate]
    let bluetoothDevices: [HIDRemoteCandidate]
    let totalCount: Int
    let error: String?

    var summary: String {
        if let error { return "系统 HID 枚举失败：\(error)" }
        return "macOS HID：总计 \(totalCount) 个 · 蓝牙设备 \(bluetoothDevices.count) 个 · 遥控器候选 \(candidates.count) 个"
    }
}

/// Passive enumeration only. macOS may expose paired remotes as HID devices
/// even when the BLE device no longer advertises for CoreBluetooth scanning.
enum SystemHIDProbe {
    /// Use the IOKit HID-specific TCC API, not a CoreGraphics preflight proxy.
    static var inputMonitoringStatus: InputMonitoringStatus {
        switch Int(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) {
        case 0: .granted
        case 1: .denied
        case 2: .notDetermined
        case let raw: .unknown(raw)
        }
    }

    static var inputMonitoringGranted: Bool {
        inputMonitoringStatus == .granted
    }

    static var cgPreflightGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// May show a system permission request. Call only after direct user action.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func deviceIdentifier(_ device: IOHIDDevice) -> String {
        let service = IOHIDDeviceGetService(device)
        var registryID: UInt64 = 0
        if service != 0,
           IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess {
            return String(format: "hid:%016llX", registryID)
        }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        return "fallback:\(vendor):\(product):\(name):\(transport)"
    }

    static func scanCandidates() -> [HIDRemoteCandidate] {
        scanDetailed().candidates
    }

    static func scanDetailed() -> HIDScanReport {
        let permission = inputMonitoringStatus
        if permission == .denied || permission == .notDetermined {
            return HIDScanReport(
                candidates: [], bluetoothDevices: [], totalCount: 0,
                error: permission.explanation
            )
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return HIDScanReport(candidates: [], bluetoothDevices: [], totalCount: 0,
                error: openStatus == kIOReturnNotPermitted
                    ? "IOKit 权限状态：\(permission.title)，但 IOHIDManagerOpen 被拒绝（0xE00002E2）；请检查应用签名/运行路径和系统授权"
                    : String(format: "IOHIDManagerOpen 0x%08X", UInt32(bitPattern: openStatus)))
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return HIDScanReport(candidates: [], bluetoothDevices: [], totalCount: 0,
                error: "IOHIDManagerCopyDevices 返回空对象")
        }
        let entries: [HIDRemoteCandidate] = devices.map { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知 HID 设备"
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "未知"
            return HIDRemoteCandidate(
                id: deviceIdentifier(device),
                productName: name,
                vendorID: vendor,
                productID: product,
                transport: transport
            )
        }
        let candidates = entries.filter(\.canSeize)
        let bluetooth = entries.filter { $0.transport.lowercased().contains("bluetooth") }
        return HIDScanReport(
            candidates: candidates.sorted { $0.productName.localizedStandardCompare($1.productName) == .orderedAscending },
            bluetoothDevices: bluetooth.sorted { $0.productName.localizedStandardCompare($1.productName) == .orderedAscending },
            totalCount: entries.count,
            error: nil
        )
    }
}
