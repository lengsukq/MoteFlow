import AppKit
import SwiftUI

@main
struct GoogleRemoteApp: App {
    @StateObject private var bluetooth = RemoteBluetoothManager()
    @StateObject private var hidCapture = HIDCaptureManager()
    @StateObject private var mappingStore = RemoteBindingStore()
    @StateObject private var actionLibrary = RemoteLibraryStore()
    @StateObject private var actionRunner = RemoteActionRunner()
    @StateObject private var runtime = RemoteAppRuntime()

    var body: some Scene {
        WindowGroup("MoteFlow", id: "main") {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(hidCapture)
                .environmentObject(mappingStore)
                .environmentObject(actionLibrary)
                .environmentObject(actionRunner)
                .environmentObject(runtime)
                .frame(minWidth: 860, minHeight: 580)
                .onAppear { runtime.mainWindowDidAppear() }
                .onDisappear { runtime.mainWindowDidDisappear() }
        }
        .defaultSize(width: 1170, height: 780)

        MenuBarExtra("MoteFlow", image: "MoteFlowStatusIcon") {
            RemoteMenuBarContent(
                runtime: runtime, bluetooth: bluetooth, hidCapture: hidCapture,
                actionRunner: actionRunner
            )
        }
    }
}

private struct RemoteMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var runtime: RemoteAppRuntime
    @ObservedObject var bluetooth: RemoteBluetoothManager
    @ObservedObject var hidCapture: HIDCaptureManager
    @ObservedObject var actionRunner: RemoteActionRunner

    var body: some View {
        Label(runtime.lightweightModeEnabled ? "轻量模式 · 菜单栏运行" : "MoteFlow 正在运行",
              systemImage: "checkmark.circle.fill")
        Label(hidCapture.isExclusive ? "HID 按键已接管" : "HID 尚未就绪",
              systemImage: hidCapture.isExclusive ? "checkmark.shield.fill" : "keyboard")
        Label(bluetooth.connectedDeviceID != nil ? "语音 BLE 已连接" : "语音 BLE 未连接",
              systemImage: "waveform")
        Text(bluetooth.voiceModeEnabled ? "ATVV 接收已启用" : "ATVV 接收未启用")
        Divider()
        Button("打开控制台") { runtime.openMainWindow { openWindow(id: "main") } }
            .keyboardShortcut("o")
        if runtime.mainWindowVisible {
            Button("收起到菜单栏") { runtime.enterLightweightMode() }
        }
        Button(hidCapture.autoSeizeEnabled ? "暂停按键拦截" : "恢复按键拦截") {
            if hidCapture.autoSeizeEnabled { hidCapture.disableAutomaticCapture() }
            else { hidCapture.enableAutomaticCapture() }
        }
        Button(hidCapture.executeHardwareActions ? "暂停动作执行" : "允许动作执行") {
            if hidCapture.executeHardwareActions {
                actionRunner.endVoiceShortcutHold()
                bluetooth.virtualMicrophone.finishVoiceInputWindow()
            }
            hidCapture.executeHardwareActions.toggle()
        }
        Divider()
        Button(bluetooth.voiceModeEnabled ? "关闭语音接收" : "启用语音接收") {
            bluetooth.toggleVoiceMode()
        }
        .disabled(!bluetooth.canEnableVoiceMode)
        Button("退出轻量模式并打开主窗口") {
            runtime.lightweightModeEnabled = false
            runtime.openMainWindow { openWindow(id: "main") }
        }
        .disabled(!runtime.lightweightModeEnabled)
        Divider()
        Button("彻底退出 MoteFlow") {
            actionRunner.endVoiceShortcutHold()
            bluetooth.virtualMicrophone.restoreInputOnShutdown()
            NSApp.terminate(nil)
        }
    }
}
