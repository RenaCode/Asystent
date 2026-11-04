import Foundation
import Observation

/// Stan jednej rozmowy: słuchanie → agent → mówienie.
@MainActor
@Observable
final class AssistantSession: ActionConfirmer {
    static let shared = AssistantSession()

    enum Phase: Equatable { case idle, listening, thinking, speaking, confirming(String), error(String) }

    struct Line: Identifiable {
        enum Role { case user, assistant }
        let id = UUID(); let role: Role; let text: String
    }

    var phase: Phase = .idle
    var transcript = ""
    var lines: [Line] = []
    /// Pokazuje ekran ujawnienia i zgody (5.1.2(i)); ustawiane, gdy ktoś chce zacząć bez zgody.
    var needsConsent = false

    private let recognizer = SpeechRecognizer()
    private let speaker = Speaker()
    @ObservationIgnored private var agent: AgentLoop!
    @ObservationIgnored private(set) var settings = AssistantSettings()
    @ObservationIgnored private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var confirmationTimeout: Task<Void, Never>?

    init() { reloadSettings() }

    /// Po zmianie trybu/klucza w Ustawieniach zaczynamy nową rozmowę z nowym klientem.
    func reloadSettings() {
        cancelPendingConfirmation()
        // Tura starego klienta, która jeszcze trwa, kończy się bez wpisu do nowej rozmowy.
        agent?.reset()
        settings = AssistantSettings()
        agent = AgentLoop(client: settings.makeClient(), registry: .default, confirmer: self)
        lines.removeAll()
        phase = .idle
    }

    var hasConsent: Bool { settings.consent.isGranted }

    func grantConsent() { settings.consent.grant(); needsConsent = false }

    func revokeConsent() { settings.consent.revoke() }

    func startListening() async {
        guard phase != .listening, phase != .thinking else { return }
        // W czasie pytania o potwierdzenie mikrofon już słucha odpowiedzi „tak”/„nie”
        // (Back Tap, Siri i kontrolka wołają tę metodę niezależnie od przycisków).
        if case .confirming = phase { return }
        guard hasConsent else { needsConsent = true; return }
        speaker.stop()
        transcript = ""
        phase = .listening
        do {
            try await recognizer.requestAuthorization()
            try recognizer.start { [weak self] partial in
                Task { @MainActor in self?.transcript = partial }
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func stopListeningAndSend() async {
        let text = recognizer.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; return }
        await send(text)
    }

    func send(_ text: String) async {
        guard phase != .thinking else { return }
        // Wpisane „tak”/„nie” w czasie pytania o potwierdzenie to odpowiedź na nie,
        // a nie nowe polecenie (pętla agenta wciąż czeka na wynik narzędzia).
        if case .confirming = phase {
            if let answer = ConfirmationParser.parse(text) { answerConfirmation(answer) }
            return
        }
        guard hasConsent else { needsConsent = true; return }
        lines.append(.init(role: .user, text: text))
        phase = .thinking
        do {
            let reply = try await agent.run(userText: text)
            lines.append(.init(role: .assistant, text: reply))
            phase = .speaking
            await speaker.speak(reply)
            // Mowę mógł przerwać mikrofon (startListening): wtedy faza to już .listening
            // i nie wolno jej nadpisać, bo przycisk pokazałby „słuchaj” przy włączonym nagrywaniu.
            if phase == .speaking { phase = .idle }
        } catch is CancellationError {
            // Tura z rozmowy porzuconej przez Reset — Reset ustawił już stan.
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func reset() { cancelPendingConfirmation(); agent.reset(); lines.removeAll(); phase = .idle }

    /// Reset albo zmiana Ustawień w czasie pytania o potwierdzenie: odpowiedź „nie” bez śladu
    /// w rozmowie. Inaczej po 15 s limit czasu zatrzymałby mikrofon nowego nasłuchu
    /// i przestawił fazę na „myślę”.
    private func cancelPendingConfirmation() {
        guard let c = pendingConfirmation else { return }
        pendingConfirmation = nil
        confirmationTimeout?.cancel()
        recognizer.stop()
        c.resume(returning: false)
    }

    // MARK: - Potwierdzenie akcji destrukcyjnych

    /// Pyta głosem i czeka na „tak”/„nie” (głos lub przyciski). Cisza = odmowa.
    func confirm(_ question: String) async -> Bool {
        lines.append(.init(role: .assistant, text: question))
        await speaker.speak(question)
        phase = .confirming(question)
        transcript = ""

        return await withCheckedContinuation { c in
            pendingConfirmation = c
            confirmationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.answerConfirmation(false)
            }
            do {
                try recognizer.start { [weak self] partial in
                    Task { @MainActor in
                        guard let self else { return }
                        self.transcript = partial
                        if let answer = ConfirmationParser.parse(partial) { self.answerConfirmation(answer) }
                    }
                }
            } catch {
                // Bez mikrofonu (np. symulator) zostają przyciski Tak/Nie.
            }
        }
    }

    func answerConfirmation(_ answer: Bool) {
        guard let c = pendingConfirmation else { return }
        pendingConfirmation = nil
        confirmationTimeout?.cancel()
        recognizer.stop()
        lines.append(.init(role: .user, text: answer ? String(localized: "Yes") : String(localized: "No")))
        phase = .thinking
        c.resume(returning: answer)
    }
}
