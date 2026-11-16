import Foundation

/// Ready-to-use beginner scene presets so first-time users can get immediate
/// value in 1 click without manually configuring 10+ keys from scratch.
enum RemoteStarterScenePreset: String, CaseIterable, Identifiable {
    case mediaBrowsing
    case presentationDeck
    case aiVoiceProductivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mediaBrowsing: "影音刷剧模式"
        case .presentationDeck: "演示翻页模式"
        case .aiVoiceProductivity: "AI 语音办公"
        }
    }

    var subtitle: String {
        switch self {
        case .mediaBrowsing: "上下切视频 · 左右快进退 · 确认暂停 · 侧键复制粘贴"
        case .presentationDeck: "左右翻页 · 确认播放 · 返回退出演示 · 输入源切双机"
        case .aiVoiceProductivity: "方向移动 · 侧键全选复制粘贴 · 主页唤起 AI · 输入源切双机"
        }
    }

    var symbol: String {
        switch self {
        case .mediaBrowsing: "play.tv.fill"
        case .presentationDeck: "rectangle.on.rectangle.angled"
        case .aiVoiceProductivity: "waveform.badge.mic"
        }
    }
}

extension RemoteBindingStore {
    /// Applies a beginner starter scene preset to the active remote model and
    /// optionally saves/updates it as a named profile for effortless switching.
    func applyStarterScene(_ preset: RemoteStarterScenePreset) {
        applyFactoryMapping()

        let spaceShortcut = RemoteShortcut(
            keyCode: 49, keyLabel: "Space",
            command: false, shift: false, option: false, control: false
        )
        let fullScreenShortcut = RemoteShortcut(
            keyCode: 3, keyLabel: "F",
            command: true, shift: false, option: false, control: true
        )
        let pageUp = RemoteShortcut(
            keyCode: 123, keyLabel: "←",
            command: false, shift: false, option: false, control: false
        )
        let pageDown = RemoteShortcut(
            keyCode: 124, keyLabel: "→",
            command: false, shift: false, option: false, control: false
        )

        switch preset {
        case .mediaBrowsing:
            _ = setShortcut(spaceShortcut, for: .select, gesture: .tap, replaceConflict: true)
            _ = setShortcut(fullScreenShortcut, for: .select, gesture: .longPress, replaceConflict: true)
            if activeModel.keys.contains(.input) {
                setSystemAction(.switchMacTarget, for: .input, gesture: .tap)
            }

        case .presentationDeck:
            _ = setShortcut(pageDown, for: .right, gesture: .tap, replaceConflict: true)
            _ = setShortcut(pageDown, for: .down, gesture: .tap, replaceConflict: true)
            _ = setShortcut(pageUp, for: .left, gesture: .tap, replaceConflict: true)
            _ = setShortcut(pageUp, for: .up, gesture: .tap, replaceConflict: true)
            _ = setShortcut(spaceShortcut, for: .select, gesture: .tap, replaceConflict: true)
            _ = setShortcut(fullScreenShortcut, for: .select, gesture: .longPress, replaceConflict: true)
            if activeModel.keys.contains(.input) {
                setSystemAction(.switchMacTarget, for: .input, gesture: .tap)
            }

        case .aiVoiceProductivity:
            if activeModel.keys.contains(.home) {
                setLibraryAction(RemoteLibraryStore.chatGPTPresetID, for: .home, gesture: .tap)
            }
            if activeModel.keys.contains(.input) {
                setSystemAction(.switchMacTarget, for: .input, gesture: .tap)
            }
            if activeModel.keys.contains(.mute) {
                setSystemAction(.screenshotAreaClipboard, for: .mute, gesture: .tap)
            }
        }
    }
}
