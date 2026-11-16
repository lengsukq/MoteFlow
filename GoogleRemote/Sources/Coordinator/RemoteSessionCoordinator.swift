import Combine
import Foundation

/// Central coordinator bridging HID hardware capture, ATVV Bluetooth voice,
/// local action execution, anti-echo speaker muting, and Dual-Mac LAN relay
/// forwarding & configuration sync via an explicit `VoiceSessionStateMachine`.
@MainActor
final class RemoteSessionCoordinator {
    private weak var bluetooth: RemoteBluetoothManager?
    private weak var hidCapture: HIDCaptureManager?
    private weak var mappingStore: RemoteBindingStore?
    private weak var actionLibrary: RemoteLibraryStore?
    private weak var actionRunner: RemoteActionRunner?
    private weak var runtime: RemoteAppRuntime?
    private weak var lanRelay: RemoteLANRelayManager?
    private weak var transcriber: NativeVoiceTranscriber?
    private var cancellables: Set<AnyCancellable> = []
    private var isConfigured = false
    private var voiceStateMachine = VoiceSessionStateMachine()

    var onActionFeedback: ((String, RemoteKey?) -> Void)?

    func bindIfNeeded(
        bluetooth: RemoteBluetoothManager,
        hidCapture: HIDCaptureManager,
        mappingStore: RemoteBindingStore,
        actionLibrary: RemoteLibraryStore,
        actionRunner: RemoteActionRunner,
        runtime: RemoteAppRuntime,
        lanRelay: RemoteLANRelayManager,
        transcriber: NativeVoiceTranscriber? = nil
    ) {
        self.transcriber = transcriber
        guard !isConfigured else { return }
        isConfigured = true
        self.bluetooth = bluetooth
        self.hidCapture = hidCapture
        self.mappingStore = mappingStore
        self.actionLibrary = actionLibrary
        self.actionRunner = actionRunner
        self.runtime = runtime
        self.lanRelay = lanRelay

        // Migrate any historical v1 standalone `.script` bindings into unified Action Library entries
        mappingStore.migrateLegacyScriptBindingsIfNeeded(into: actionLibrary)

        runtime.startKeepingRemoteAlive(
            hidCapture,
            runner: actionRunner,
            bluetooth: bluetooth,
            lanRelay: lanRelay
        )
        actionRunner.onSwitchMacTarget = { [weak lanRelay] in
            lanRelay?.toggleTarget(showHUD: true)
        }

        hidCapture.$isExclusive
            .removeDuplicates()
            .sink { [weak lanRelay] isExclusive in
                lanRelay?.updateLocalHardwarePresence(isExclusive)
            }
            .store(in: &cancellables)

        wireBluetoothAndVoiceCallbacks()
        wirePhysicalHIDCallbacks()
        wireLANRelayReceiverAndSyncCallbacks()

        hidCapture.tryAutomaticCapture()
    }

    private func verifiedActiveHardwareModel() -> RemoteDeviceModel? {
        guard let mappingStore,
              let device = hidCapture?.currentDeviceIdentity,
              let model = RemoteDeviceProfileRegistry.identify(
                vendorID: device.vendorID,
                productID: device.productID,
                productName: device.productName
              ),
              model == mappingStore.activeModel else {
            return nil
        }
        return model
    }

    private func resolveHoldShortcut(
        for key: RemoteKey,
        in store: RemoteBindingStore,
        library: RemoteLibraryStore
    ) -> RemoteShortcut? {
        let action = store.action(for: key, gesture: .longPress)
        guard action.effectiveHoldMode == .physical else { return nil }
        if action.kind == .keyboardShortcut {
            return action.shortcut
        }
        if action.kind == .libraryAction,
           let steps = library.steps(for: action),
           steps.count == 1,
           steps[0].kind == .keyboard {
            return steps[0].shortcut
        }
        return nil
    }

    private func resolveVoiceAssistantShortcut(
        in store: RemoteBindingStore,
        library: RemoteLibraryStore
    ) -> RemoteShortcut? {
        for gesture in [RemoteGesture.longPress, .tap] {
            let action = store.action(for: .assistant, gesture: gesture)
            if let steps = library.steps(for: action),
               steps.count == 1,
               let first = steps.first,
               first.kind == .keyboard,
               let shortcut = first.shortcut {
                return shortcut
            }
        }
        return nil
    }

