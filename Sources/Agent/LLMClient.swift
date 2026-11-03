import Foundation

/// Abstrakcja nad dostawcą odpowiedzi modelu. Pętla agenta nie wie, czy rozmawia z
/// `api.anthropic.com` bezpośrednio (BYO key), czy z własnym proxy.
protocol LLMClient: Sendable {
    func send(_ req: ChatRequest) async throws -> ChatResponse
}

/// Ustawienia wspólne dla klientów (proxy ma własne, po stronie serwera).
enum ClaudeDefaults {
    static let model = "claude-opus-5-5"
    /// Asystent głosowy: krótkie odpowiedzi, liczy się opóźnienie. Opus 5.5 ma domyślnie
    /// `medium`, więc poziom ustawiamy jawnie.
    static let effort = "low"
    /// Z zapasem na myślenie adaptacyjne (liczy się do limitu, choć tekstu nie widać).
    static let maxTokens = 16_000
    static let apiVersion = "2026-10-21"
    /// Serwerowy fallback przy odmowie klasyfikatora (`fallbacks: "default"`).
    static let fallbackBeta = "server-side-fallback-2026-07-01"
}

struct LLMHTTPError: LocalizedError {
    let service: String, status: Int, body: String
    var errorDescription: String? { "\(service) \(status): \(body.prefix(200))" }
}

/// Wspólna obsługa odpowiedzi HTTP. `URLSession` wstrzykiwalne w testach.
func performJSON(_ request: URLRequest, session: URLSession, service: String) async throws -> ChatResponse {
    let (data, resp) = try await session.data(for: request)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
        throw LLMHTTPError(service: service, status: status, body: String(decoding: data, as: UTF8.self))
    }
    return try JSONDecoder().decode(ChatResponse.self, from: data)
}
