import AVFoundation
import Speech

/// STT w języku interfejsu (pl-PL albo en-US). Preferuje rozpoznawanie on-device, jeśli dostępne.
final class SpeechRecognizer: @unchecked Sendable {
    enum SpeechError: LocalizedError {
        case notAuthorized, unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: String(localized: "Microphone or speech recognition permission is missing.")
            case .unavailable: String(localized: "Speech recognition is unavailable for this language.")
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: VoiceLocale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""

    func requestAuthorization() async throws {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else { throw SpeechError.notAuthorized }
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        // Drugi `installTap` na tej samej szynie rzuca wyjątek i wywraca apkę — sprzątamy
        // poprzedni nasłuch, także ten, który padł w połowie startu (np. `engine.start()`).
        stop()
        latest = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch { stop(); throw error }

        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            self?.latest = text
            onPartial(text)
        }
    }

    /// Zatrzymuje nasłuch i zwraca ostatnią transkrypcję.
    @discardableResult
    func stop() -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        return latest
    }
}
