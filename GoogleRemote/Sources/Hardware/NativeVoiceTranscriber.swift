import Combine
import Foundation
import Speech

/// Explicit opt-in or LAN-fallback local transcription of a decoded WAV recording.
/// Never opens the Mac physical microphone and never falls back to a cloud recognizer.
@MainActor
final class NativeVoiceTranscriber: ObservableObject {
    @Published var transcript = ""
    @Published private(set) var status = "录音完成后可使用 macOS 本地语音识别"
    @Published private(set) var isProcessing = false
    @Published var language = "zh-CN"

    private var recognitionTask: SFSpeechRecognitionTask?
    private var tempRecordingURL: URL?
    private var activeRequest = UUID()

    func recognize(
        waveData: Data,
        onFinalTranscript: ((String) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) {
        if isProcessing {
            cancel()
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            performRecognition(
                waveData: waveData,
                onFinalTranscript: onFinalTranscript,
                onFailure: onFailure
            )
        case .notDetermined:
            status = "等待系统语音识别授权"
            SFSpeechRecognizer.requestAuthorization { [weak self] permission in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if permission == .authorized {
                        self.performRecognition(
                            waveData: waveData,
                            onFinalTranscript: onFinalTranscript,
                            onFailure: onFailure
                        )
                    } else {
                        let msg = "未授权本地语音识别（可在「权限引导」开启，或安装 BlackHole 2ch 配合豆包使用）"
                        self.status = msg
                        onFailure?(msg)
                    }
                }
            }
        default:
            let msg = "本地语音识别权限未开启（请到「权限引导」开启，或安装 BlackHole 2ch 配合豆包使用）"
            status = msg
            onFailure?(msg)
        }
    }

    func cancel() {
        activeRequest = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        cleanup()
        isProcessing = false
        status = "已取消识别"
    }

    private func performRecognition(
        waveData: Data,
        onFinalTranscript: ((String) -> Void)?,
        onFailure: ((String) -> Void)?
    ) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            let msg = "macOS 不支持此识别语言"
            status = msg
            onFailure?(msg)
            return
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            let msg = "本机缺少离线听写语音资源（可在系统键盘听写设置下载，或安装 BlackHole 2ch 配合豆包使用）"
            status = msg
            onFailure?(msg)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleRemote-\(UUID().uuidString).wav")
        do {
            try waveData.write(to: url, options: .atomic)
        } catch {
            let msg = "无法准备待识别录音：\(error.localizedDescription)"
            status = msg
            onFailure?(msg)
            return
        }

        recognitionTask?.cancel()
        cleanup()
        activeRequest = UUID()
        let requestID = activeRequest
        tempRecordingURL = url
        transcript = ""
        status = "正在调用 macOS 本地引擎识别远端语音…"
        isProcessing = true

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isProcessing, self.activeRequest == requestID else { return }
                if let result {
                    let formatted = result.bestTranscription.formattedString
                    self.transcript = formatted
                    if result.isFinal {
                        self.status = "识别完成（本地）"
                        self.isProcessing = false
                        self.recognitionTask = nil
                        self.cleanup()
                        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onFinalTranscript?(trimmed)
                        } else {
                            onFailure?("未识别到清晰语音内容")
                        }
                    }
                }
                if let error, self.isProcessing {
                    let msg = "本地识别未检出语音：\(error.localizedDescription)"
                    self.status = msg
                    self.isProcessing = false
                    self.recognitionTask = nil
                    self.cleanup()
                    onFailure?(msg)
                }
            }
        }
    }

    private func cleanup() {
        if let tempRecordingURL { try? FileManager.default.removeItem(at: tempRecordingURL) }
        tempRecordingURL = nil
    }
}
