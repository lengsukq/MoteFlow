import AppKit
import Foundation
import SwiftUI

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
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.installedCaskVersion(brew: path)
            await MainActor.run {
                guard let self else { return }
                self.homebrewVersion = result.brewInfo
                self.caskVersion = result.version
                self.checking = false
                self.updateDescription(isLoaded: router.devices.contains {
                    $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
                })
            }
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
            // Avoid Homebrew auto-update during a read-only status check.
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

    /// Called only after the user confirms an explicit install/uninstall.
    /// Homebrew itself requests administrator approval in interactive Terminal.
    /// We do not spawn sudo, capture passwords, or claim completion.
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

        // The program path and cask name come from hardcoded allowlists; no
        // user-controlled strings are interpolated into a shell command.
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
            // The Automation permission might be denied. Copy the identical
            // allowlisted command and open Terminal; user chooses to execute.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init()) { _, _ in }
            lastCommandMessage = "无法自动操作终端（可能未授权自动化）。已复制 \(operation.title)命令，请在打开的终端粘贴执行。"
        }
    }
}

struct BlackHoleDriverManagementCard: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter
    @StateObject private var manager = BlackHoleDriverManager()
    @State private var confirmInstall = false
    @State private var confirmUninstall = false

    private var loaded: Bool {
        router.devices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }
    }

    var body: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    RemoteSectionTitle(
                        title: "BlackHole 2ch · 驱动管理",
                        subtitle: "检测、安装、卸载和系统音频状态",
                        symbol: "waveform.path"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: loaded ? "已加载" :
                            (manager.driverOnDisk || manager.isHomebrewInstalled ? "待激活" : "未安装"),
                        symbol: loaded ? "checkmark.circle.fill" : "circle.dotted",
                        tint: loaded ? RemotePalette.positive : RemotePalette.amber
                    )
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(RemotePalette.indigo)
                    Text(manager.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Label(manager.homebrewPath == nil ? "Homebrew 未找到" : "Homebrew 可用",
                          systemImage: manager.homebrewPath == nil ? "xmark.circle" : "checkmark.circle")
                    if let version = manager.caskVersion {
                        Label("已安装 \(version)", systemImage: "shippingbox")
                    }
                    if manager.driverOnDisk {
                        Label("驱动文件存在", systemImage: "externaldrive")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    Button {
                        manager.refresh(using: router)
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(manager.checking)

                    if manager.canInstallWithHomebrew {
                        if !manager.isHomebrewInstalled && !loaded && !manager.driverOnDisk {
                            Button("一键安装", systemImage: "arrow.down.circle") {
                                confirmInstall = true
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(manager.checking)
                        } else if manager.isHomebrewInstalled {
                            Button("卸载 BlackHole 2ch", systemImage: "trash") {
                                confirmUninstall = true
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                            .disabled(manager.checking)
                        }
                    } else {
                        Link("获取 Homebrew", destination: URL(string: "https://brew.sh/")!)
                    }
                    Spacer(minLength: 0)
                }

                if (loaded || manager.driverOnDisk) && !manager.isHomebrewInstalled {
                    Text("检测到系统中的驱动并非 Homebrew 管理。为避免误删其他安装来源，请使用 BlackHole 官方卸载工具。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link("官方卸载说明", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
                }
                if let message = manager.lastCommandMessage {
                    Label(message, systemImage: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(RemotePalette.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("操作会在 Terminal 中执行 Homebrew 命令，并可能请求管理员密码；MoteFlow 不读取或保存密码。安装/卸载后按提示重启，再检测系统是否识别。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            manager.refresh(using: router)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refresh(using: router)
        }
        .confirmationDialog("安装 BlackHole 2ch 虚拟音频驱动？",
                            isPresented: $confirmInstall) {
            Button("打开终端安装") {
                manager.launch(.install, router: router)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将运行官方 Homebrew 命令：brew install --cask blackhole-2ch。安装可能需要管理员授权和重启；MoteFlow 不会静默提权。")
        }
        .confirmationDialog("卸载 BlackHole 2ch？",
                            isPresented: $confirmUninstall) {
            Button("停止路由并打开终端卸载", role: .destructive) {
                manager.launch(.uninstall, router: router)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止 MoteFlow 的虚拟麦克风路由，运行 brew uninstall --cask blackhole-2ch。使用同一音频设备的其他应用也可能中断；完成后可能需要重启。")
        }
    }
}
