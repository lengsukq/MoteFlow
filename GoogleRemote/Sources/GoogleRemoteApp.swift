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
    @StateObject private var lanRelay = RemoteLANRelayManager()

    var body: some Scene {
        WindowGroup("MoteFlow", id: "main") {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(hidCapture)
                .environmentObject(mappingStore)
                .environmentObject(actionLibrary)
                .environmentObject(actionRunner)
                .environmentObject(runtime)
                .environmentObject(lanRelay)
                .frame(minWidth: 880, minHeight: 600)
                .onAppear { runtime.mainWindowDidAppear() }
                .onDisappear { runtime.mainWindowDidDisappear() }
        }
        .defaultSize(width: 1180, height: 800)

        MenuBarExtra("MoteFlow", image: "MoteFlowStatusIcon") {
            RemoteMenuBarContent(
                runtime: runtime,
                bluetooth: bluetooth,
                hidCapture: hidCapture,
                actionRunner: actionRunner,
                lanRelay: lanRelay
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
    @ObservedObject var lanRelay: RemoteLANRelayManager

    var body: some View {
        Label(
            runtime.lightweightModeEnabled ? "轻量模式 · 菜单栏运行中" : "MoteFlow 正在运行",
            systemImage: "checkmark.circle.fill"
        )
        Label(
            hidCapture.isExclusive ? "遥控器按键：已独占就绪" : "遥控器按键：等待连接",
            systemImage: hidCapture.isExclusive ? "checkmark.shield.fill" : "keyboard"
        )
        Label(
            lanRelay.isForwardingToRemoteMac
                ? "当前控制：远端「\(lanRelay.connectedPeerName ?? "另一台 Mac")」"
                : lanRelay.isControlledByPeer
                    ? "正在接收来自「\(lanRelay.controllingPeerName ?? "主控 Mac")」的操作"
                    : "当前控制：本机 Mac",
            systemImage: lanRelay.isForwardingToRemoteMac ? "macbook.and.ipad" : "desktopcomputer"
        )
        Label(
            bluetooth.isRecording ? "语音：正在采集录音" :
                bluetooth.voiceModeEnabled ? "语音：待机就绪" : "语音：未开启监听",
            systemImage: "waveform"
        )
        Divider()
        Button("打开主界面") {
            runtime.openMainWindow { openWindow(id: "main") }
        }
        .keyboardShortcut("o")

        if lanRelay.isConnected {
            Button(
                lanRelay.activeTarget == .remoteMac
                    ? "切回控制本机 Mac (\(lanRelay.switchShortcut.display))"
                    : "切换控制「\(lanRelay.connectedPeerName ?? "另一台 Mac")」(\(lanRelay.switchShortcut.display))"
            ) {
                lanRelay.toggleTarget(showHUD: true)
            }

            Menu("远程按键跟随方式") {
                Button {
                    lanRelay.setMappingFollowSource(.followRemoteMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followRemoteMac {
                        Label("跟随远程的遥控器设置", systemImage: "checkmark")
                    } else {
                        Text("跟随远程的遥控器设置")
                    }
                }
                Button {
                    lanRelay.setMappingFollowSource(.followLocalMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followLocalMac {
                        Label("跟随本机的遥控器设置", systemImage: "checkmark")
                    } else {
                        Text("跟随本机的遥控器设置")
                    }
                }
            }
        }

        if runtime.mainWindowVisible {
            Button("进入轻量模式（收起到菜单栏）") { runtime.enterLightweightMode() }
        }
        Divider()
        Button(hidCapture.executeHardwareActions ? "暂停遥控器动作执行" : "开启遥控器动作执行") {
            if hidCapture.executeHardwareActions {
                actionRunner.endVoiceShortcutHold()
                bluetooth.stopCurrentVoiceSession()
                bluetooth.virtualMicrophone.finishVoiceInputWindow()
            }
            hidCapture.executeHardwareActions.toggle()
        }
        Button(hidCapture.autoSeizeEnabled ? "暂停遥控器按键接管" : "恢复遥控器按键接管") {
            if hidCapture.autoSeizeEnabled { hidCapture.disableAutomaticCapture() }
            else { hidCapture.enableAutomaticCapture() }
        }
        Button(bluetooth.voiceModeEnabled ? "关闭语音键监听" : "开启语音键监听") {
            bluetooth.toggleVoiceMode()
        }
        .disabled(!bluetooth.canEnableVoiceMode)

        if runtime.lightweightModeEnabled {
            Button("恢复常规 Dock 窗口模式") {
                runtime.lightweightModeEnabled = false
                runtime.openMainWindow { openWindow(id: "main") }
            }
        }
        Divider()
        Button("彻底退出 MoteFlow") {
            actionRunner.endVoiceShortcutHold()
            lanRelay.disconnectCurrentPeer(reason: "退出应用", pauseSessionAutoConnect: false)
            bluetooth.stopVoiceMode()
            bluetooth.virtualMicrophone.restoreInputOnShutdown()
            NSApp.terminate(nil)
        }
    }
}
