import AppKit
import Combine
import SwiftUI

/// Owns the small always-on part of the app independently of the main
/// SwiftUI window. Hiding/closing the window must never stop HID monitoring
/// or Dual-Mac LAN relay forwarding.
@MainActor
final class RemoteAppRuntime: ObservableObject {
    @Published var lightweightModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lightweightModeEnabled, forKey: Self.preferenceKey)
            if !lightweightModeEnabled { NSApp.setActivationPolicy(.regular) }
            else if !mainWindowVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
    @Published private(set) var mainWindowVisible = true
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginErrorMessage: String?

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus.isEnabled
    }

    private static let preferenceKey = "GoogleRemote.lightweightModeEnabled.v1"
    private let launchAtLoginService: LaunchAtLoginManaging
    private var cancellables: Set<AnyCancellable> = []
    private weak var monitor: HIDCaptureManager?
    private weak var runner: RemoteActionRunner?
    private weak var bluetooth: RemoteBluetoothManager?
    private weak var lanRelay: RemoteLANRelayManager?
    private var monitoringTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var handledInitialWindow = false

    init(launchAtLoginService: LaunchAtLoginManaging = SystemLaunchAtLoginService()) {
        self.launchAtLoginService = launchAtLoginService
        self.lightweightModeEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        self.launchAtLoginStatus = launchAtLoginService.currentStatus

        // Keep Login Items status synced when the user toggles MoteFlow directly
        // inside macOS System Settings and returns to the app or opens the menu bar.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshLaunchAtLoginStatus()
            }
            .store(in: &cancellables)
    }

    func refreshLaunchAtLoginStatus() {
        let latest = launchAtLoginService.currentStatus
        if latest != launchAtLoginStatus {
            launchAtLoginStatus = latest
        }
        if latest == .enabled {
            launchAtLoginErrorMessage = nil
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool, announceHUD: Bool = false) {
        let result = LaunchAtLoginController.apply(
            desiredEnabled: enabled,
            service: launchAtLoginService
        )
        launchAtLoginStatus = result.status
        launchAtLoginErrorMessage = result.errorMessage
        if result.shouldOpenSystemSettings {
            launchAtLoginService.openSystemSettings()
        }
        guard announceHUD else { return }

        if let errorMessage = result.errorMessage {
            RemoteSwitchHUDController.shared.show(
                title: result.status.needsSystemSettingsApproval ? "需在系统设置允许开机自启" : "开机自启设置未生效",
                subtitle: errorMessage,
                symbol: "exclamationmark.triangle.fill",
                tint: RemotePalette.amber
            )
        } else if result.status.isEnabled {
            RemoteSwitchHUDController.shared.show(
                title: "已开启开机自动启动",
                subtitle: lightweightModeEnabled
                    ? "下次登录 macOS 将自动静默常驻菜单栏"
                    : "下次登录 macOS 将自动启动 MoteFlow",
                symbol: "power.circle.fill",
                tint: RemotePalette.positive
            )
        } else {
            RemoteSwitchHUDController.shared.show(
                title: "已关闭开机自动启动",
                subtitle: "已从 macOS 登录项中移除 MoteFlow",
                symbol: "power.circle",
                tint: RemotePalette.indigo
            )
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func startKeepingRemoteAlive(
        _ manager: HIDCaptureManager,
        runner: RemoteActionRunner,
        bluetooth: RemoteBluetoothManager,
        lanRelay: RemoteLANRelayManager? = nil
    ) {
        monitor = manager
        self.runner = runner
        self.bluetooth = bluetooth
        self.lanRelay = lanRelay
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.runner?.endVoiceShortcutHold()
                    self?.runner?.cancelPendingMappedActions()
                    self?.runner?.endMappedShortcutHold()
                    self?.lanRelay?.hotkeyMonitor.unregister()
                    self?.lanRelay?.disconnectCurrentPeer(reason: "MoteFlow 退出", pauseSessionAutoConnect: false)
                    // Close the microphone lease before quitting, even if
                    // all SwiftUI windows have been hidden for hours.
                    self?.bluetooth?.stopVoiceMode()
                    self?.bluetooth?.virtualMicrophone.restoreInputOnShutdown()
                }
            }
        }
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.monitor?.tryAutomaticCapture()
            }
        }
    }

    func mainWindowDidAppear() {
        if !handledInitialWindow {
            handledInitialWindow = true
            if lightweightModeEnabled {
                // Restore the user's previous menu-bar-only choice on launch.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(130))
                    enterLightweightMode(announceHUD: false)
                }
                return
            }
        }
        mainWindowVisible = true
        NSApp.setActivationPolicy(.regular)
    }

    func mainWindowDidDisappear() {
        mainWindowVisible = false
        if lightweightModeEnabled {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func enterLightweightMode(announceHUD: Bool = true) {
        lightweightModeEnabled = true
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            window.orderOut(nil)
        }
        mainWindowVisible = false
        NSApp.setActivationPolicy(.accessory)
        if announceHUD {
            RemoteSwitchHUDController.shared.show(
                title: "已进入菜单栏轻量模式",
                subtitle: "遥控器与双机互联仍在后台运行 · 点击右上角菜单栏图标可重新打开",
                symbol: "menubar.arrow.up.rectangle",
                tint: RemotePalette.indigo
            )
        }
    }

    func openMainWindow(_ open: () -> Void) {
        handledInitialWindow = true
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            mainWindowVisible = true
        }
    }
}
