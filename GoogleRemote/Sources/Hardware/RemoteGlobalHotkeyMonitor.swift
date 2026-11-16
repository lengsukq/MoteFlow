import AppKit
import Carbon.HIToolbox
import Combine

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
