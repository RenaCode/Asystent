import Foundation

/// Potwierdzenie akcji destrukcyjnej przez użytkownika (w apce: pytanie głosem + „tak”/„nie”).
@MainActor
protocol ActionConfirmer: AnyObject {
    func confirm(_ question: String) async -> Bool
}

/// Pętla tool use: wysyła rozmowę, wykonuje lokalnie żądane narzędzia, odsyła wyniki,
/// aż Claude zwróci zwykłą odpowiedź tekstową.
///
/// Historia jest wyłącznie dopisywana (append-only), a prompt systemowy zamrożony na czas
/// rozmowy — bloki `thinking` są związane z prefiksem rozmowy i każda jego edycja je unieważnia.
/// Bieżąca godzina idzie więc w wiadomości użytkownika, nie w prompcie systemowym.
@MainActor
final class AgentLoop {
    private let client: any LLMClient
    private let registry: ToolRegistry
    private weak var confirmer: (any ActionConfirmer)?
    private let now: @Sendable () -> Date
    private(set) var history: [Message] = []
    private var system: String
    let maxSteps = 8
    /// Numer rozmowy: `reset()` go podbija, więc tura sprzed Resetu wie, że jej wynik
    /// należy do porzuconej rozmowy i nie może dotykać nowej historii.
    private var generation = 0
    /// Rozmowa (`generation`), której tura właśnie trwa; `nil` = żadna.
    private var runningGeneration: Int?

    init(client: any LLMClient, registry: ToolRegistry, confirmer: (any ActionConfirmer)? = nil,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.client = client
        self.registry = registry
        self.confirmer = confirmer
        self.now = now
        self.system = Self.systemPrompt()
    }

    func reset() {
        generation += 1
        history.removeAll()
        system = Self.systemPrompt()
    }

    func run(userText: String) async throws -> String {
        // Jedna tura naraz: druga przeplatałaby historię (np. `tool_use` bez `tool_result`).
        guard runningGeneration != generation else { throw AgentError.busy }
        let gen = generation
        runningGeneration = gen
        defer { if runningGeneration == gen { runningGeneration = nil } }
        let checkpoint = history.count
        /// Po Resecie w trakcie tury historia jest już pusta i należy do nowej rozmowy.
        func ensureCurrent() throws { guard generation == gen else { throw CancellationError() } }
        func rollBack() { if generation == gen { history.removeSubrange(checkpoint...) } }

        history.append(Message(role: "user", content: [
            .text("[\(String(localized: "Current time")): \(now().formatted(Date.ISO8601FormatStyle(timeZone: .current)))]"),
            .text(userText),
        ]))

        do {
            for _ in 0..<maxSteps {
                let resp = try await client.send(.init(system: system, messages: history, tools: registry.specs))
                try ensureCurrent()

                switch resp.stop_reason {
                case "tool_use":
                    let calls = resp.content.filter { $0.type == "tool_use" }
                    guard !calls.isEmpty else { throw AgentError.malformedResponse }
                    history.append(Message(role: "assistant", content: resp.content))
                    let results = await runTools(calls)
                    try ensureCurrent()
                    history.append(Message(role: "user", content: results))

                case "end_turn", "stop_sequence":
                    history.append(Message(role: "assistant", content: resp.content))
                    let text = Self.text(of: resp)
                    return text.isEmpty ? Replies.empty : text

                case "pause_turn":
                    // Serwer przerwał długą turę — odsyłamy ją bez zmian, żeby dokończył.
                    history.append(Message(role: "assistant", content: resp.content))

                case "refusal":
                    // Odmowa (także po fallbacku): treść może być częściowa — nie czytamy jej
                    // i wycofujemy całą turę, żeby nie zostawić jej w historii.
                    rollBack()
                    return Replies.refusal

                case "max_tokens", "model_context_window_exceeded":
                    // Ucięta odpowiedź: niedokończonych wywołań narzędzi nie wykonujemy.
                    rollBack()
                    let text = Self.text(of: resp)
                    return text.isEmpty ? Replies.truncated : text

                default:
                    throw AgentError.unexpectedStopReason(resp.stop_reason ?? "nil")
                }
            }
        } catch {
            rollBack()
            throw error
        }
        rollBack()
        return Replies.tooManySteps
    }

    /// Wszystkie wyniki trafiają do JEDNEJ wiadomości użytkownika, w kolejności wywołań.
    private func runTools(_ calls: [ContentBlock]) async -> [ContentBlock] {
        var results: [ContentBlock] = []
        for call in calls {
            guard let id = call.id else { continue }
            let name = call.name ?? ""
            let input = call.input ?? .object([:])
            guard let tool = registry.tool(named: name) else {
                results.append(.toolResult(id: id, content: "Unknown tool \(name)", isError: true))
                continue
            }
            if let question = tool.confirmationQuestion(for: input) {
                let ok = await confirmer?.confirm(question) ?? false
                guard ok else {
                    results.append(.toolResult(id: id, content: "User did not confirm. Action cancelled; do not retry.", isError: true))
                    continue
                }
            }
            do {
                results.append(.toolResult(id: id, content: try await tool.run(input)))
            } catch {
                results.append(.toolResult(id: id, content: "Error: \(error.localizedDescription)", isError: true))
            }
        }
        return results
    }

    private static func text(of resp: ChatResponse) -> String {
        resp.content.filter { $0.type == "text" }.compactMap(\.text)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum AgentError: LocalizedError, Equatable {
        /// Poprzednia tura jeszcze trwa (np. czeka na odpowiedź albo na potwierdzenie).
        case busy
        case malformedResponse, unexpectedStopReason(String)
        var errorDescription: String? {
            switch self {
            case .busy: String(localized: "Hejo is still working on the previous request.")
            case .malformedResponse: String(localized: "The model returned an invalid response.")
            case .unexpectedStopReason(let r): String(localized: "Unexpected model stop reason: \(r)")
            }
        }
    }

    enum Replies {
        static var refusal: String { String(localized: "Sorry, I can't help with that.") }
        static var truncated: String { String(localized: "Sorry, my answer got cut off. Please try again.") }
        static var tooManySteps: String { String(localized: "Sorry, I couldn't finish this task.") }
        static var empty: String { String(localized: "Done.") }
    }

    static func systemPrompt(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        """
        You are a voice assistant running on the user's iPhone. Reply in the language the user speaks \
        (default: \(locale.identifier)). Keep replies short (1–2 sentences): they are read aloud, so no \
        markdown, lists or emoji.
        The user's time zone is \(timeZone.identifier); each user message starts with the current time.
        Use the tools to act on the phone. Pass dates as ISO 8601 with the time zone offset.
        If a request is ambiguous, ask one short clarifying question.
        If the user does not confirm an action, do not retry it.
        """
    }
}
