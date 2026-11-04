import Foundation
import os

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

/// Błąd HTTP od Anthropic albo proxy. `errorDescription` widzi użytkownik: co się stało i co zrobić,
/// bez surowego JSON-a (kody i typy błędów: https://docs.anthropic.com/en/api/errors).
struct LLMHTTPError: LocalizedError {
    let service: String, status: Int, body: String

    var errorDescription: String? {
        let isAnthropic = service == "Anthropic"
        switch status {
        case 401:
            return isAnthropic
                ? String(localized: "Anthropic rejected the API key. Check or replace it in Settings.")
                : String(localized: "The proxy rejected the app token (APP_TOKEN in Config.local.xcconfig).")
        case 402:
            return String(localized: "Your Anthropic credit balance is too low. Add credits in the Anthropic Console.")
        case 400 where body.localizedCaseInsensitiveContains("credit balance"):
            return String(localized: "Your Anthropic credit balance is too low. Add credits in the Anthropic Console.")
        case 403:
            return String(localized: "This API key has no permission for this request. Check the key's workspace and limits in the Anthropic Console.")
        case 429:
            return String(localized: "Too many requests. Wait a moment and try again.")
        case 500, 502, 503, 504, 529:
            return String(localized: "\(service) is temporarily unavailable or overloaded (\(status)). Please try again in a moment.")
        default:
            return String(localized: "\(service) error \(status): \(apiMessage)")
        }
    }

    /// Tekst błędu z odpowiedzi: Anthropic `{"type":"error","error":{"type":…,"message":…}}`,
    /// proxy (`proxy/server.js`) `{"error":"…"}`; inna treść — skrócona.
    var apiMessage: String {
        struct Anthropic: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
        struct Proxy: Decodable { let error: String }
        let data = Data(body.utf8)
        let text = (try? JSONDecoder().decode(Anthropic.self, from: data))?.error.message
            ?? (try? JSONDecoder().decode(Proxy.self, from: data))?.error
            ?? body
        return String(text.prefix(200))
    }
}

/// Odpowiedź 200, której nie da się odczytać jako odpowiedzi API (np. strona logowania sieci Wi-Fi
/// albo przerwane połączenie). Zamiast surowego `DecodingError` — komunikat z nazwą usługi.
struct LLMInvalidResponse: LocalizedError {
    let service: String
    /// Przyczyna do diagnostyki (nie trafia do komunikatu dla użytkownika).
    var underlying: DecodingError?

    var errorDescription: String? {
        String(localized: "\(service) sent a response the app could not read. Check your internet connection and try again.")
    }
}

/// Wspólna obsługa odpowiedzi HTTP. `URLSession` wstrzykiwalne w testach.
/// Błędy transportu (`URLError`, np. brak sieci) idą dalej bez zmian — iOS daje dla nich zlokalizowany opis.
func performJSON(_ request: URLRequest, session: URLSession, service: String) async throws -> ChatResponse {
    let (data, resp) = try await session.data(for: request)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
        throw LLMHTTPError(service: service, status: status, body: String(decoding: data, as: UTF8.self))
    }
    do {
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    } catch let error as DecodingError {
        // Bez treści odpowiedzi — może zawierać dane użytkownika.
        Logger(subsystem: "Asystent", category: "LLMClient")
            .error("\(service, privacy: .public): unreadable 200 response (\(data.count) bytes): \(String(describing: error), privacy: .private)")
        throw LLMInvalidResponse(service: service, underlying: error)
    }
}