    private func wireBluetoothAndVoiceCallbacks() {
        guard let bluetooth, let hidCapture else { return }

        bluetooth.shouldRouteVoiceRemotely = { [weak self] in
            self?.lanRelay?.isForwardingToRemoteMac == true
        }
        bluetooth.onRemoteVoiceAudioStart = { [weak self] sampleRate in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let monitor = self.hidCapture,
                  let relay = self.lanRelay,
                  monitor.executeHardwareActions,
                  relay.isForwardingToRemoteMac else { return }
            let shortcut = self.resolveVoiceAssistantShortcut(in: store, library: library)
            _ = self.voiceStateMachine.beginLocalOrForwardedSession(
                forwardingToRemote: true,
                hasVoiceShortcut: shortcut != nil,
                trigger: monitor.doubaoShortcutTrigger
            )
            self.bluetooth?.virtualMicrophone.engageSpeakerEchoSuppression()
            relay.forwardVoiceStart(
                sampleRate: sampleRate,
                shortcut: shortcut,
                trigger: monitor.doubaoShortcutTrigger
            )
            self.onActionFeedback?(
                "语音转发至「\(relay.connectedPeerName ?? "远端 Mac")」",
                .assistant
            )
        }
        bluetooth.onRemoteVoiceSamples = { [weak self] samples, sampleRate in
            self?.lanRelay?.forwardVoicePCM(samples: samples, sampleRate: sampleRate)
        }
        bluetooth.onATVVControlReport = { [weak hidCapture] payload in
            hidCapture?.recordATVVControl(payload)
        }
        bluetooth.onATVVAudioEnded = { [weak hidCapture] in
            hidCapture?.endATVVVoiceSession()
        }

        hidCapture.onVoiceSessionStart = { [weak self] in
            guard let self,
                  let mappingStore = self.mappingStore,
                  let actionLibrary = self.actionLibrary,
                  let actionRunner = self.actionRunner,
                  let hidCapture = self.hidCapture else { return }

            let shortcut = self.resolveVoiceAssistantShortcut(in: mappingStore, library: actionLibrary)
            let isForwarding = (self.lanRelay?.isForwardingToRemoteMac == true)
            guard self.voiceStateMachine.beginLocalOrForwardedSession(
                forwardingToRemote: isForwarding,
                hasVoiceShortcut: shortcut != nil,
                trigger: hidCapture.doubaoShortcutTrigger
            ) else { return }

            if let relay = self.lanRelay, isForwarding {
                self.bluetooth?.virtualMicrophone.engageSpeakerEchoSuppression()
                let preferredRate = self.bluetooth?.preferredVoiceSampleRate ?? 8_000
                relay.forwardVoiceStart(
                    sampleRate: preferredRate,
                    shortcut: shortcut,
                    trigger: hidCapture.doubaoShortcutTrigger
                )
                self.onActionFeedback?(
                    "正在向「\(relay.connectedPeerName ?? "远端 Mac")」传送语音…",
                    .assistant
                )
                return
            }

            self.bluetooth?.virtualMicrophone.prepareVoiceInputWindow()
            if let shortcut {
                switch hidCapture.doubaoShortcutTrigger {
                case .tap:
                    actionRunner.tapVoiceShortcut(shortcut)
                case .hold:
                    actionRunner.beginVoiceShortcutHold(shortcut)
                }
                self.onActionFeedback?("已唤起语音热键 \(shortcut.display)", .assistant)
            } else {
                let tapAction = mappingStore.action(for: .assistant, gesture: .tap)
                guard tapAction.kind != .none else { return }
                actionRunner.test(
                    action: tapAction,
                    label: "实体语音助手 · ATVV",
                    library: actionLibrary
                )
                self.onActionFeedback?("已执行语音键绑定动作", .assistant)
            }
        }

        hidCapture.onVoiceSessionEnd = { [weak self] in
            guard let self else { return }
            let effect = self.voiceStateMachine.endLocalOrForwardedSession()
            if let relay = self.lanRelay, relay.isForwardingToRemoteMac {
                relay.forwardVoiceEnd()
            }
            switch effect {
            case .stopLocalVoice(let releaseHold, let restoreMic):
                if releaseHold { self.actionRunner?.endVoiceShortcutHold() }
                if restoreMic { self.bluetooth?.virtualMicrophone.scheduleVoiceInputRestoration() }
            case .stopForwardedVoice(let releaseHold, let releaseEcho):
                if releaseHold { self.actionRunner?.endVoiceShortcutHold() }
                if releaseEcho { self.bluetooth?.virtualMicrophone.scheduleSpeakerEchoSuppressionRelease() }
            case .finishIncomingRemoteVoice(let releaseHold, _, _):
                if releaseHold { self.actionRunner?.endVoiceShortcutHold() }
                self.bluetooth?.virtualMicrophone.scheduleVoiceInputRestoration()
            case .none:
                break
            }
        }
    }

