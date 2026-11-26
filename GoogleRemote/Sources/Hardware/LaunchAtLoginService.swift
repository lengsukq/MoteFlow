import Foundation
import ServiceManagement

/// macOS 13+ native Launch-at-Login adapter backed by `SMAppService.mainApp`.
/// Reads real OS registration status as the single source of truth so changes
/// made in System Settings → General → Login Items are always reflected accurately.
struct SystemLaunchAtLoginService: LaunchAtLoginManaging {
    private var isBundledApplication: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    var currentStatus: LaunchAtLoginStatus {
        guard isBundledApplication else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered, .notFound:
            // macOS backgroundtaskmanagementd returns `.notFound` ("record not found")
            // for valid `.app` bundles that have never been registered yet or whose BTM
            // entry was removed on unregister; treat it as `.disabled` so the user can
            // trigger initial registration via `register()`.
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .disabled
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
