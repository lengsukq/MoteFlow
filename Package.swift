// swift-tools-version: 5.9
import PackageDescription

// Standalone protocol test package. The GUI remains an Xcode macOS app.
let package = Package(
    name: "GoogleRemoteProtocolTests",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ATVVCore", targets: ["ATVVCore"])],
    targets: [
        .target(
            name: "ATVVCore",
            path: "GoogleRemote/Sources",
            exclude: ["GoogleRemoteApp.swift", "RemoteBluetoothManager.swift", "NativeVoiceTranscriber.swift", "SystemHIDProbe.swift", "RemoteDesignSystem.swift", "RemoteControlCenter.swift", "RemoteOverviewPage.swift", "RemoteVoicePage.swift", "RemoteDiagnosticsPage.swift", "ShortcutRecorderView.swift", "RemoteKeyVisual.swift", "RemoteMappingPage.swift", "HIDCaptureManager.swift", "RemoteKeyLabPage.swift", "RemoteActionRunner.swift", "RemoteActionLibraryPage.swift", "RemoteTestPage.swift", "RemoteSettingsPage.swift", "RemoteVirtualMicrophoneRouter.swift", "BlackHoleDriverManager.swift", "RemoteAppRuntime.swift"],
            sources: ["ATVVoiceCore.swift", "RemoteKeyModels.swift", "RemoteDeviceProfiles.swift", "RemoteBindingStore.swift", "RemoteLibraryStore.swift", "RemoteHIDReportDecoder.swift", "RemoteHIDProfiles.swift"]
        ),
        .testTarget(name: "ATVVCoreTests", dependencies: ["ATVVCore"], path: "Tests")
    ]
)

