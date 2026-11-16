import AppKit
import Combine
import Foundation

/// Only manages the official Homebrew cask for BlackHole **2ch**.
/// Never removes a manually installed driver or any 16/64ch device.
@MainActor
final class BlackHoleDriverManager: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var homebrewPath: String?
    @Published private(set) var homebrewVersion: String?
    @Published private(set) var caskVersion: String?
    @Published private(set) var driverOnDisk = false
    @Published private(set) var statusMessage = "正在检查 BlackHole 2ch"
    @Published private(set) var lastCommandMessage: String?

    private static let officialDriverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    var isHomebrewInstalled: Bool { caskVersion != nil }
    var canInstallWithHomebrew: Bool { homebrewPath != nil }

    func refresh(using router: RemoteVirtualMicrophoneRouter) {
        router.refreshDevices()
        driverOnDisk = FileManager.default.fileExists(atPath: Self.officialDriverPath)
        let loaded = router.devices.contains {
            $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
        }
        checking = true
        statusMessage = "正在检查 Homebrew 与系统音频驱动…"
        let path = Self.brewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        homebrewPath = path

        guard let path else {
            homebrewVersion = nil
            caskVersion = nil
            checking = false
            updateDescription(isLoaded: loaded)
            return
        }
        Task { [weak self, weak router] in
            let result = await Task.detached(priority: .utility) {
                Self.installedCaskVersion(brew: path)
            }.value
            guard let self else { return }
            self.homebrewVersion = result.brewInfo
            self.caskVersion = result.version
            self.checking = false
            self.updateDescription(isLoaded: router?.devices.contains {
                $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
            } ?? false)
        }
    }

    private func updateDescription(isLoaded: Bool) {
        if isLoaded {
            statusMessage = "BlackHole 2ch 已加载，可在 MoteFlow 和豆包中选择。"
        } else if driverOnDisk || isHomebrewInstalled {
            statusMessage = "驱动已经安装，但 CoreAudio 尚未识别；安装后通常需要重新启动 Mac。"
        } else {
            statusMessage = "未检测到 BlackHole 2ch；可以通过 Homebrew 安装。"
        }
    }

    nonisolated private static func installedCaskVersion(brew: String) -> (version: String?, brewInfo: String?) {
        func run(_ args: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ANALYTICS": "1"
            ]) { _, new in new }
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }
        let info = run(["--version"])?.components(separatedBy: .newlines).first
        let output = run(["list", "--cask", "--versions", "blackhole-2ch"])
        let version = output?.split(whereSeparator: \.isWhitespace).last.map(String.init)
        return (version, info)
    }

    enum Operation {
        case install
        case uninstall

        var arguments: String {
            switch self {
            case .install: "install --cask blackhole-2ch"
            case .uninstall: "uninstall --cask blackhole-2ch"
            }
        }

        var title: String {
            switch self {
            case .install: "安装"
            case .uninstall: "卸载"
            }
        }
    }

    func launch(_ operation: Operation, router: RemoteVirtualMicrophoneRouter) {
        guard let homebrewPath else {
            lastCommandMessage = "未安装 Homebrew，请打开官方安装页面进行安装。"
            return
        }
        if case .uninstall = operation {
            guard isHomebrewInstalled else {
                lastCommandMessage = "该驱动不是通过 Homebrew 管理的，不能使用 Homebrew 卸载。"
                return
            }
            router.isEnabled = false
            router.endSession()
        }

        let command = "'\(homebrewPath)' \(operation.arguments)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&errorInfo)
        } else {
            errorInfo = ["NSAppleScriptErrorMessage": "无法创建 Terminal 自动化请求"]
        }
        if errorInfo == nil {
            lastCommandMessage = "已在终端启动 BlackHole 2ch \(operation.title)命令。请按终端提示授权，完成后返回点击「重新检测」。"
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init()) { _, _ in }
            lastCommandMessage = "无法自动操作终端（可能未授权自动化）。已复制 \(operation.title)命令，请在打开的终端粘贴执行。"
        }
    }
}
