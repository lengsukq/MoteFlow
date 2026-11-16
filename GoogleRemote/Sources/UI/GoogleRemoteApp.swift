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
            hidCapture.isExclusive
                ? (hidCapture.executeHardwareActions ? "遥控器：已接管生效" : "遥控器：仅预览模式")
                : (hidCapture.isRemoteControlActive ? "遥控器：等待唤醒连接" : "遥控器：已暂停控制"),
            systemImage: hidCapture.isExclusive ? "checkmark.shield.fill" : "keyboard"
        )
        Label(
            lanRelay.isForwardingToRemoteMac
                ? "当前控制：远端「\(lanRelay.connectedPeerName ?? "另一台 Mac")」"
                : lanRelay.isControlledByPeer
                    ? "正在接收来自「\(lanRelay.controllingPeerName ?? "主控 Mac")」的操作"
                    : "当前控制：本机「\(lanRelay.localPeerName)」",
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
                    ? "切回控制「\(lanRelay.localPeerName)」(\(lanRelay.switchShortcut.display))"
                    : "切换控制「\(lanRelay.connectedPeerName ?? "另一台 Mac")」(\(lanRelay.switchShortcut.display))"
            ) {
                lanRelay.toggleTarget(showHUD: true)
            }

            Menu("双机键位生效方案（当前：\(lanRelay.activeMappingOwnerName)）") {
                let peerLabel = lanRelay.connectedPeerName ?? "另一台 Mac"
                Button {
                    lanRelay.setMappingFollowSource(.followLocalMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followLocalMac {
                        Label("套用「\(lanRelay.localPeerName)」的键位方案", systemImage: "checkmark")
                    } else {
                        Text("套用「\(lanRelay.localPeerName)」的键位方案")
                    }
                }
                Button {
                    lanRelay.setMappingFollowSource(.followRemoteMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followRemoteMac {
                        Label("套用「\(peerLabel)」的键位方案", systemImage: "checkmark")
                    } else {
                        Text("套用「\(peerLabel)」的键位方案")
                    }
                }
            }
        }

        if runtime.mainWindowVisible {
            Button("收起到菜单栏（轻量模式）") { runtime.enterLightweightMode() }
        }
        Divider()
        Button(hidCapture.isRemoteControlActive ? "暂停遥控器控制" : "恢复遥控器控制") {
            if hidCapture.isRemoteControlActive {
                actionRunner.endVoiceShortcutHold()
                bluetooth.stopCurrentVoiceSession()
                bluetooth.virtualMicrophone.finishVoiceInputWindow()
                hidCapture.setRemoteControlActive(false)
            } else {
                hidCapture.setRemoteControlActive(true)
            }
        }
        Button(bluetooth.voiceModeEnabled ? "关闭语音键监听" : "开启语音键监听") {
            bluetooth.toggleVoiceMode()
        }
        .disabled(!bluetooth.canEnableVoiceMode)

        if runtime.lightweightModeEnabled {
            Button("恢复常规程序坞窗口模式") {
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
