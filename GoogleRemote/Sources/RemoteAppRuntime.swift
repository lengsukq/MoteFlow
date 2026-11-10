import AppKit
import Combine
import SwiftUI

/// Owns the small always-on part of the app independently of the main
/// SwiftUI window. Hiding/closing the window must never stop HID monitoring.
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

    private static let preferenceKey = "GoogleRemote.lightweightModeEnabled.v1"
    private weak var monitor: HIDCaptureManager?
    private weak var runner: RemoteActionRunner?
    private weak var bluetooth: RemoteBluetoothManager?
    private var monitoringTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var handledInitialWindow = false

    init() {
        lightweightModeEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    func startKeepingRemoteAlive(_ manager: HIDCaptureManager,
                                 runner: RemoteActionRunner,
                                 bluetooth: RemoteBluetoothManager) {
        monitor = manager
        self.runner = runner
        self.bluetooth = bluetooth
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.runner?.endVoiceShortcutHold()
                    self?.runner?.cancelPendingMappedActions()
                    self?.runner?.endMappedShortcutHold()
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
                    enterLightweightMode()
                }
                return
            }
        }
        mainWindowVisible = true
        // Allow a normal macOS app window and Dock behavior while editing.
        NSApp.setActivationPolicy(.regular)
    }

    func mainWindowDidDisappear() {
        mainWindowVisible = false
        if lightweightModeEnabled {
            // Accessory apps retain their status-bar menu without a Dock icon.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func enterLightweightMode() {
        lightweightModeEnabled = true
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            window.orderOut(nil)
        }
        mainWindowVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    func openMainWindow(_ open: () -> Void) {
        // Opening the configuration UI is intentional, even if the persistent
        // preference still says to return to the menu bar when closed.
        handledInitialWindow = true
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate(ignoringOtherApps: true)
        // WindowGroup may recreate a closed window on the next run-loop turn.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            mainWindowVisible = true
        }
    }
}
