import Combine
import Foundation
import IOKit.hid

enum HIDCaptureKind: String {
    case value = "VALUE"
    case report = "REPORT"
    case ble = "BLE"
    case atvv = "ATVV"
    case system = "SYSTEM"
}

enum RemoteHIDImportError: LocalizedError {
    case wrongConnectedDevice
    case unsupportedDevice

    var errorDescription: String? {
        switch self {
        case .wrongConnectedDevice:
            "导入的设备型号与当前已独占的遥控器不一致。请先连接对应型号，或断开当前遥控器后重新导入。"
        case .unsupportedDevice:
            "导入文件未标明可识别的遥控器型号，已拒绝。"
        }
    }
}

enum RemoteHIDExportError: LocalizedError {
    case noDevice
    var errorDescription: String? {
        "未记录可验证的遥控器型号，请先在本机成功独占一次实体 HID 设备再导出。"
    }
}

struct HIDCaptureEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: HIDCaptureKind
    let expectedKey: RemoteKey?
    let usagePage: Int?
    let usage: Int?
    let value: Int?
    let reportID: Int?
    let rawHex: String?
    let note: String

    var timestamp: String { date.formatted(date: .omitted, time: .standard) }
    var line: String {
        let tagged = expectedKey.map { " [标记:\($0.title)]" } ?? ""
        switch kind {
        case .value:
            return "[\(timestamp)] VALUE page=\(Self.hex(usagePage)) usage=\(Self.hex(usage)) value=\(value ?? 0) report=\(reportID ?? 0)\(tagged)"
        case .report:
            return "[\(timestamp)] REPORT id=\(reportID ?? 0) bytes=\(rawHex ?? "")\(tagged)"
        case .ble:
            return "[\(timestamp)] BLE HID \(note) bytes=\(rawHex ?? "")\(tagged) [非独占]"
        case .atvv:
            return "[\(timestamp)] ATVV CTL bytes=\(rawHex ?? "")\(tagged) [仅语音控制]"
        case .system:
            return "[\(timestamp)] SYSTEM \(note)"
        }
    }

    private static func hex(_ value: Int?) -> String {
        value.map { String(format: "0x%04X", $0) } ?? "—"
    }
}

