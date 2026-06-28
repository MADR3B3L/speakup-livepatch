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

    /// Rolling average audio power in dB. Updated every buffer (~23ms).
    /// Typical values: -50 dB = silence, -30 dB = ambient, -15 dB = speaking nearby, -5 dB = speaking directly.
    private(set) var currentPowerLevel: Float = -160

    /// Minimum power level to consider audio as intentional speech.
    /// Below this, transcriptions are tagged as likely ambient.
    var volumeGateThreshold: Float = -45

    /// Whether the most recent audio buffer was above the volume gate.
    private(set) var isAboveVolumeGate: Bool = false

    /// Peak power seen during the current recognition session.
    private(set) var sessionPeakPower: Float = -160

    /// Adaptive gate: rolling ambient noise floor, updated every buffer.
    private var ambientSamples: [Float] = []
    private static let ambientWindowSize = 50
    private static let ambientMargin: Float = 15
    private(set) var ambientFloor: Float = -50
    var adaptiveGateEnabled: Bool = true

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
        request.taskHint = .search
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = [
            "mac", "max", "action", "media", "display", "capture", "report",
            "open", "close", "quit", "hide", "show", "prepare", "search", "find",
            "notes", "chrome", "safari", "finder", "mail", "calendar", "music",
            "reminders", "messages", "photos", "maps", "terminal", "claude",
            "copy", "paste", "cut", "undo", "redo", "save", "select", "delete",
            "insert", "type", "dictate",
            "next", "previous", "back", "forward", "tab",
            "play", "pause", "mute", "unmute", "volume",
            "brightness", "screenshot", "spotlight", "lock",
            "minimize", "fullscreen", "focus", "work with",
            "note", "reminder", "bug", "issue", "feedback",
            "send", "buffer", "codex", "veq",
            "bold", "italic", "checklist",
            "new tab", "close tab", "reload", "bookmark", "history",
            "duplicate", "preferences", "settings",
        ]
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
        sessionPeakPower = -160
        ambientSamples = []
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / max(Float(frameCount), 1))
            let db = 20 * log10(max(rms, 1e-10))
            self.currentPowerLevel = db
            if self.adaptiveGateEnabled {
                self.ambientSamples.append(db)
                if self.ambientSamples.count > Self.ambientWindowSize {
                    self.ambientSamples.removeFirst()
                }
                if self.ambientSamples.count >= 10 {
                    let sorted = self.ambientSamples.sorted()
                    let lower = sorted[sorted.count / 4]
                    self.ambientFloor = lower
                    self.volumeGateThreshold = lower + Self.ambientMargin
                }
            }
            self.isAboveVolumeGate = db > self.volumeGateThreshold
            if db > self.sessionPeakPower {
                self.sessionPeakPower = db
            }
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
