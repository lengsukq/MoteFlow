import Foundation

/// Pure domain representation of macOS Launch-at-Login (`SMAppService.mainApp`) status.
/// Kept free of AppKit/ServiceManagement imports so transitions and error recovery
/// can be verified deterministically in `ATVVCoreTests`.
enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable

    var isEnabled: Bool {
        self == .enabled
    }

    var needsSystemSettingsApproval: Bool {
        self == .requiresApproval
    }

    var badgeTitle: String {
        switch self {
        case .enabled: "已开启"
        case .disabled: "未开启"
        case .requiresApproval: "待系统设置允许"
        case .unavailable: "暂不可用"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "power.circle"
        case .requiresApproval: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    var detailMessage: String {
        switch self {
        case .enabled:
            "登录 macOS 后会自动启动并接管已配对遥控器；搭配下方「菜单栏轻量模式」可静默常驻菜单栏。"
        case .disabled:
            "开启后每次登录 macOS 自动运行 MoteFlow，无需手动打开即可直接使用遥控器与双机协同。"
        case .requiresApproval:
            "macOS 正在等待你在「系统设置 → 通用 → 登录项与扩展」中允许 MoteFlow 开机自启。"
        case .unavailable:
            "当前未从标准 MoteFlow.app 启动，无法注册系统开机自启；请从应用程序目录打开已安装版本。"
        }
    }
}

/// Abstracts `SMAppService.mainApp` so `RemoteAppRuntime` stays testable without
/// mutating the host machine's real macOS login items during unit tests.
protocol LaunchAtLoginManaging {
    var currentStatus: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct LaunchAtLoginTransitionResult: Equatable, Sendable {
    let status: LaunchAtLoginStatus
    let errorMessage: String?
    let shouldOpenSystemSettings: Bool
}

enum LaunchAtLoginController {
    static func apply(
        desiredEnabled: Bool,
        service: LaunchAtLoginManaging
    ) -> LaunchAtLoginTransitionResult {
        desiredEnabled ? enable(using: service) : disable(using: service)
    }

    private static func enable(using service: LaunchAtLoginManaging) -> LaunchAtLoginTransitionResult {
        let current = service.currentStatus
        if current == .enabled {
            return LaunchAtLoginTransitionResult(
                status: .enabled,
                errorMessage: nil,
                shouldOpenSystemSettings: false
            )
        }
        if current == .unavailable {
            return LaunchAtLoginTransitionResult(
                status: .unavailable,
                errorMessage: "当前运行形态不支持注册开机自启，请先从应用程序目录打开 MoteFlow.app。",
                shouldOpenSystemSettings: false
            )
        }

        do {
            try service.register()
            let updated = service.currentStatus
            switch updated {
            case .enabled:
                return LaunchAtLoginTransitionResult(
                    status: .enabled,
                    errorMessage: nil,
                    shouldOpenSystemSettings: false
                )
            case .requiresApproval:
                return LaunchAtLoginTransitionResult(
                    status: .requiresApproval,
                    errorMessage: "macOS 需要你在「系统设置 → 通用 → 登录项与扩展」中手动允许 MoteFlow 开机自启。",
                    shouldOpenSystemSettings: true
                )
            case .disabled, .unavailable:
                return LaunchAtLoginTransitionResult(
                    status: updated,
                    errorMessage: "未能完成开机自启注册，请前往「系统设置 → 通用 → 登录项与扩展」手动添加 MoteFlow。",
                    shouldOpenSystemSettings: false
                )
            }
        } catch {
            let updated = service.currentStatus
            if updated == .requiresApproval {
                return LaunchAtLoginTransitionResult(
                    status: .requiresApproval,
                    errorMessage: "macOS 需要你在「系统设置 → 通用 → 登录项与扩展」中允许 MoteFlow 开机自启。",
                    shouldOpenSystemSettings: true
                )
            }
            return LaunchAtLoginTransitionResult(
                status: updated,
                errorMessage: "开启开机自启失败（\(error.localizedDescription)）。请确认应用已安装至应用程序目录，或在系统设置中手动添加。",
                shouldOpenSystemSettings: false
            )
        }
    }

    private static func disable(using service: LaunchAtLoginManaging) -> LaunchAtLoginTransitionResult {
        if service.currentStatus == .disabled {
            return LaunchAtLoginTransitionResult(
                status: .disabled,
                errorMessage: nil,
                shouldOpenSystemSettings: false
            )
        }

        do {
            try service.unregister()
            let updated = service.currentStatus
            if updated == .disabled {
                return LaunchAtLoginTransitionResult(
                    status: .disabled,
                    errorMessage: nil,
                    shouldOpenSystemSettings: false
                )
            }
            return LaunchAtLoginTransitionResult(
                status: updated,
                errorMessage: "未能取消开机自启，请前往「系统设置 → 通用 → 登录项与扩展」手动关闭 MoteFlow。",
                shouldOpenSystemSettings: false
            )
        } catch {
            let updated = service.currentStatus
            if updated == .disabled {
                return LaunchAtLoginTransitionResult(
                    status: .disabled,
                    errorMessage: nil,
                    shouldOpenSystemSettings: false
                )
            }
            return LaunchAtLoginTransitionResult(
                status: updated,
                errorMessage: "关闭开机自启失败（\(error.localizedDescription)）。可前往「系统设置 → 通用 → 登录项与扩展」手动关闭。",
                shouldOpenSystemSettings: false
            )
        }
    }
}
