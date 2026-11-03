import Foundation

/// Tryb self-hosted: rozmawia z naszym proxy (klucz API jest tylko na serwerze).
/// Model, effort i fallback wybiera proxy — apka wysyła tylko rozmowę.
struct ProxyClient: LLMClient {
    let baseURL: URL
    let appToken: String
    var session: URLSession = .shared

    /// Adres i token z Info.plist (wstrzykiwane z `Config.local.xcconfig`).
    static func fromInfoPlist() -> ProxyClient? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let s = info["PROXY_URL"] as? String, !s.isEmpty, let url = URL(string: s), url.host != nil,
              let token = info["APP_TOKEN"] as? String, !token.isEmpty
        else { return nil }
        return .init(baseURL: url, appToken: token)
    }

    func makeRequest(_ req: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: "v1/chat"))
        r.httpMethod = "POST"
        r.timeoutInterval = 90
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONEncoder().encode(req)
        return r
    }

    func send(_ req: ChatRequest) async throws -> ChatResponse {
        try await performJSON(makeRequest(req), session: session, service: "Proxy")
    }
}