    private func wirePhysicalHIDCallbacks() {
        guard let hidCapture else { return }

        hidCapture.longPressThresholdForKey = { [weak self] key in
            self?.mappingStore?.binding(for: key).effectiveThreshold ?? 0.65
        }

        hidCapture.shouldFollowPhysicalHold = { [weak self] key in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let model = self.verifiedActiveHardwareModel(),
                  model.keys.contains(key) else { return false }
            let action = store.action(for: key, gesture: .longPress)
            if action.kind == .systemAction && action.systemAction == .switchMacTarget {
                return false
            }
            if let relay = self.lanRelay,
               relay.isForwardingToRemoteMac,
               relay.dispatchMode == .receiverMapping {
                return key != .assistant
            }
            return self.resolveHoldShortcut(for: key, in: store, library: library) != nil
        }

        hidCapture.onMappedHoldStart = { [weak self] key in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let model = self.verifiedActiveHardwareModel() else {
                return false
            }
            let localShortcut = self.resolveHoldShortcut(for: key, in: store, library: library)
            if let relay = self.lanRelay, relay.isForwardingToRemoteMac {
                if relay.dispatchMode == .receiverMapping || localShortcut != nil {
                    let ok = relay.forwardHoldStart(key: key, senderModel: model, shortcut: localShortcut)
                    if ok {
                        self.onActionFeedback?(
                            "长按转发「\(key.title)」→ \(relay.connectedPeerName ?? "远端 Mac")",
                            key
                        )
                    }
                    return ok
                }
                return false
            }
            guard let localShortcut else { return false }
            let ok = self.actionRunner?.beginMappedShortcutHold(localShortcut, for: key) ?? false
            if ok {
                self.onActionFeedback?("按住「\(key.title)」→ \(localShortcut.display)", key)
            }
            return ok
        }

        hidCapture.onMappedHoldEnd = { [weak self] key in
            guard let self else { return }
            self.lanRelay?.forwardHoldEnd(key: key)
            self.actionRunner?.endMappedShortcutHold(for: key)
        }

        hidCapture.onAbortMappedActions = { [weak self] in
            self?.actionRunner?.cancelPendingMappedActions()
        }

        hidCapture.onMappedGesture = { [weak self] key, gesture in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let runner = self.actionRunner,
                  let model = self.verifiedActiveHardwareModel(),
                  model.keys.contains(key) else { return }

            let action = store.action(for: key, gesture: gesture)
            if action.kind == .systemAction && action.systemAction == .switchMacTarget {
                self.lanRelay?.toggleTarget(showHUD: true)
                self.onActionFeedback?("已切换双机控制目标", key)
                return
            }

            if let relay = self.lanRelay, relay.isForwardingToRemoteMac {
                relay.forwardMappedAction(
                    key: key,
                    gesture: gesture,
                    action: action,
                    senderModel: model,
                    library: library
                )
                self.onActionFeedback?(
                    "已转发「\(key.title) · \(gesture.title)」→ \(relay.connectedPeerName ?? "远端 Mac")",
                    key
                )
                return
            }

            guard action.kind != .none else { return }
            let summary = library.description(for: action)
            runner.enqueueMappedAction(
                action,
                label: "实体\(key.title) · \(gesture.title)",
                library: library
            )
            self.onActionFeedback?("已触发「\(key.title) · \(gesture.title)」：\(summary)", key)
        }
    }

