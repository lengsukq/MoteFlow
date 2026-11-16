import Combine
import CoreBluetooth
import Foundation

struct RemoteDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Focused ATVV voice Bluetooth manager (GATT discovery, ADPCM stream decoding,
/// and virtual microphone PCM delivery). Ordinary buttons are handled by IOKit HID.
@MainActor
final class RemoteBluetoothManager: NSObject, ObservableObject {
    let virtualMicrophone = RemoteVirtualMicrophoneRouter()
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var bluetoothState = "初始化中"
    @Published private(set) var isBluetoothReady = false
    @Published private(set) var isScanning = false
    @Published private(set) var connectedDeviceID: UUID?
    @Published private(set) var connectionSummary = "未连接"
    @Published private(set) var discoveredServices: [String] = []
    @Published private(set) var logs: [String] = []
    @Published private(set) var atvvFound = false
    @Published private(set) var voiceModeEnabled = false
    @Published private(set) var audioChannelActive = false
    @Published private(set) var voiceStatus = "等待连接 ATVV 遥控器"
    @Published private(set) var protocolDetails = "尚未协商"
    @Published private(set) var isRecording = false
    @Published private(set) var audioPacketCount = 0
    @Published private(set) var decodedFrameCount = 0
    @Published private(set) var audioByteCount = 0
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var recordedSampleCount = 0
    @Published private(set) var droppedFrameCount = 0
    @Published var autoVoiceConnectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoVoiceConnectEnabled, forKey: Self.autoVoiceKey)
            if autoVoiceConnectEnabled {
                if canEnableVoiceMode && !voiceModeEnabled { toggleVoiceMode() }
                else { restoreVoicePeripheralIfPossible() }
            }
            else if voiceModeEnabled { stopVoiceMode() }
        }
    }
    private static let lastVoiceDeviceKey = "GoogleRemote.lastATVVPeripheral.v1"
    private static let autoVoiceKey = "GoogleRemote.autoATVVOnLaunch.v1"
    private var manuallyDisconnected = false

    var onATVVControlReport: ((Data) -> Void)?
    var onATVVAudioEnded: (() -> Void)?
    var shouldRouteVoiceRemotely: (() -> Bool)?
    var onRemoteVoiceAudioStart: ((Int) -> Void)?
    var onRemoteVoiceSamples: (([Int16], Int) -> Void)?

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var atvvTX: CBCharacteristic?
    private var atvvAudio: CBCharacteristic?
    private var atvvCTL: CBCharacteristic?
    private var negotiationRequested = false
    private var pendingStartBeforeCaps = false
    private var pendingStartTimeout: Task<Void, Never>?
    private var microphoneOpenPending = false
    private var microphoneOpenTimeout: Task<Void, Never>?
    private var audioSilenceWatchdog: Task<Void, Never>?
    private var lastVoicePacketAt: Date?
    private var capabilities: ATVVCapabilities?
    private var pendingAudio = ATVVLegacyAssembler()
    private var v1Decoder = ATVVV1StreamDecoder()
    private var recordedSamples: [Int16] = []
    private var recordingRate = 8_000
    private var unsupportedVersionLogged = false
    private var keepaliveTask: Task<Void, Never>?
    private var packetTotal = 0
    private var byteTotal = 0
    private var frameTotal = 0
    private var levelLatest = 0.0
    private var lastMetricsUpdate = Date.distantPast

    override init() {
        autoVoiceConnectEnabled = UserDefaults.standard.object(forKey: Self.autoVoiceKey) as? Bool ?? true
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var preferredVoiceSampleRate: Int {
        capabilities?.supports8k == true ? 8_000 : 16_000
    }

    private func restoreVoicePeripheralIfPossible() {
        guard autoVoiceConnectEnabled, central.state == .poweredOn,
              connectedDeviceID == nil else { return }
        if let text = UserDefaults.standard.string(forKey: Self.lastVoiceDeviceKey),
           let id = UUID(uuidString: text),
           let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            register(peripheral, name: peripheral.name ?? "Chromecast Remote", rssi: 0)
            connect(to: id)
            return
        }
        let systemConnected = central.retrieveConnectedPeripherals(withServices: [ATVV.service])
        if let first = systemConnected.first {
            register(first, name: first.name ?? "Chromecast Remote", rssi: 0)
            connect(to: first.identifier)
        }
    }

    func toggleScan() {
        guard central.state == .poweredOn else { log("蓝牙不可用"); return }
        if isScanning {
            central.stopScan()
            isScanning = false
            log("停止扫描")
        } else {
            devices.removeAll()
            let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [ATVV.service])
            for peripheral in alreadyConnected { register(peripheral, name: peripheral.name ?? "已连接的 ATVV 设备", rssi: 0) }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            isScanning = true
            log("开始 BLE 扫描；如无结果，请按键唤醒遥控器")
        }
    }

    func connect(to id: UUID) {
        guard let peripheral = discovered[id] else { log("设备不在发现列表中"); return }
        manuallyDisconnected = false
        if let previous = active, previous.identifier != id {
            stopVoiceMode()
            central.cancelPeripheralConnection(previous)
        }
        resetATVV()
        active = peripheral
        peripheral.delegate = self
        discoveredServices.removeAll()
        connectionSummary = "连接中：\(peripheral.name ?? id.uuidString)"
        if isScanning { central.stopScan(); isScanning = false }
        central.connect(peripheral, options: nil)
        log("尝试连接 \(id)")
    }

    func disconnect() {
        manuallyDisconnected = true
        stopVoiceMode()
        if let active { central.cancelPeripheralConnection(active) }
    }

    func clearLogs() { logs.removeAll() }

    var canEnableVoiceMode: Bool {
        connectedDeviceID != nil && atvvTX != nil && atvvAudio != nil && atvvCTL != nil
    }

    var canSaveWave: Bool { recordedSampleCount > 0 }

    func waveFileData() -> Data? {
        guard !recordedSamples.isEmpty else { return nil }
        return WaveFile.pcm16(samples: recordedSamples, rate: recordingRate)
    }

    // MARK: - Incoming LAN Forwarded Voice Metrics & WAV Buffer

    func beginRemoteIncomingVoice(sampleRate: Int, peerName: String?) {
        recordedSamples.removeAll(keepingCapacity: true)
        packetTotal = 0
        byteTotal = 0
        frameTotal = 0
        levelLatest = 0
        lastMetricsUpdate = .distantPast
        recordedSampleCount = 0
        audioPacketCount = 0
        audioByteCount = 0
        decodedFrameCount = 0
        droppedFrameCount = 0
        recordingRate = (sampleRate == 8_000 || sampleRate == 16_000) ? sampleRate : 8_000
        isRecording = true
        voiceStatus = "正在接收来自「\(peerName ?? "主控 Mac")」的遥控器语音"
    }

    func appendRemoteIncomingVoice(samples: [Int16], sampleRate: Int) {
        guard !samples.isEmpty else { return }
        if (sampleRate == 8_000 || sampleRate == 16_000), sampleRate != recordingRate {
            if recordedSamples.isEmpty {
                recordingRate = sampleRate
            }
        }
        packetTotal += 1
        frameTotal += 1
        byteTotal += samples.count * 2
        let remaining = recordingRate * 60 - recordedSamples.count
        if remaining > 0 {
            recordedSamples.append(contentsOf: samples.prefix(remaining))
        }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        levelLatest = min(1, sqrt(energy / Double(samples.count)) / 10_000)
        publishAudioMetrics()
    }

    func endRemoteIncomingVoice() {
        isRecording = false
        publishAudioMetrics(force: true)
        audioLevel = 0
        voiceStatus = voiceModeEnabled ? "语音按键待机 · 音频采集已关闭" : "远端语音接收已完成"
    }

    func toggleVoiceMode() {
        if voiceModeEnabled { stopVoiceMode(); return }
        guard canEnableVoiceMode, let active, let atvvCTL else {
            log("ATVV 音频特征未齐全，无法启用语音")
            return
        }
        voiceModeEnabled = true
        voiceStatus = "语音按键待机 · 音频采集已关闭"
        negotiationRequested = false
        pendingStartBeforeCaps = false
        pendingStartTimeout?.cancel()
        pendingStartTimeout = nil
        microphoneOpenPending = false
        audioChannelActive = false
        capabilities = nil
        protocolDetails = "等待能力协商"
        if let atvvAudio {
            active.setNotifyValue(true, for: atvvAudio)
        }
        active.setNotifyValue(true, for: atvvCTL)
        log("ATVV 就绪：被动订阅 Audio / Control；麦克风实际采集已关闭")
    }

    func stopVoiceMode() {
        if voiceModeEnabled, (isRecording || microphoneOpenPending || audioChannelActive) {
            let close = capabilities?.isLegacy == false ? ATVV.micCloseV1 : ATVV.micClose
            sendATVV(close, title: "MIC_CLOSE")
        }
        finishAudio(reason: "语音模式已关闭", restoreInputImmediately: true)
        voiceModeEnabled = false
        negotiationRequested = false
        pendingStartBeforeCaps = false
        pendingStartTimeout?.cancel()
        pendingStartTimeout = nil
        microphoneOpenPending = false
        audioChannelActive = false
        if let active {
            if let atvvAudio, atvvAudio.isNotifying { active.setNotifyValue(false, for: atvvAudio) }
            if let atvvCTL, atvvCTL.isNotifying { active.setNotifyValue(false, for: atvvCTL) }
        }
        voiceStatus = atvvFound ? "语音按键监听已关闭 · 音频采集已释放" : "未发现 ATVV 服务"
    }

    func stopCurrentVoiceSession() {
        guard isRecording || microphoneOpenPending || audioChannelActive ||
              pendingStartBeforeCaps else {
            virtualMicrophone.endSession()
            virtualMicrophone.scheduleVoiceInputRestoration()
            return
        }
        if voiceModeEnabled {
            sendATVV(capabilities?.isLegacy == false ? ATVV.micCloseV1 : ATVV.micClose,
                     title: "MIC_CLOSE (physical key release)")
        }
        finishAudio(reason: "遥控器语音键已释放")
    }

    private func register(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        discovered[peripheral.identifier] = peripheral
        let item = RemoteDevice(id: peripheral.identifier, name: name, rssi: rssi)
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
            log("发现：\(name) (RSSI \(rssi))")
        }
    }

    private func resetATVV() {
        finishAudio(reason: "音频会话重置", restoreInputImmediately: true)
        atvvFound = false
        voiceModeEnabled = false
        pendingStartBeforeCaps = false
        pendingStartTimeout?.cancel()
        pendingStartTimeout = nil
        microphoneOpenPending = false
        audioChannelActive = false
        atvvTX = nil
        atvvAudio = nil
        atvvCTL = nil
        negotiationRequested = false
        capabilities = nil
        voiceStatus = "等待 ATVV 服务发现"
        protocolDetails = "尚未协商"
        unsupportedVersionLogged = false
    }

    private func negotiateIfReady() {
        guard voiceModeEnabled, !negotiationRequested,
              ATVVTransportPolicy.canNegotiate(
                audioSubscribed: atvvAudio?.isNotifying == true,
                controlSubscribed: atvvCTL?.isNotifying == true
              ) else { return }
        negotiationRequested = true
        voiceStatus = "正在协商语音协议"
        sendATVV(ATVV.getCapabilities, title: "GET_CAPS")
    }

    private func sendATVV(_ data: Data, title: String) {
        guard let active, let atvvTX else { log("\(title) 未发送：没有命令特征"); return }
        if atvvTX.properties.contains(.writeWithoutResponse) {
            guard active.canSendWriteWithoutResponse else {
                log("\(title) 未发送：BLE 写缓冲暂不可用")
                return
            }
            active.writeValue(data, for: atvvTX, type: .withoutResponse)
        } else if atvvTX.properties.contains(.write) {
            active.writeValue(data, for: atvvTX, type: .withResponse)
        } else {
            log("\(title) 未发送：特征不支持写入")
            return
        }
        log("TX \(title): \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
    }

    private func beginAudio(codec: UInt8?) {
        guard voiceModeEnabled else { return }
        if isRecording { finishAudio(reason: "重新开始录音", notifySessionEnd: false,
                                     releaseAudioChannel: false) }
        pendingStartTimeout?.cancel()
        pendingStartTimeout = nil
        pendingStartBeforeCaps = false
        microphoneOpenTimeout?.cancel()
        microphoneOpenTimeout = nil
        microphoneOpenPending = false
        audioChannelActive = true
        isRecording = true
        lastVoicePacketAt = Date()
        audioSilenceWatchdog?.cancel()
        audioSilenceWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                if let last = self.lastVoicePacketAt, Date().timeIntervalSince(last) >= 12 {
                    self.log("音频超过 12 秒未送达，关闭失联会话以防占用麦克风")
                    self.stopCurrentVoiceSession()
                    return
                }
            }
        }
        recordedSamples.removeAll(keepingCapacity: true)
        packetTotal = 0
        byteTotal = 0
        frameTotal = 0
        levelLatest = 0
        lastMetricsUpdate = .distantPast
        recordedSampleCount = 0
        pendingAudio.reset()
        v1Decoder.reset()
        audioPacketCount = 0
        audioByteCount = 0
        decodedFrameCount = 0
        droppedFrameCount = 0
        audioLevel = 0
        recordingRate = codec == 0x02 ? 16_000 : 8_000
        if shouldRouteVoiceRemotely?() == true {
            onRemoteVoiceAudioStart?(recordingRate)
        } else {
            virtualMicrophone.beginSession(sourceRate: recordingRate)
        }
        voiceStatus = shouldRouteVoiceRemotely?() == true ? "正在接收语音并转发至远端 Mac" : "正在接收遥控器语音"
        log("AUDIO_START codec=\(codec.map { "0x" + String($0, radix: 16) } ?? "unknown")")
        keepaliveTask?.cancel()
        if capabilities?.isLegacy == false {
            keepaliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, !Task.isCancelled, self.isRecording, self.voiceModeEnabled else { break }
                    self.sendATVV(ATVV.extendMicrophone(), title: "MIC_EXTEND")
                }
            }
        }
    }

    private func finishAudio(reason: String, notifySessionEnd: Bool = true,
                             releaseAudioChannel: Bool = true,
                             restoreInputImmediately: Bool = false) {
        virtualMicrophone.endSession()
        if releaseAudioChannel {
            if restoreInputImmediately {
                virtualMicrophone.finishVoiceInputWindow()
            } else {
                virtualMicrophone.scheduleVoiceInputRestoration()
            }
        }
        audioSilenceWatchdog?.cancel()
        audioSilenceWatchdog = nil
        lastVoicePacketAt = nil
        if isRecording { log("\(reason)：共 \(packetTotal) 包 / \(frameTotal) 解码块") }
        isRecording = false
        publishAudioMetrics(force: true)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        audioLevel = 0
        if releaseAudioChannel {
            pendingStartTimeout?.cancel()
            pendingStartTimeout = nil
            pendingStartBeforeCaps = false
            microphoneOpenTimeout?.cancel()
            microphoneOpenTimeout = nil
            microphoneOpenPending = false
            audioChannelActive = false
        }
        if voiceModeEnabled {
            voiceStatus = releaseAudioChannel
                ? "语音按键待机 · 音频采集已关闭"
                : "正在重新同步遥控器语音"
        }
        pendingAudio.reset()
        if notifySessionEnd { onATVVAudioEnded?() }
    }

    private func openMicrophoneOnDemand() {
        guard voiceModeEnabled, !isRecording, !microphoneOpenPending,
              let capabilities,
              capabilities.supports8k || capabilities.supports16k else { return }
        microphoneOpenPending = true
        audioChannelActive = true
        voiceStatus = "语音键已按下 · 等待遥控器 AUDIO_START"
        log("ATVV：START_SEARCH → MIC_OPEN → AUDIO_START")
        sendATVV(ATVV.micOpen(codec: capabilities.supports8k ? 0x0001 : 0x0002),
                 title: "MIC_OPEN")
        microphoneOpenTimeout?.cancel()
        microphoneOpenTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) }
            catch { return }
            guard let self, !Task.isCancelled, self.microphoneOpenPending,
                  !self.isRecording else { return }
            self.log("12 秒内未收到 AUDIO_START；远端未开启音频，释放本次请求")
            self.sendATVV(self.capabilities?.isLegacy == false ? ATVV.micCloseV1 : ATVV.micClose,
                          title: "MIC_CLOSE (start failed)")
            self.finishAudio(reason: "未收到 AUDIO_START")
        }
    }

    private func completePendingMicrophoneOpen() {
        guard microphoneOpenPending, voiceModeEnabled, let atvvAudio,
              atvvAudio.isNotifying, let capabilities else { return }
        microphoneOpenPending = false
        sendATVV(ATVV.micOpen(codec: capabilities.supports8k ? 0x0001 : 0x0002),
                 title: "MIC_OPEN (on demand)")
    }

    private func waitForCapabilitiesAfterPress() {
        guard !pendingStartBeforeCaps else { return }
        pendingStartBeforeCaps = true
        voiceStatus = "语音键已按下 · 等待 ATVV 协商"
        log("语音键在 CAPS_RESP 前触发：延后 MIC_OPEN，不结束语音会话")
        negotiateIfReady()
        pendingStartTimeout?.cancel()
        pendingStartTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) }
            catch { return }
            guard let self, !Task.isCancelled, self.pendingStartBeforeCaps else { return }
            self.finishAudio(reason: "ATVV 能力协商超时，取消本次语音会话")
        }
    }

    private func processControl(_ data: Data) {
        guard voiceModeEnabled else { return }
        let bytes = [UInt8](data)
        guard let opcode = bytes.first else { return }
        log("CTL \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        switch opcode {
        case 0x0B:
            guard let caps = ATVVCapabilities(response: data) else {
                voiceStatus = "CAPS_RESP 数据不完整"
                return
            }
            capabilities = caps
            protocolDetails = "ATVV \(caps.displayVersion) · codec mask 0x\(String(caps.codecMask, radix: 16))" +
                " · packet \(caps.frameSize ?? 0)B"
            voiceStatus = caps.supports8k || caps.supports16k
                ? "语音按键待机 · 音频采集已关闭"
                : "不支持已实现的 ADPCM 编码，当前只能诊断"
            log("能力协商成功：\(protocolDetails)")
            if pendingStartBeforeCaps {
                pendingStartTimeout?.cancel()
                pendingStartTimeout = nil
                pendingStartBeforeCaps = false
                if caps.supports8k || caps.supports16k {
                    openMicrophoneOnDemand()
                } else {
                    finishAudio(reason: "音频编码不兼容，取消本次语音会话")
                }
            }
        case 0x08:
            guard let capabilities else {
                waitForCapabilitiesAfterPress()
                return
            }
            if isRecording {
                log("语音会话正在录音，忽略重复 START_SEARCH")
            } else if capabilities.supports8k || capabilities.supports16k {
                openMicrophoneOnDemand()
            } else {
                log("遥控器不支持 ADPCM 8k/16k 模式，未发送 MIC_OPEN")
            }
        case 0x04:
            beginAudio(codec: bytes.count >= 3 ? bytes[2] : 0x01)
        case 0x00:
            guard ATVVTransportPolicy.shouldEndOnStop(
                isRecording: isRecording,
                openingMic: microphoneOpenPending || audioChannelActive,
                hasPendingSearch: pendingStartBeforeCaps
            ) else {
                log("语音音频尚未启动时收到 0x00；忽略过期 STOP")
                return
            }
            if isRecording || microphoneOpenPending || audioChannelActive {
                let close = capabilities?.isLegacy == false ? ATVV.micCloseV1 : ATVV.micClose
                sendATVV(close, title: "MIC_CLOSE")
            }
            finishAudio(reason: "遥控器停止发送音频")
        case 0x0A:
            guard capabilities?.isLegacy == false else { return }
            if v1Decoder.synchronize(control: data) {
                let newRate = bytes[1] == 0x02 ? 16_000 : 8_000
                if isRecording && newRate != recordingRate {
                    recordedSamples.removeAll()
                    recordedSampleCount = 0
                    log("SYNC 切换采样率：清除之前不同采样率的 PCM")
                }
                recordingRate = newRate
                log("v1.0 SYNC：序号 \(v1Decoder.syncSequence ?? 0)，\(recordingRate)Hz")
            } else {
                log("v1.0 SYNC 数据无效，等待后续同步")
            }
        default:
            break
        }
    }

    private func processAudio(_ data: Data) {
        guard voiceModeEnabled, isRecording else { return }
        lastVoicePacketAt = Date()
        packetTotal += 1
        byteTotal += data.count
        defer { publishAudioMetrics() }
        guard let capabilities else { return }
        if !capabilities.isLegacy {
            guard let samples = v1Decoder.decode(data) else {
                if !unsupportedVersionLogged {
                    unsupportedVersionLogged = true
                    log("v1.0 音频通知已到达，等待 CTL SYNC 初始化 ADPCM 解码器")
                }
                return
            }
            frameTotal += 1
            storeSamples(samples)
            return
        }
        guard capabilities.frameSize == 134 else {
            if !unsupportedVersionLogged {
                unsupportedVersionLogged = true
                log("不支持的 v0.4 帧尺寸：\(capabilities.frameSize ?? 0)B")
            }
            return
        }
        let frames = pendingAudio.append(data)
        for frame in frames {
            frameTotal += 1
            storeSamples(frame.samples)
        }
    }

    private func storeSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if shouldRouteVoiceRemotely?() == true {
            onRemoteVoiceSamples?(samples, recordingRate)
        } else {
            virtualMicrophone.write(samples: samples, sampleRate: recordingRate)
        }
        let remaining = recordingRate * 60 - recordedSamples.count
        if remaining > 0 {
            recordedSamples.append(contentsOf: samples.prefix(remaining))
        } else if frameTotal % 200 == 0 {
            log("录音缓存达到 60 秒上限，仅继续统计音频包数")
        }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        levelLatest = min(1, sqrt(energy / Double(samples.count)) / 10_000)
    }

    private func publishAudioMetrics(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastMetricsUpdate) >= 0.2 else { return }
        lastMetricsUpdate = now
        audioPacketCount = packetTotal
        audioByteCount = byteTotal
        decodedFrameCount = frameTotal
        recordedSampleCount = recordedSamples.count
        droppedFrameCount = pendingAudio.droppedSequenceCount
        audioLevel = isRecording ? levelLatest : 0
    }

    private func log(_ value: String) {
        logs.append("[\(Date().formatted(date: .omitted, time: .standard))] \(value)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}

extension RemoteBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: bluetoothState = "蓝牙已开启"
            case .poweredOff: bluetoothState = "蓝牙已关闭"
            case .unauthorized: bluetoothState = "蓝牙未授权"
            case .unsupported: bluetoothState = "不支持蓝牙"
            default: bluetoothState = "蓝牙尚未就绪"
            }
            isBluetoothReady = central.state == .poweredOn
            if isBluetoothReady { restoreVoicePeripheralIfPossible() }
            if !isBluetoothReady {
                isScanning = false
                resetATVV()
            }
            log(bluetoothState)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "未命名设备"
            register(peripheral, name: name, rssi: RSSI.intValue)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard active?.identifier == peripheral.identifier else { return }
            connectedDeviceID = peripheral.identifier
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastVoiceDeviceKey)
            connectionSummary = "已连接：\(peripheral.name ?? peripheral.identifier.uuidString)"
            log("连接成功，读取 GATT 服务")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard active?.identifier == peripheral.identifier else { return }
            connectedDeviceID = nil
            connectionSummary = "连接失败"
            resetATVV()
            log(error?.localizedDescription ?? "连接失败（未知原因）")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if connectedDeviceID == peripheral.identifier {
                connectedDeviceID = nil
                connectionSummary = "设备已断开"
                discoveredServices.removeAll()
                resetATVV()
            }
            log("设备断开：\(error?.localizedDescription ?? "正常断开")")
            if autoVoiceConnectEnabled && !manuallyDisconnected && central.state == .poweredOn {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, self.connectedDeviceID == nil, self.autoVoiceConnectEnabled,
                          !self.manuallyDisconnected else { return }
                    self.restoreVoicePeripheralIfPossible()
                }
            }
        }
    }
}

