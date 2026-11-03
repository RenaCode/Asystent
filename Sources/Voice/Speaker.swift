import AVFoundation

/// TTS w języku interfejsu. Wybiera najlepszy dostępny głos (premium > enhanced > default).
/// Głosy premium: Ustawienia → Dostępność → Treść mówiona → Głosy.
/// Argument uruchomienia `-mute` wyłącza mowę (testy, symulator).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    static let isMuted = ProcessInfo.processInfo.arguments.contains("-mute")

    private lazy var voice: AVSpeechSynthesisVoice? = {
        let lang = VoiceLocale.current.identifier(.bcp47)
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        return matching.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: lang)
    }()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        guard !Self.isMuted else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        await withCheckedContinuation { c in
            continuation = c
            synth.speak(u)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