/// Exclusive listener for ONE verified Google remote HID interface. Automatic
/// startup interception is user-configurable and does not seize normal keyboards.
@MainActor
final class HIDCaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isExclusive = false
    @Published private(set) var status = "尚未启动监听"
    @Published private(set) var remainingSeconds = 90
    @Published private(set) var events: [HIDCaptureEntry] = []
    @Published private(set) var sampledKeys: Set<RemoteKey> = []
    @Published var expectedKey: RemoteKey = .up
    @Published var learningKey: RemoteKey?
    @Published private(set) var learnedCodes: [RemoteKey: RemoteHIDButtonCode] = [:]
    @Published private(set) var userLearnedCodes: [RemoteKey: RemoteHIDButtonCode] = [:]
    @Published private(set) var factoryCodes: [RemoteKey: RemoteHIDButtonCode] = [:]
    @Published private(set) var currentDeviceIdentity: RemoteHIDDeviceIdentity?
    @Published private(set) var lastLearnedDeviceIdentity: RemoteHIDDeviceIdentity?
    @Published var advancedLearningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(advancedLearningEnabled, forKey: Self.advancedKey)
            if !advancedLearningEnabled { learningKey = nil }
        }
    }
    @Published private(set) var activePhysicalKey: RemoteKey?
    @Published private(set) var highlightedPhysicalKey: RemoteKey?
    @Published private(set) var lastHardwareFeedback = "等待实体遥控器按键"
    @Published private(set) var hardwareEventSequence = 0
    @Published private(set) var isAutomaticCapture = false
    @Published var autoSeizeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSeizeEnabled, forKey: Self.autoKey) }
    }
    @Published var executeHardwareActions: Bool {
        didSet { UserDefaults.standard.set(executeHardwareActions, forKey: Self.actionsKey) }
    }
    @Published var doubaoShortcutTrigger: DoubaoShortcutTrigger {
        didSet { UserDefaults.standard.set(doubaoShortcutTrigger.rawValue, forKey: Self.doubaoTriggerKey) }
    }
    var onMappedGesture: ((RemoteKey, RemoteGesture) -> Void)?
    /// ATVV mic requests have start/stop semantics, not HID key-up timing.
    var onVoiceSessionStart: (() -> Void)?
    var onVoiceSessionEnd: (() -> Void)?
    private var atvvVoiceActive = false
    var longPressThresholdForKey: ((RemoteKey) -> Double)?

    private var device: IOHIDDevice?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var timerTask: Task<Void, Never>?
    private let reportBufferSize = 512
    private let captureDuration = 90
    private var currentPress: (code: RemoteHIDButtonCode, started: Date)?
    private var xiaomiPresses: [RemoteKey: Date] = [:]
    private var flashTask: Task<Void, Never>?
    private var suppressNextRelease = false
    private static let autoKey = "GoogleRemote.autoSeizeOnLaunch.v1"
    private static let actionsKey = "GoogleRemote.executeHardwareActions.v1"
    private static let doubaoTriggerKey = "GoogleRemote.doubaoShortcutTrigger.v1"
    private static let learnedKey = "GoogleRemote.learnedHardwareCodes.v1"
    private static let deviceIdentityKey = "GoogleRemote.learnedDeviceIdentity.v1"
    private static let advancedKey = "GoogleRemote.advancedLearningEnabled.v1"
    private static let learnedDeviceKey = "GoogleRemote.learnedHardwareDevice.v1"
    private static let lastVendorKey = "GoogleRemote.lastVendorID.v1"
    private static let lastProductKey = "GoogleRemote.lastProductID.v1"
    private static let lastInterfaceKey = "GoogleRemote.lastHIDInterface.v1"
    private var lastAttempt: Date = .distantPast
    private var currentRemoteFingerprint: String?

    init() {
        // User explicitly requested automatic interception after matching the
        // physical Google remote. Action execution still requires a separate opt-in.
        autoSeizeEnabled = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        executeHardwareActions = UserDefaults.standard.bool(forKey: Self.actionsKey)
        doubaoShortcutTrigger = DoubaoShortcutTrigger(
            rawValue: UserDefaults.standard.string(forKey: Self.doubaoTriggerKey) ?? ""
        ) ?? .hold
        advancedLearningEnabled = UserDefaults.standard.bool(forKey: Self.advancedKey)
        if let data = UserDefaults.standard.data(forKey: Self.learnedKey),
           let restored = try? JSONDecoder().decode([RemoteKey: RemoteHIDButtonCode].self, from: data) {
            userLearnedCodes = restored
            // Do not claim these codes are usable until the actual opened HID
            // device matches the stored model.
        }
        if let data = UserDefaults.standard.data(forKey: Self.deviceIdentityKey) {
            lastLearnedDeviceIdentity = try? JSONDecoder().decode(RemoteHIDDeviceIdentity.self, from: data)
        }
    }

    var eventCount: Int { events.filter { $0.kind != .system }.count }
    var latest: HIDCaptureEntry? { events.last(where: { $0.kind != .system }) }

    /// Safe, bounded periodic discovery. On startup/reconnect, only seize when
    /// an unambiguous verified Google remote HID candidate exists.
    func tryAutomaticCapture() {
        guard autoSeizeEnabled, !isCapturing,
              Date().timeIntervalSince(lastAttempt) >= 4 else { return }
        lastAttempt = Date()
        let scan = SystemHIDProbe.scanDetailed()
        guard scan.error == nil else {
            status = scan.error ?? "等待 HID 授权"
            return
        }
        let eligible = scan.candidates.filter(\.canSeize)
        let lastInterface = UserDefaults.standard.string(forKey: Self.lastInterfaceKey)
        let exact = eligible.filter { $0.id == lastInterface }
        let preferredVendor = UserDefaults.standard.object(forKey: Self.lastVendorKey) as? Int
        let preferredProduct = UserDefaults.standard.object(forKey: Self.lastProductKey) as? Int
        let preferred = eligible.filter { $0.vendorID == preferredVendor && $0.productID == preferredProduct }
        let selected: HIDRemoteCandidate?
        if exact.count == 1 {
            selected = exact.first
        } else if preferred.count == 1 {
            selected = preferred.first
        } else if eligible.count == 1 {
            selected = eligible.first
        } else {
            selected = nil
        }
        guard let selected else {
            status = eligible.isEmpty ? "等待已配对的遥控器 HID 接口" : "存在多个遥控器接口，请在诊断中指定设备"
            return
        }
        startSeizedCapture(of: selected, persistent: true)
    }

    func disableAutomaticCapture() {
        autoSeizeEnabled = false
        stop(reason: "用户暂停自动拦截；HID 已释放")
    }

    func enableAutomaticCapture() {
        autoSeizeEnabled = true
        lastAttempt = .distantPast
        tryAutomaticCapture()
    }

    func forgetLearnedKey(_ key: RemoteKey) {
        guard advancedLearningEnabled else { return }
        userLearnedCodes.removeValue(forKey: key)
        persistLearnedCodes()
        updateEffectiveCodes()
    }

    private func persistLearnedCodes() {
        guard let data = try? JSONEncoder().encode(userLearnedCodes) else { return }
        UserDefaults.standard.set(data, forKey: Self.learnedKey)
        if let currentRemoteFingerprint {
            UserDefaults.standard.set(currentRemoteFingerprint, forKey: Self.learnedDeviceKey)
        }
        if let currentDeviceIdentity,
           let data = try? JSONEncoder().encode(currentDeviceIdentity) {
            lastLearnedDeviceIdentity = currentDeviceIdentity
            UserDefaults.standard.set(data, forKey: Self.deviceIdentityKey)
        }
    }

    private func updateEffectiveCodes() {
        let overrides = overridesMatchCurrentDevice() ? userLearnedCodes : [:]
        learnedCodes = RemoteHIDProfileResolver.merged(defaults: factoryCodes, overrides: overrides)
        sampledKeys = Set(learnedCodes.keys)
    }

    private func overridesMatchCurrentDevice() -> Bool {
        guard let currentDeviceIdentity else { return false }
        if let lastLearnedDeviceIdentity {
            return lastLearnedDeviceIdentity.matches(currentDeviceIdentity)
        }
        return currentRemoteFingerprint != nil &&
            UserDefaults.standard.string(forKey: Self.learnedDeviceKey) == currentRemoteFingerprint
    }

    var exportableLearnedCount: Int { userLearnedCodes.count }

    func exportLearnedProfileData() throws -> Data {
        guard let device = currentDeviceIdentity ?? lastLearnedDeviceIdentity else {
            throw RemoteHIDExportError.noDevice
        }
        // The export contains only independently sampled user mappings,
        // never unverified factory placeholders or remembered UI labels.
        let profile = RemoteHIDProfile(device: device, codes: userLearnedCodes)
        return try profile.exportData()
    }

    /// Restore a JSON backup without ever importing executable actions or
    /// granting access to another HID device. A profile is only used when
    /// its exact model matches the actual device opened by IOKit.
    func importUserProfileData(_ data: Data) throws {
        let profile = try RemoteHIDProfile.importData(data)
        let device = profile.device
        guard RemoteDeviceProfileRegistry.identify(
            vendorID: device.vendorID, productID: device.productID,
            productName: device.productName
        ) != nil else {
            throw RemoteHIDImportError.unsupportedDevice
        }
        if let currentDeviceIdentity, !device.matches(currentDeviceIdentity) {
            throw RemoteHIDImportError.wrongConnectedDevice
        }
        userLearnedCodes = try profile.validatedCodes()
        let fingerprint = "\(device.vendorID):\(device.productID):\(device.productName)"
        UserDefaults.standard.set(fingerprint, forKey: Self.learnedDeviceKey)
        lastLearnedDeviceIdentity = device
        UserDefaults.standard.set(try JSONEncoder().encode(device), forKey: Self.deviceIdentityKey)
        persistLearnedCodes()
        updateEffectiveCodes()
    }

    func clearUserOverrides() {
        guard advancedLearningEnabled else { return }
        userLearnedCodes.removeAll()
        persistLearnedCodes()
        updateEffectiveCodes()
    }

    func startSeizedCapture(of candidate: HIDRemoteCandidate, persistent: Bool = false) {
        guard !isCapturing else { return }
        guard SystemHIDProbe.inputMonitoringGranted else {
            status = "macOS「输入监控」权限未授权；不能打开 HID 接口"
            appendSystem(status)
            return
        }
        guard candidate.canSeize else {
            status = "为保护 Mac 键盘和鼠标，未能确认这是支持的遥控器；拒绝独占。"
            appendSystem(status)
            return
        }

        let enumerator = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(enumerator, nil)
        let enumResult = IOHIDManagerOpen(enumerator, IOOptionBits(kIOHIDOptionsTypeNone))
        guard enumResult == kIOReturnSuccess else {
            status = "HID 枚举失败：\(Self.errorCode(enumResult))"
            appendSystem(status)
            return
        }
        let allDevices = IOHIDManagerCopyDevices(enumerator) as? Set<IOHIDDevice> ?? []
        let matches = allDevices.filter { SystemHIDProbe.deviceIdentifier($0) == candidate.id }
        IOHIDManagerClose(enumerator, IOOptionBits(kIOHIDOptionsTypeNone))

        guard matches.count == 1, let selectedDevice = matches.first else {
            status = matches.isEmpty ? "设备已离线，请重新扫描" : "同一设备标识匹配了多个接口，已拒绝独占"
            appendSystem(status)
            return
        }

        // Check again immediately before opening; do not trust a stale UI selection.
        let name = IOHIDDeviceGetProperty(selectedDevice, kIOHIDProductKey as CFString) as? String ?? ""
        let vendor = (IOHIDDeviceGetProperty(selectedDevice, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let product = (IOHIDDeviceGetProperty(selectedDevice, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let transport = IOHIDDeviceGetProperty(selectedDevice, kIOHIDTransportKey as CFString) as? String ?? ""
        let current = HIDRemoteCandidate(id: candidate.id, productName: name, vendorID: vendor, productID: product, transport: transport)
        guard current.canSeize, candidate.vendorID == vendor, candidate.productID == product,
              candidate.productName == name else {
            status = "设备信息已改变或不是安全的遥控器型号，拒绝独占"
            appendSystem(status)
            return
        }

        let result = IOHIDDeviceOpen(selectedDevice, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            // Never silently fall back to passive monitoring: the user's first
            // requirement is that remote keypresses do not reach macOS.
            status = "独占失败 \(Self.errorCode(result))；未开始监听，系统仍可能响应按键"
            appendSystem(status)
            return
        }

        let reportMemory = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        reportMemory.initialize(repeating: 0, count: reportBufferSize)
        buffer = reportMemory
        device = selectedDevice
        currentRemoteFingerprint = "\(vendor):\(product):\(name)"
        currentDeviceIdentity = RemoteHIDDeviceIdentity(
            vendorID: vendor, productID: product, productName: name, transport: transport
        )
        if let currentDeviceIdentity {
            factoryCodes = RemoteHIDDefaultProfiles.verifiedCodes(for: currentDeviceIdentity)
        } else {
            factoryCodes = [:]
        }
        updateEffectiveCodes()
        if !userLearnedCodes.isEmpty, !overridesMatchCurrentDevice() {
            lastHardwareFeedback = "当前设备与自定义映射的型号不符；已仅使用匹配的内置映射"
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(selectedDevice, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<HIDCaptureManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.recordValue(value) }
        }, context)

        IOHIDDeviceRegisterInputReportCallback(
            selectedDevice, reportMemory, reportBufferSize,
            { context, result, _, _, reportID, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                let owner = Unmanaged<HIDCaptureManager>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.recordReport(reportID: Int(reportID), report: report, length: Int(reportLength)) }
            }, context
        )

        IOHIDDeviceRegisterRemovalCallback(selectedDevice, { context, _, _ in
            guard let context else { return }
            let owner = Unmanaged<HIDCaptureManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.stop(reason: "遥控器已断开，自动释放独占") }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selectedDevice, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        remainingSeconds = captureDuration
        isAutomaticCapture = persistent
        isExclusive = true
        isCapturing = true
        status = persistent ? "\(name) 自动独占中 · 可在诊断或菜单栏停止" : "临时独占中 · 90 秒后自动释放"
        appendSystem("独占成功：\(name) VID=\(String(format: "%04X", vendor)) PID=\(String(format: "%04X", product))；仅选定接口")
        UserDefaults.standard.set(vendor, forKey: Self.lastVendorKey)
        UserDefaults.standard.set(product, forKey: Self.lastProductKey)
        UserDefaults.standard.set(candidate.id, forKey: Self.lastInterfaceKey)

        timerTask?.cancel()
        if !persistent { timerTask = Task { [weak self] in
            for _ in 0..<captureDuration {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isCapturing else { return }
                self.remainingSeconds -= 1
            }
            self?.stop(reason: "90 秒时间到，已自动释放 HID 独占")
        }}
        else { remainingSeconds = 0 }
    }

    func stop(reason: String = "用户结束监听，HID 独占已释放") {
        timerTask?.cancel()
        timerTask = nil
        var releaseFailure: String?
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let code = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if code != kIOReturnSuccess {
                releaseFailure = "HID 关闭返回 \(Self.errorCode(code))。建议退出 MoteFlow，让 macOS 回收设备句柄。"
            }
        }
        device = nil
        currentRemoteFingerprint = nil
        currentDeviceIdentity = nil
        currentPress = nil
        xiaomiPresses.removeAll()
        activePhysicalKey = nil
        highlightedPhysicalKey = nil
        flashTask?.cancel()
        flashTask = nil
        learningKey = nil
        isAutomaticCapture = false
        if let buffer {
            buffer.deinitialize(count: reportBufferSize)
            buffer.deallocate()
        }
        buffer = nil
        guard isCapturing else { return }
        isCapturing = false
        isExclusive = false
        remainingSeconds = 0
        status = releaseFailure ?? reason
        appendSystem(status)
    }

    func clearLogs() {
        events.removeAll()
        // Clearing logs must not silently erase the durable learned mappings.
    }

    func exportText() -> String {
        events.map(\.line).joined(separator: "\n")
    }

    func recordBLEReport(characteristic: String, data: Data) {
        let hex = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
        append(HIDCaptureEntry(
            kind: .ble, expectedKey: expectedKey, usagePage: nil, usage: nil, value: nil,
            reportID: nil, rawHex: hex, note: "char=\(characteristic)"
        ))
        // BLE diagnostics must not falsely mark a button as physically
        // learned: only an explicit HID learning session can do that.
    }

    func recordATVVControl(_ data: Data) {
        let bytes = [UInt8](data)
        guard let opcode = bytes.first else { return }
        // Ignore capability negotiation and stream maintenance, keep only
        // speech button start/stop and audio lifecycle diagnostics.
        guard [0x00, 0x04, 0x08, 0x0A].contains(opcode) else { return }
        let hex = bytes.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        append(HIDCaptureEntry(
            kind: .atvv, expectedKey: expectedKey, usagePage: nil, usage: nil, value: nil,
            reportID: nil, rawHex: hex, note: "语音控制信号"
        ))
        // ATVV 0x08 requests a microphone session; it is not necessarily a
        // physical key-up/down pair. The session ends only on ATVV mic-close,
        // audio completion or disconnect, NOT after a fixed amount of time.
        if opcode == 0x08 {
            if learningKey == .assistant {
                learningKey = nil
            }
            hardwareEventSequence += 1
            lastHardwareFeedback = "实体语音助手 · ATVV 麦克风请求已收到（非 HID 按键）"
            flashPhysicalKey(.assistant)
            if !atvvVoiceActive {
                atvvVoiceActive = true
                if executeHardwareActions { onVoiceSessionStart?() }
            }
        } else if opcode == 0x00 {
            endATVVVoiceSession()
        }
    }

    func endATVVVoiceSession() {
        guard atvvVoiceActive else { return }
        atvvVoiceActive = false
        onVoiceSessionEnd?()
    }

    private func recordValue(_ value: IOHIDValue) {
        guard isCapturing else { return }
        let element = IOHIDValueGetElement(value)
        let numericValue = Int(IOHIDValueGetIntegerValue(value))
        append(HIDCaptureEntry(
            kind: .value, expectedKey: expectedKey,
            usagePage: Int(IOHIDElementGetUsagePage(element)),
            usage: Int(IOHIDElementGetUsage(element)),
            value: numericValue,
            reportID: Int(IOHIDElementGetReportID(element)),
            rawHex: nil, note: ""
        ))
        // Xiaomi RC001/RC003 may publish standard key/consumer usage values.
        // This path is isolated from Google's verified 2-byte report decoder.
        if let identity = currentDeviceIdentity,
           let model = RemoteDeviceProfileRegistry.identify(
                vendorID: identity.vendorID,
                productID: identity.productID,
                productName: identity.productName
           ), model == .xiaomiRemote2 || model == .xiaomiRemote2Pro,
           let key = XiaomiHIDUsageMapper.key(
                usagePage: Int(IOHIDElementGetUsagePage(element)),
                usage: Int(IOHIDElementGetUsage(element))
           ) {
            processXiaomiUsage(key: key, value: numericValue)
        }
    }

    private func processXiaomiUsage(key: RemoteKey, value: Int) {
        guard value == 0 || value == 1 else { return }
        if value == 1 {
            guard xiaomiPresses[key] == nil else { return }
            xiaomiPresses[key] = Date()
            hardwareEventSequence += 1
            lastHardwareFeedback = "小米遥控器实体按下「\(key.title)」· HID Usage"
            activePhysicalKey = key
            if learningKey == key { learningKey = nil }
            if key == .assistant && !atvvVoiceActive {
                // Some Xiaomi firmware reports microphone as F5 HID, others
                // also send an ATVV mic-start. Share a single session gate.
                atvvVoiceActive = true
                if executeHardwareActions { onVoiceSessionStart?() }
            }
            return
        }
        guard let pressed = xiaomiPresses.removeValue(forKey: key) else { return }
        activePhysicalKey = nil
        let duration = Date().timeIntervalSince(pressed)
        let gesture = RemotePressClassifier.gesture(
            duration: duration, threshold: longPressThresholdForKey?(key) ?? 0.65
        )
        hardwareEventSequence += 1
        lastHardwareFeedback = "小米实体「\(key.title)」· \(gesture.title) · \(String(format: "%.2f", duration)) 秒"
        flashPhysicalKey(key)
        if key == .assistant {
            endATVVVoiceSession()
            return
        }
        if learningKey == nil && executeHardwareActions {
            onMappedGesture?(key, gesture)
        }
    }

    private func recordReport(reportID: Int, report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard isCapturing else { return }
        let count = max(0, min(length, reportBufferSize))
        let preview = min(count, 64)
        let hex = (0..<preview)
            .map { String(format: "%02X", report[$0]) }
            .joined(separator: " ")
        append(HIDCaptureEntry(
            kind: .report, expectedKey: expectedKey, usagePage: nil, usage: nil,
            value: nil, reportID: reportID,
            rawHex: hex + (count > preview ? " ... (\(count) bytes)" : ""),
            note: ""
        ))
        guard let identity = currentDeviceIdentity,
              RemoteDeviceProfileRegistry.identify(
                vendorID: identity.vendorID,
                productID: identity.productID,
                productName: identity.productName
              ) == .googleG9N9N else { return }
        if let signal = RemoteHIDReportDecoder.decode(reportID: reportID,
                                                      bytes: Array(UnsafeBufferPointer(start: report, count: count))) {
            processSignal(signal)
        }
    }

    private func processSignal(_ signal: RemoteHIDButtonCode) {
        let matchesLearnedDevice = currentDeviceIdentity != nil
        if signal.code == 0 {
            guard let currentPress, currentPress.code.reportID == signal.reportID else { return }
            self.currentPress = nil
            let elapsed = Date().timeIntervalSince(currentPress.started)
            let pressedKey = matchesLearnedDevice
                ? learnedCodes.first { $0.value == currentPress.code }?.key : nil
            activePhysicalKey = nil
            guard let pressedKey else { return }
            let threshold = longPressThresholdForKey?(pressedKey) ?? 0.65
            let gesture = RemotePressClassifier.gesture(duration: elapsed, threshold: threshold)
            hardwareEventSequence += 1
            lastHardwareFeedback = "实体\(pressedKey.title) · \(gesture.title) · \(String(format: "%.2f", elapsed)) 秒"
            flashPhysicalKey(pressedKey)
            if suppressNextRelease {
                suppressNextRelease = false
            } else if learningKey == nil && executeHardwareActions {
                onMappedGesture?(pressedKey, gesture)
            }
            return
        }
        // Ignore held-key auto repeats; send at most one action when released.
        if currentPress?.code == signal { return }
        currentPress = (signal, Date())
        hardwareEventSequence += 1

        if let learningKey, advancedLearningEnabled {
            if !overridesMatchCurrentDevice() && !userLearnedCodes.isEmpty {
                userLearnedCodes.removeAll()
            }
            if let previous = learnedCodes.first(where: { $0.value == signal && $0.key != learningKey }) {
                lastHardwareFeedback = "原始码 \(signal.code) 已分配给「\(previous.key.title)」，请检查采样"
                return
            }
            userLearnedCodes[learningKey] = signal
            expectedKey = learningKey
            persistLearnedCodes()
            updateEffectiveCodes()
            lastHardwareFeedback = "学习成功：「\(learningKey.title)」= report \(signal.reportID) / code \(signal.code)"
            activePhysicalKey = learningKey
            highlightedPhysicalKey = learningKey
            suppressNextRelease = true
            self.learningKey = nil
            return
        }
        if matchesLearnedDevice, let key = learnedCodes.first(where: { $0.value == signal })?.key {
            activePhysicalKey = key
            highlightedPhysicalKey = key
            flashTask?.cancel()
            lastHardwareFeedback = "实体按下「\(key.title)」· 原始码 \(signal.code)"
        } else {
            activePhysicalKey = nil
            lastHardwareFeedback = "收到未学习硬件码 \(signal.code)（Report \(signal.reportID)）"
        }
    }

    private func flashPhysicalKey(_ key: RemoteKey) {
        flashTask?.cancel()
        highlightedPhysicalKey = key
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.highlightedPhysicalKey = nil
        }
    }

    private func appendSystem(_ message: String) {
        append(HIDCaptureEntry(
            kind: .system, expectedKey: nil, usagePage: nil,
            usage: nil, value: nil, reportID: nil,
            rawHex: nil, note: message
        ))
    }

    private func append(_ entry: HIDCaptureEntry) {
        events.append(entry)
        if events.count > 360 { events.removeFirst(events.count - 360) }
    }

    private static func errorCode(_ code: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}
