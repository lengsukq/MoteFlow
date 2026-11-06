import Combine
import Foundation
import Speech

/// Explicit opt-in transcription of an already-decoded WAV recording.
/// This service never opens the Mac microphone and never falls back to a network recognizer.
@MainActor
final class NativeVoiceTranscriber: ObservableObject {
    @Published var transcript = ""
    @Published private(set) var status = "录音完成后可使用 macOS 本地语音识别"
    @Published private(set) var isProcessing = false
    @Published var language = "zh-CN"

    private var recognitionTask: SFSpeechRecognitionTask?
    private var tempRecordingURL: URL?
    private var activeRequest = UUID()

    func recognize(waveData: Data) {
        guard !isProcessing else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            performRecognition(waveData: waveData)
        case .notDetermined:
            status = "等待系统语音识别授权"
            SFSpeechRecognizer.requestAuthorization { [weak self] permission in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if permission == .authorized {
                        self.performRecognition(waveData: waveData)
                    } else {
                        self.status = "未获得语音识别权限，请到系统设置 → 隐私与安全性 → 语音识别授权"
                    }
                }
            }
        default:
            status = "语音识别权限被拒绝，请到系统设置 → 隐私与安全性 → 语音识别授权"
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

    private func performRecognition(waveData: Data) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            status = "macOS 不支持此识别语言"
            return
        }
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            status = "本机缺少该语言的离线识别能力；请检查系统语言/听写资源。未尝试在线识别。"
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleRemote-\(UUID().uuidString).wav")
        do {
            try waveData.write(to: url, options: .atomic)
        } catch {
            status = "无法准备待识别录音：\(error.localizedDescription)"
            return
        }

        recognitionTask?.cancel()
        cleanup()
        activeRequest = UUID()
        let requestID = activeRequest
        tempRecordingURL = url
        transcript = ""
        status = "使用 macOS 本地语音识别中…"
        isProcessing = true

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isProcessing, self.activeRequest == requestID else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.status = "识别完成（本地）"
                        self.isProcessing = false
                        self.recognitionTask = nil
                        self.cleanup()
                    }
                }
                if let error, self.isProcessing {
                    self.status = "本地识别失败：\(error.localizedDescription)"
                    self.isProcessing = false
                    self.recognitionTask = nil
                    self.cleanup()
                }
            }
        }
    }

    private func cleanup() {
        if let tempRecordingURL { try? FileManager.default.removeItem(at: tempRecordingURL) }
        tempRecordingURL = nil
    }
}
