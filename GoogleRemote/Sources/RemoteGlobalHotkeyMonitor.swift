import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

/// Global keyboard hotkey registration using Carbon HIToolbox for standard key
/// combinations (zero accessibility requirement, zero CPU idle cost) plus
/// NSEvent monitors as a fallback for standalone modifier-only hotkeys.
@MainActor
final class RemoteGlobalHotkeyMonitor: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var status = "尚未启用切换快捷键"

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var modifierCapture = RemoteModifierCaptureState()

    static let defaultSwitchShortcut = RemoteShortcut(
        keyCode: 46, // 'M'
        keyLabel: "M",
        command: true,
        shift: false,
        option: true,
        control: true
    )

    func update(shortcut: RemoteShortcut?, enabled: Bool) {
        unregister()
        guard enabled, let shortcut else {
            status = enabled ? "尚未设置切换快捷键" : "全局切换快捷键已暂停"
            return
        }
        if shortcut.isModifierOnly {
            registerModifierOnlyMonitor(shortcut)
        } else {
            registerCarbonHotKey(shortcut)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        modifierCapture = RemoteModifierCaptureState()
        isRegistered = false
    }

    private func registerCarbonHotKey(_ shortcut: RemoteShortcut) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == 0x4D544657, hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<RemoteGlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    owner.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            status = "全局快捷键处理器注册失败（\(installStatus)）"
            return
        }

        var carbonModifiers: UInt32 = 0
        if shortcut.command { carbonModifiers |= UInt32(cmdKey) }
        if shortcut.shift { carbonModifiers |= UInt32(shiftKey) }
        if shortcut.option { carbonModifiers |= UInt32(optionKey) }
        if shortcut.control { carbonModifiers |= UInt32(controlKey) }

        let hotKeyID = EventHotKeyID(signature: 0x4D544657, id: 1)
        var createdRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &createdRef
        )
        if regStatus == noErr, let createdRef {
            hotKeyRef = createdRef
            isRegistered = true
            status = "全局切换快捷键已就绪：\(shortcut.display)"
        } else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            status = "快捷键 \(shortcut.display) 可能被系统或其他软件占用（\(regStatus)）"
        }
    }

    private func registerModifierOnlyMonitor(_ shortcut: RemoteShortcut) {
        let targetCode = shortcut.keyCode
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleModifierEvent(event, targetCode: targetCode)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleModifierEvent(event, targetCode: targetCode)
            }
            return event
        }
        isRegistered = true
        status = "单修饰键切换已启用：\(shortcut.display)"
    }

    private func handleModifierEvent(_ event: NSEvent, targetCode: UInt16) {
        if event.type == .keyDown {
            modifierCapture.ordinaryKeyPressed()
            return
        }
        if let released = modifierCapture.flagsChanged(keyCode: event.keyCode),
           released == targetCode {
            onTrigger?()
        }
    }
}

