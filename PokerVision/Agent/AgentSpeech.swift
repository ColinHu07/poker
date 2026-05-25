import AVFoundation
import Foundation
import Speech

/// What the speech subsystem can tell the UI.
enum SpeechAvailability: Equatable {
    case available
    case micPermissionDenied
    case speechPermissionDenied
    case notSupportedOnDevice
    case unknownError(String)
}

protocol SpeechServiceDelegate: AnyObject {
    func speechService(_ service: SpeechService, didUpdatePartial text: String)
    func speechService(_ service: SpeechService, didFinishWith text: String?)
    func speechService(_ service: SpeechService, didFailWith error: Error)
}

/// Speech recognizer with built-in silence-based auto-finalize.
///
/// Lifecycle: caller invokes `start()`, and the service auto-stops itself
/// after `silenceTimeout` seconds of "silence" (no partial updates AND input
/// audio level under a small threshold). Call `stop()` or `cancel()` to end
/// early.
///
/// The "no speech detected" family of SFSpeech errors (code 1110 / 203) is
/// filtered out so the UI never shows them — when silence fires with no
/// transcript, the delegate simply receives `didFinishWith: nil`.
@MainActor
final class SpeechService: NSObject {
    weak var delegate: SpeechServiceDelegate?

    /// Finalize after this many seconds with no detected speech activity.
    var silenceTimeout: TimeInterval = 2.0
    /// RMS level above this counts as "speech activity" (roughly -40 dBFS).
    var audioLevelThreshold: Float = 0.012

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRunning: Bool = false
    private var lastPartial: String = ""

    private var silenceTimer: Timer?
    private var lastAudioActivityAt: Date?
    private var didEmitFinish: Bool = false

    override init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    // MARK: - Permissions

    /// Request both Speech and Mic permissions. Returns the resulting availability.
    func requestPermissions() async -> SpeechAvailability {
        guard recognizer?.isAvailable == true else {
            return .notSupportedOnDevice
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation {
            cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return .speechPermissionDenied
        }

        let micGranted: Bool = await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        return micGranted ? .available : .micPermissionDenied
    }

    func currentAvailability() -> SpeechAvailability {
        guard recognizer?.isAvailable == true else { return .notSupportedOnDevice }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            return .speechPermissionDenied
        }
        let micStatus: AVAudioSession.RecordPermission
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: micStatus = .granted
            case .denied: micStatus = .denied
            case .undetermined: micStatus = .undetermined
            @unknown default: micStatus = .undetermined
            }
        } else {
            micStatus = AVAudioSession.sharedInstance().recordPermission
        }
        if micStatus != .granted { return .micPermissionDenied }
        return .available
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "SpeechService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
            [weak self, weak req] buffer, _ in
            req?.append(buffer)
            let level = SpeechService.rms(of: buffer)
            if let self {
                Task { @MainActor in self.handleAudioLevel(level) }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        lastPartial = ""
        lastAudioActivityAt = Date()
        didEmitFinish = false
        isRunning = true
        NSLog("[Speech] start (silenceTimeout=%.1fs)", silenceTimeout)
        armSilenceTimer()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.lastPartial = text
                    self.delegate?.speechService(self, didUpdatePartial: text)
                    // Any new partial counts as speech activity — reset silence.
                    self.resetSilenceClock()
                }
                if result.isFinal {
                    Task { @MainActor in self.finalize(reason: "isFinal", text: text) }
                }
            }
            if let error {
                Task { @MainActor in self.handleRecognitionError(error) }
            }
        }
    }

    /// Stop cleanly and submit whatever we have (silence / user request).
    func stop() {
        guard isRunning else { return }
        NSLog("[Speech] stop (lastPartial=\"%@\")", lastPartial)
        finalize(reason: "stop", text: lastPartial)
    }

    /// Stop without submitting (explicit cancel).
    func cancel() {
        guard isRunning else { return }
        NSLog("[Speech] cancel")
        teardownAudio()
        isRunning = false
        if !didEmitFinish {
            didEmitFinish = true
            let d = self.delegate
            Task { @MainActor in d?.speechService(self, didFinishWith: nil) }
        }
    }

    // MARK: - Silence / VAD

    private func handleAudioLevel(_ level: Float) {
        if level >= audioLevelThreshold {
            resetSilenceClock()
        }
    }

    private func resetSilenceClock() {
        lastAudioActivityAt = Date()
        armSilenceTimer()
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceTimeout, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.onSilenceTimerFired() }
        }
    }

    private func onSilenceTimerFired() {
        guard isRunning, !didEmitFinish else { return }
        NSLog("[Speech] silence timer fired — finalizing (partial=\"%@\")", lastPartial)
        finalize(reason: "silence", text: lastPartial)
    }

    // MARK: - Finalize / error handling

    private func finalize(reason: String, text: String) {
        guard isRunning, !didEmitFinish else { return }
        didEmitFinish = true
        NSLog("[Speech] finalize reason=%@ text=\"%@\"", reason, text)
        teardownAudio()
        isRunning = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = self.delegate
        Task { @MainActor in
            d?.speechService(self, didFinishWith: trimmed.isEmpty ? nil : trimmed)
        }
    }

    private func teardownAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func handleRecognitionError(_ error: Error) {
        let ns = error as NSError
        let isNoSpeech =
            (ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203))
            || (ns.domain == SFSpeechErrorDomain && (ns.code == 1110 || ns.code == 203))
        if isNoSpeech {
            NSLog(
                "[Speech] no-speech (%@, %d) — silently finalizing as empty",
                ns.domain, ns.code)
            finalize(reason: "no-speech", text: "")
            return
        }
        // Other errors: tell delegate, let it decide whether to flip to dev mode.
        let d = self.delegate
        Task { @MainActor in d?.speechService(self, didFailWith: error) }
    }

    // MARK: - Utility

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channelData[i]
            sum += s * s
        }
        return sqrt(sum / Float(frameLength))
    }
}
