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

        MenuBarExtra {
            RemoteMenuBarContent(
                runtime: runtime,
                bluetooth: bluetooth,
                hidCapture: hidCapture,
                actionRunner: actionRunner,
                lanRelay: lanRelay
            )
        } label: {
            RemoteMenuBarIcon(lanRelay: lanRelay)
        }
    }
}

private struct RemoteMenuBarIcon: View {
    @ObservedObject var lanRelay: RemoteLANRelayManager

    private var iconName: String {
        if lanRelay.isRemoteMacActiveControlTarget {
            return "MoteFlowStatusIconRemote"
        }
        if lanRelay.isControlledByPeer {
            return "MoteFlowStatusIconControlled"
        }
        return "MoteFlowStatusIcon"
    }

    private var accessibilityTitle: String {
        if lanRelay.isRemoteMacActiveControlTarget {
            return "MoteFlow（当前控制远端 Mac）"
        }
        if lanRelay.isControlledByPeer {
            return "MoteFlow（本机正接收远端遥控）"
        }
        return "MoteFlow（当前控制本机）"
    }

    var body: some View {
        Image(iconName)
            .renderingMode(.template)
            .accessibilityLabel(accessibilityTitle)
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
            lanRelay.isRemoteMacActiveControlTarget
                ? "当前控制：远端 Mac"
                : lanRelay.isControlledByPeer
                    ? "当前控制：本机（接收远端转发）"
                    : "当前控制：本机",
            systemImage: lanRelay.isRemoteMacActiveControlTarget ? "macbook.and.ipad" : "desktopcomputer"
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
                lanRelay.isRemoteMacActiveControlTarget
                    ? "切回控制本机 (\(lanRelay.switchShortcut.display))"
                    : "切换控制远端 Mac (\(lanRelay.switchShortcut.display))"
            ) {
                lanRelay.switchControlFocus(toLocalMac: !lanRelay.isLocalMacActiveControlTarget, showHUD: true)
            }

            Menu("双机键位生效方案（当前：\(lanRelay.activeMappingOwnerName)）") {
                Button {
                    lanRelay.setMappingFollowSource(.followLocalMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followLocalMac {
                        Label("套用本机键位方案", systemImage: "checkmark")
                    } else {
                        Text("套用本机键位方案")
                    }
                }
                Button {
                    lanRelay.setMappingFollowSource(.followRemoteMac)
                } label: {
                    if lanRelay.localMappingFollowSource == .followRemoteMac {
                        Label("套用远端键位方案", systemImage: "checkmark")
                    } else {
                        Text("套用远端键位方案")
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
        Toggle("开机自动启动", isOn: Binding(
            get: { runtime.isLaunchAtLoginEnabled },
            set: { runtime.setLaunchAtLoginEnabled($0, announceHUD: true) }
        ))
        .disabled(runtime.launchAtLoginStatus == .unavailable)
        if runtime.launchAtLoginStatus.needsSystemSettingsApproval {
            Button("在系统设置中允许开机自启…") {
                runtime.openLoginItemsSettings()
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
