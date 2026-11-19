import AppKit
import Combine
import CoreAudio
import Foundation

/// Manages MoteFlow's built-in input-only CoreAudio HAL virtual microphone (`MoteFlowMic.driver`)
/// and provides zero-output direct PCM injection over CoreAudio custom properties (`'MFPC'` / `'MFRS'`).
@MainActor
final class MoteFlowMicDriverManager: ObservableObject {
    nonisolated static let deviceUID = "MoteFlowMic_Device_UID_v1"
    static let driverBundleName = "MoteFlowMic.driver"
    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/MoteFlowMic.driver"

    // FourCC custom selectors declared in MoteFlowMic.c
    nonisolated private static let pushPCMSelector: AudioObjectPropertySelector = 0x4D465043     // 'MFPC'
    nonisolated private static let resetBufferSelector: AudioObjectPropertySelector = 0x4D465253 // 'MFRS'

    @Published private(set) var driverOnDisk = false
    @Published private(set) var isLoaded = false
    @Published private(set) var bundledDriverPath: String?
    @Published private(set) var statusMessage = "正在检测 MoteFlow 纯输入虚拟麦克风驱动…"
    @Published private(set) var lastCommandMessage: String?

    nonisolated static func isDirectPushDevice(_ uid: String) -> Bool {
        uid == deviceUID
    }

    nonisolated static func pushStereo48kPCM(deviceID: AudioDeviceID, samples: [Int16]) -> OSStatus {
        guard !samples.isEmpty else { return noErr }
        let byteCount = samples.count * MemoryLayout<Int16>.stride
        let cfData: CFData? = samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return CFDataCreate(kCFAllocatorDefault, base.assumingMemoryBound(to: UInt8.self), byteCount)
        }
        guard let cfData else { return kAudioHardwareUnspecifiedError }
        var address = AudioObjectPropertyAddress(
            mSelector: pushPCMSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var plist: Unmanaged<CFPropertyList>? = Unmanaged.passUnretained(cfData as CFPropertyList)
        return withUnsafePointer(to: &plist) { ptr in
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size),
                ptr
            )
        }
    }

    nonisolated static func resetBuffer(deviceID: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: resetBufferSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var plist: Unmanaged<CFPropertyList>? = Unmanaged.passUnretained(kCFBooleanTrue as CFPropertyList)
        return withUnsafePointer(to: &plist) { ptr in
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size),
                ptr
            )
        }
    }

    func refresh(using router: RemoteVirtualMicrophoneRouter) {
        router.refreshDevices()
        driverOnDisk = FileManager.default.fileExists(atPath: Self.installedDriverPath)
        isLoaded = router.devices.contains { $0.id == Self.deviceUID }
        bundledDriverPath = resolveBundledDriverPath()

        if isLoaded {
            statusMessage = "MoteFlow Mic（纯输入无输出）已就绪：直推 PCM 到麦克风，彻底消除屏幕共享回声。"
        } else if driverOnDisk {
            statusMessage = "驱动文件已就位，但 CoreAudio 尚未识别；请重启 CoreAudio 或重启 Mac 后重新检测。"
        } else if bundledDriverPath != nil {
            statusMessage = "未安装 MoteFlow Mic；点击下方一键安装即可彻底消除屏幕共享回声，无需 BlackHole。"
        } else {
            statusMessage = "未找到内置驱动包，请先重新运行打包脚本编译 MoteFlowMic.driver。"
        }
    }

    private func resolveBundledDriverPath() -> String? {
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent(Self.driverBundleName),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL.path
        }
        let devBuildPath = FileManager.default.currentDirectoryPath + "/.build/moteflow-mic-driver/" + Self.driverBundleName
        if FileManager.default.fileExists(atPath: devBuildPath) {
            return devBuildPath
        }
        return nil
    }

    enum Operation {
        case install
        case uninstall

        var title: String {
            switch self {
            case .install: "安装"
            case .uninstall: "卸载"
            }
        }
    }

    func launch(_ operation: Operation, router: RemoteVirtualMicrophoneRouter) {
        let command: String
        switch operation {
        case .install:
            guard let src = resolveBundledDriverPath() else {
                lastCommandMessage = "未找到内置 MoteFlowMic.driver，请先运行打包脚本生成驱动。"
                return
            }
            let escapedSrc = src.replacingOccurrences(of: "'", with: "'\\''")
            command = [
                "sudo mkdir -p /Library/Audio/Plug-Ins/HAL",
                "sudo rm -rf '\(Self.installedDriverPath)'",
                "sudo ditto '\(escapedSrc)' '\(Self.installedDriverPath)'",
                "sudo chown -R root:wheel '\(Self.installedDriverPath)'",
                "sudo chmod -R 755 '\(Self.installedDriverPath)'",
                "(sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod)",
                "echo '✅ MoteFlow Mic 安装完成，请返回 MoteFlow 点击「重新检测」。'"
            ].joined(separator: " && ")

        case .uninstall:
            if router.isUsingDirectPushMic {
                router.endSession()
            }
            command = [
                "sudo rm -rf '\(Self.installedDriverPath)'",
                "(sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || sudo killall coreaudiod)",
                "echo '✅ MoteFlow Mic 已卸载。'"
            ].joined(separator: " && ")
        }

        let escapedForAppleScript = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escapedForAppleScript)"
        end tell
        """
        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errorInfo)
        } else {
            errorInfo = ["NSAppleScriptErrorMessage": "无法创建 Terminal 自动化请求"]
        }

        if errorInfo == nil {
            lastCommandMessage = "已在终端启动 MoteFlow Mic \(operation.title)命令。输入管理员密码完成后，返回点击「重新检测」即可生效（无需重启电脑）。"
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init()) { _, _ in }
            lastCommandMessage = "无法自动操作终端，已将 \(operation.title)命令复制到剪贴板，请在终端粘贴执行。"
        }
    }
}
