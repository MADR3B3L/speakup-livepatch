import Foundation
import Speech
import AVFoundation

/// Milestone 2A, step 1-3: capture microphone audio via AVAudioEngine and
/// stream it to SFSpeechRecognizer for live transcription. This class does
/// NOT touch the AX write engine — results are only handed back via
/// `onResult` so the caller can log them. Routing transcripts into
/// AccessibilityInspector.insertTextAtCursor is a later step.
final class SpeechCapture: NSObject {
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Called for every partial/final transcription update.
    var onResult: ((String, Bool) -> Void)?
    /// Called on any *unexpected* recognizer/engine error. Normal
    /// end-of-task errors (kAFAssistantErrorDomain code 216, which fires
    /// every time `stop()`/`cancel()` ends a task) are swallowed here.
    var onError: ((String) -> Void)?

    /// The most recent transcription (partial or final) seen this session.
    /// This is the "commit" value used on stop/release, since `isFinal`
    /// is not reliably delivered before a task is cancelled.
    private(set) var lastTranscript: String = ""

    var isRunning: Bool {
        audioEngine.isRunning
    }

    static func authorizationStatusDescription() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    /// Starts streaming mic audio into the recognizer. Throws if the
    /// recognizer is unavailable or the audio engine fails to start.
    func start() throws {
        // Tear down any previous session first.
        stop()

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw "Speech recognizer unavailable for this locale/device."
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        lastTranscript = ""

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.lastTranscript = result.bestTranscription.formattedString
                self.onResult?(self.lastTranscript, result.isFinal)
            }
            if let error = error {
                let nsError = error as NSError
                // kAFAssistantErrorDomain code 216 = "no speech detected /
                // task ended" — this fires on EVERY normal stop()/cancel(),
                // so it's not an error worth surfacing.
                let isNormalEndOfTask = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216
                if !isNormalEndOfTask {
                    self.onError?(error.localizedDescription)
                }
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stops audio capture and cancels any in-flight recognition task.
    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }
}