extension RemoteBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { log("服务发现失败：\(error.localizedDescription)"); return }
            for service in peripheral.services ?? [] {
                discoveredServices.append("Service \(service.uuid.uuidString)")
                if service.uuid == ATVV.service {
                    atvvFound = true
                    voiceStatus = "发现 ATVV 语音服务，等待特征"
                }
                peripheral.discoverCharacteristics(nil, for: service)
            }
            if !atvvFound {
                voiceStatus = "未发现 ATVV 语音服务（可能是非语音遥控器或未授权）"
            }
            log("发现 \(peripheral.services?.count ?? 0) 个 GATT 服务")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error { log("特征发现失败：\(error.localizedDescription)"); return }
            for characteristic in service.characteristics ?? [] {
                discoveredServices.append("  └ \(characteristic.uuid.uuidString) (属性 \(characteristic.properties.rawValue))")
                if service.uuid == ATVV.service {
                    switch characteristic.uuid {
                    case ATVV.command: atvvTX = characteristic
                    case ATVV.audio: atvvAudio = characteristic
                    case ATVV.control: atvvCTL = characteristic
                    default: break
                    }
                }
            }
            if canEnableVoiceMode {
                voiceStatus = "ATVV 特征齐全：可以启用语音模式"
                if autoVoiceConnectEnabled && !voiceModeEnabled { toggleVoiceMode() }
            }
            log("服务 \(service.uuid.uuidString)：\(service.characteristics?.count ?? 0) 个特征")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard active?.identifier == peripheral.identifier else { return }
            if let error {
                log("订阅 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
                if characteristic === atvvAudio {
                    finishAudio(reason: "音频通知订阅失败")
                    voiceStatus = "音频通知启用失败；语音键待机但不占用麦克风"
                } else {
                    voiceStatus = "通知订阅失败；检查设备配对与系统蓝牙授权"
                }
                return
            }
            log("通知 \(characteristic.uuid.uuidString)：\(characteristic.isNotifying ? "已启用" : "已停用")")
            if characteristic === atvvAudio {
                if characteristic.isNotifying {
                    if microphoneOpenPending {
                        completePendingMicrophoneOpen()
                    } else {
                        log("ATVV Audio 通知已就绪，待机不采集麦克风")
                    }
                } else if voiceModeEnabled {
                    log("ATVV Audio 通知被停用，请重新启用监听以恢复协商")
                }
            }
            negotiateIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard active?.identifier == peripheral.identifier else { return }
            if let error { log("读取 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)"); return }
            guard let value = characteristic.value else { return }
            switch characteristic.uuid {
            case ATVV.control:
                if value.first == 0x00 {
                    let wasStreaming = isRecording
                    processControl(value)
                    if wasStreaming {
                        onATVVControlReport?(value)
                    } else {
                        log("0x00 出现在 AUDIO_START 前，保留待启动会话")
                    }
                } else {
                    onATVVControlReport?(value)
                    processControl(value)
                }
            case ATVV.audio:
                processAudio(value)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { log("指令写入失败：\(characteristic.uuid.uuidString) \(error.localizedDescription)") }
        }
    }
}