/// Delivers both a macOS Notification Center banner (even when the app is in
/// the foreground) AND a top-of-screen non-activating HUD pill + audio cue so
/// the user always knows unmistakably which Mac is currently active.
@MainActor
final class RemoteSwitchNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteSwitchNotificationCenter()

    private var didConfigureDelegate = false

    private var canUseSystemNotifications: Bool {
        Bundle.main.bundleIdentifier != nil &&
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    override private init() {
        super.init()
    }

    func requestAuthorizationIfNeeded() {
        guard canUseSystemNotifications else { return }
        let center = UNUserNotificationCenter.current()
        if !didConfigureDelegate {
            center.delegate = self
            didConfigureDelegate = true
        }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notify unmistakably when control switches TO this local Mac.
    func notifySwitchedToThisMac(
        thisMacName: String,
        detail: String,
        hudEnabled: Bool = true,
        systemNotificationEnabled: Bool,
        soundEnabled: Bool
    ) {
        if hudEnabled {
            RemoteSwitchHUDController.shared.show(
                title: "当前控制本机：\(thisMacName)",
                subtitle: detail,
                symbol: "desktopcomputer",
                tint: RemotePalette.positive
            )
        }
        if soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        if systemNotificationEnabled {
            postSystemBanner(
                identifier: "moteflow.target.active",
                title: "已切换到本机：\(thisMacName)",
                body: detail
            )
        }
    }

    /// Notify when control leaves this Mac to control the other Mac.
    func notifySwitchedToOtherMac(
        otherMacName: String,
        detail: String,
        hudEnabled: Bool = true,
        systemNotificationEnabled: Bool,
        soundEnabled: Bool
    ) {
        if hudEnabled {
            RemoteSwitchHUDController.shared.show(
                title: "已转发至：\(otherMacName)",
                subtitle: detail,
                symbol: "macbook.and.ipad",
                tint: RemotePalette.turquoise
            )
        }
        if soundEnabled {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
        if systemNotificationEnabled {
            postSystemBanner(
                identifier: "moteflow.target.active",
                title: "正在控制另一台 Mac：\(otherMacName)",
                body: detail
            )
        }
    }

    func notifyWarning(
        title: String,
        detail: String,
        hudEnabled: Bool = true,
        soundEnabled: Bool = true
    ) {
        if hudEnabled {
            RemoteSwitchHUDController.shared.show(
                title: title,
                subtitle: detail,
                symbol: "exclamationmark.triangle.fill",
                tint: RemotePalette.amber
            )
        }
        if soundEnabled {
            NSSound(named: NSSound.Name("Basso"))?.play()
        }
    }

    private func postSystemBanner(identifier: String, title: String, body: String) {
        guard canUseSystemNotifications else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// Non-activating translucent HUD banner shown briefly at the top of the screen
/// when switching between local Mac control and remote Mac LAN forwarding.
@MainActor
final class RemoteSwitchHUDController {
    static let shared = RemoteSwitchHUDController()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(title: String, subtitle: String, symbol: String, tint: Color) {
        hideTask?.cancel()
        let content = RemoteSwitchHUDView(
            title: title, subtitle: subtitle, symbol: symbol, tint: tint
        )
        let hosting = NSHostingView(rootView: content)
        let size = NSSize(width: 376, height: 78)
        hosting.frame = NSRect(origin: .zero, size: size)

        let hud: NSPanel
        if let existing = panel {
            hud = existing
            hud.contentView = hosting
        } else {
            hud = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            hud.isFloatingPanel = true
            hud.level = .statusBar
            hud.backgroundColor = .clear
            hud.isOpaque = false
            hud.hasShadow = true
            hud.ignoresMouseEvents = true
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            hud.contentView = hosting
            panel = hud
        }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - 40
            hud.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
        hud.alphaValue = 1
        hud.orderFrontRegardless()

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1750))
            guard !Task.isCancelled, let hud = self?.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                hud.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    hud.orderOut(nil)
                }
            }
        }
    }
}

private struct RemoteSwitchHUDView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 376, height: 78)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.opacity(0.40), lineWidth: 1.3)
        )
    }
}

/// Floating confirmation window presented when another Mac on the LAN requests
/// pairing, ensuring click-to-confirm works even if MoteFlow is hidden in the menu bar.
@MainActor
final class RemotePairingPromptWindowController {
    static let shared = RemotePairingPromptWindowController()
    private var panel: NSPanel?

    private init() {}

    func present(
        request: RemoteIncomingPairingRequest,
        port: UInt16,
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        let view = RemotePairingPromptCard(
            request: request,
            port: port,
            onApprove: { [weak self] in
                self?.dismiss()
                onApprove()
            },
            onReject: { [weak self] in
                self?.dismiss()
                onReject()
            }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 410, height: 225)
        hosting.frame = NSRect(origin: .zero, size: size)

        let prompt: NSPanel
        if let existing = panel {
            prompt = existing
            prompt.contentView = hosting
        } else {
            prompt = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            prompt.titleVisibility = .hidden
            prompt.titlebarAppearsTransparent = true
            prompt.isFloatingPanel = true
            prompt.level = .floating
            prompt.backgroundColor = .clear
            prompt.isOpaque = false
            prompt.hasShadow = true
            prompt.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            prompt.contentView = hosting
            panel = prompt
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            prompt.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2 + 60,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }
        prompt.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }
}

private struct RemotePairingPromptCard: View {
    let request: RemoteIncomingPairingRequest
    let port: UInt16
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RemotePalette.indigo, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("局域网双机配对请求")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("来自「\(request.peerName)」· 共享端口 \(port)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("请核对两台 Mac 上的 6 位配对码一致：")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(request.verificationCode)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(RemotePalette.indigo)
                }
                Spacer()
            }
            .padding(12)
            .background(RemotePalette.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Text("确认后将信任该设备，允许其向本机转发遥控器操作。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("拒绝", action: onReject)
                    .buttonStyle(RemoteActionButtonStyle())
                Button("确认配对", action: onApprove)
                    .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(20)
        .frame(width: 410, height: 225)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