    private func wireLANRelayReceiverAndSyncCallbacks() {
        guard let lanRelay else { return }

        lanRelay.onReleaseLocalHoldsBeforeSwitch = { [weak self] in
            self?.voiceStateMachine.reset()
            self?.actionRunner?.cancelPendingMappedActions()
            self?.actionRunner?.endMappedShortcutHold()
            self?.actionRunner?.endVoiceShortcutHold()
            self?.bluetooth?.virtualMicrophone.scheduleSpeakerEchoSuppressionRelease()
        }

        lanRelay.onExportLocalConfig = { [weak self] in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let relay = self.lanRelay else { return nil }
            return store.exportSyncSnapshot(
                peerName: relay.localPeerName,
                library: library,
                learnedHIDProfile: self.hidCapture?.exportLearnedProfile()
            )
        }

        lanRelay.onApplySyncedConfig = { [weak self] snapshot, strategy in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary else { return nil }
            let result = store.applySyncedSnapshot(
                snapshot,
                strategy: strategy,
                library: library,
                onRestoreHIDProfile: { [weak self] profile in
                    self?.hidCapture?.applyImportedLearnedProfile(profile) ?? 0
                }
            )
            if self.lanRelay?.suppressPromptWindowsForTesting != true {
                RemoteSwitchHUDController.shared.show(
                    title: strategy == .merge ? "已完成合并同步" : "已完成覆盖同步",
                    subtitle: "来自「\(snapshot.sourcePeerName)」· 更新 \(result.updatedKeyGestureCount) 项动作",
                    symbol: "arrow.triangle.2.circlepath.circle.fill",
                    tint: RemotePalette.positive
                )
            }
            return result
        }

        lanRelay.onIncomingAction = { [weak self] key, gesture, mode, _, shortcut, holdSeconds, systemAction, forwardedSteps in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let runner = self.actionRunner else { return }

            let label = "局域网远端 · \(key.title)（\(gesture.title)）"
            if mode == .receiverMapping {
                let localAction = store.action(for: key, gesture: gesture)
                guard localAction.kind != .none else { return }
                runner.enqueueMappedAction(localAction, label: label, library: library)
                self.onActionFeedback?("收到远端「\(key.title)」→ \(library.description(for: localAction))", key)
                return
            }

            if let systemAction, systemAction != .switchMacTarget {
                let action = RemoteAction(kind: .systemAction, systemAction: systemAction)
                runner.enqueueMappedAction(action, label: label, library: library)
                self.onActionFeedback?("收到远端「\(key.title)」→ \(systemAction.title)", key)
            } else if let forwardedSteps, !forwardedSteps.isEmpty {
                let steps = forwardedSteps.map { $0.toActionStep() }
                runner.enqueueForwardedSteps(steps, label: label, library: library)
                self.onActionFeedback?("收到远端多步动作「\(key.title)」", key)
            } else if let shortcut {
                let action = RemoteAction(
                    kind: .keyboardShortcut,
                    shortcut: shortcut,
                    outputHoldSeconds: holdSeconds
                )
                runner.enqueueMappedAction(action, label: label, library: library)
                self.onActionFeedback?("收到远端「\(key.title)」→ \(shortcut.display)", key)
            }
        }

        lanRelay.onIncomingHoldStart = { [weak self] key, mode, _, senderShortcut in
            guard let self,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let runner = self.actionRunner else { return }
            if mode == .receiverMapping {
                if let localHoldShortcut = self.resolveHoldShortcut(for: key, in: store, library: library) {
                    _ = runner.beginMappedShortcutHold(localHoldShortcut, for: key)
                } else {
                    let localLongPress = store.action(for: key, gesture: .longPress)
                    if localLongPress.kind != .none {
                        runner.enqueueMappedAction(
                            localLongPress,
                            label: "局域网远端 · \(key.title)（长按）",
                            library: library
                        )
                    }
                }
                return
            }
            if let senderShortcut {
                _ = runner.beginMappedShortcutHold(senderShortcut, for: key)
            }
        }

        lanRelay.onIncomingHoldEnd = { [weak self] key in
            self?.actionRunner?.endMappedShortcutHold(for: key)
        }

        lanRelay.onIncomingVoiceStart = { [weak self] sampleRate, mode, senderShortcut, senderTrigger in
            guard let self,
                  let bluetooth = self.bluetooth,
                  let store = self.mappingStore,
                  let library = self.actionLibrary,
                  let runner = self.actionRunner,
                  let monitor = self.hidCapture else { return }

            bluetooth.beginRemoteIncomingVoice(
                sampleRate: sampleRate,
                peerName: self.lanRelay?.controllingPeerName ?? self.lanRelay?.connectedPeerName
            )
            let hasVirtualMic = bluetooth.virtualMicrophone.ensureReadyForIncomingRemoteVoice()
            let localShortcut = self.resolveVoiceAssistantShortcut(in: store, library: library)
            let targetShortcut = mode == .receiverMapping
                ? (localShortcut ?? senderShortcut)
                : (senderShortcut ?? localShortcut)
            let trigger = mode == .receiverMapping ? monitor.doubaoShortcutTrigger : senderTrigger

            self.voiceStateMachine.beginIncomingRemoteSession(
                hasVirtualMic: hasVirtualMic,
                hasTargetShortcut: targetShortcut != nil,
                trigger: trigger
            )

            if hasVirtualMic, let targetShortcut {
                bluetooth.virtualMicrophone.prepareVoiceInputWindow()
                bluetooth.virtualMicrophone.beginSession(sourceRate: sampleRate)
                switch trigger {
                case .tap:
                    runner.tapVoiceShortcut(targetShortcut)
                case .hold:
                    runner.beginVoiceShortcutHold(targetShortcut)
                }
            } else {
                bluetooth.virtualMicrophone.engageSpeakerEchoSuppression()
                if hasVirtualMic {
                    bluetooth.virtualMicrophone.beginSession(sourceRate: sampleRate)
                }
                if self.lanRelay?.suppressPromptWindowsForTesting != true {
                    RemoteSwitchHUDController.shared.show(
                        title: "正在接收远端遥控器语音…",
                        subtitle: hasVirtualMic
                            ? "未绑定语音快捷键，松开后将调用本机语音识别自动上屏"
                            : "本机未装 BlackHole 2ch，松开后将自动本地语音转文字输入",
                        symbol: "waveform.circle.fill",
                        tint: RemotePalette.indigo
                    )
                }
            }
        }

        lanRelay.onIncomingVoicePCM = { [weak self] samples, sampleRate in
            guard let self, let bluetooth = self.bluetooth else { return }
            bluetooth.appendRemoteIncomingVoice(samples: samples, sampleRate: sampleRate)
            bluetooth.virtualMicrophone.write(samples: samples, sampleRate: sampleRate)
        }

        lanRelay.onIncomingVoiceEnd = { [weak self] in
            guard let self, let bluetooth = self.bluetooth else { return }
            let effect = self.voiceStateMachine.endIncomingRemoteSession(
                recordedSamples: bluetooth.recordedSampleCount
            )
            if case .finishIncomingRemoteVoice(let releaseHold, let drainMic, let shouldTranscribe) = effect {
                if releaseHold {
                    self.actionRunner?.endVoiceShortcutHold()
                }
                if drainMic {
                    bluetooth.virtualMicrophone.endSessionGracefully()
                }
                bluetooth.virtualMicrophone.scheduleVoiceInputRestoration()
                bluetooth.endRemoteIncomingVoice()

                if shouldTranscribe,
                   let wav = bluetooth.waveFileData(),
                   let transcriber = self.transcriber {
                    transcriber.recognize(
                        waveData: wav,
                        onFinalTranscript: { [weak self] recognizedText in
                            self?.actionRunner?.insertRecognizedText(recognizedText)
                            if self?.lanRelay?.suppressPromptWindowsForTesting != true {
                                RemoteSwitchHUDController.shared.show(
                                    title: "远端语音已识别输入",
                                    subtitle: recognizedText,
                                    symbol: "checkmark.bubble.fill",
                                    tint: RemotePalette.positive
                                )
                            }
                        },
                        onFailure: { [weak self] reason in
                            if self?.lanRelay?.suppressPromptWindowsForTesting != true {
                                RemoteSwitchHUDController.shared.show(
                                    title: "远端语音已接收（未自动上屏）",
                                    subtitle: reason,
                                    symbol: "exclamationmark.bubble.fill",
                                    tint: RemotePalette.amber
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}
