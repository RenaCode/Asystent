import Foundation

/// Tryb BYO key: apka woła `api.anthropic.com` bezpośrednio kluczem użytkownika z Keychain.
/// Brak oficjalnego SDK dla Swifta — kształt zapytania jak w cURL z dokumentacji Messages API.
struct AnthropicDirectClient: LLMClient {
    var apiKey: String
    var model: String = ClaudeDefaults.model
    var effort: String = ClaudeDefaults.effort
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    var session: URLSession = .shared

    /// Ciało zapytania. Bez `temperature` i bez `thinking` (Opus 5.5 myśli adaptacyjnie zawsze),
    /// głębię kontroluje `output_config.effort`.
    struct Body: Encodable {
        var model: String
        var max_tokens: Int
        var system: String
        var messages: [Message]
        var tools: [ToolSpec]
        var output_config: [String: String]
        var fallbacks: String?
    }

    func makeRequest(_ req: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 90
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(ClaudeDefaults.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Haiku 5.5 nie ma serwerowego fallbacku — dla niego parametr pomijamy.
        let fallback = model.hasPrefix("claude-haiku") ? nil : "default"
        if fallback != nil { r.setValue(ClaudeDefaults.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = try JSONEncoder().encode(Body(
            model: model,
            max_tokens: ClaudeDefaults.maxTokens,
            system: req.system,
            messages: req.messages,
            tools: req.tools,
            output_config: ["effort": effort],
            fallbacks: fallback
        ))
        return r
    }

    func send(_ req: ChatRequest) async throws -> ChatResponse {
        try await performJSON(makeRequest(req), session: session, service: "Anthropic")
    }
}
