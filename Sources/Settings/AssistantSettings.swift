import Foundation

/// Skąd apka bierze odpowiedzi modelu.
enum BackendMode: String, CaseIterable, Identifiable, Sendable {
    /// Własny klucz Anthropic użytkownika, zapytania prosto do api.anthropic.com.
    case direct
    /// Self-hosted proxy (`proxy/`), klucz tylko na serwerze.
    case proxy
    var id: String { rawValue }
}

/// Ustawienia trzymane w UserDefaults (bez sekretów) + klucz w Keychain.
@MainActor
struct AssistantSettings {
    static let modeKey = "backendMode"
    var defaults: UserDefaults = .standard
    var keychain = KeychainStore()
    /// Proxy jest w ofercie tylko wtedy, gdy build ma `PROXY_URL` i `APP_TOKEN` (self-hosting).
    /// Build sklepowy ma je puste, więc pokazuje wyłącznie tryb własnego klucza.
    var proxyAvailable = ProxyClient.fromInfoPlist() != nil

    var availableModes: [BackendMode] { proxyAvailable ? BackendMode.allCases : [.direct] }

    var mode: BackendMode {
        get {
            let stored = BackendMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .direct
            return availableModes.contains(stored) ? stored : .direct
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    /// Zgoda na wysyłkę do Anthropic dla bieżącego trybu (inny tryb = inny odbiorca = osobna zgoda).
    var consent: ConsentStore { ConsentStore(defaults: defaults, scope: mode.rawValue) }

    var hasAPIKey: Bool { !(keychain.read() ?? "").isEmpty }

    /// Klient zgodny z aktualnymi ustawieniami; gdy czegoś brakuje — klient, który
    /// zwraca czytelny błąd, zamiast wysyłać zapytanie. Zawsze za bramką zgody.
    func makeClient() -> any LLMClient {
        ConsentGatedClient(base: makeBaseClient(), consent: consent)
    }

    private func makeBaseClient() -> any LLMClient {
        switch mode {
        case .direct:
            guard let key = keychain.read(), !key.isEmpty else {
                return UnconfiguredClient(reason: String(localized: "Add your Anthropic API key in Settings."))
            }
            return AnthropicDirectClient(apiKey: key)
        case .proxy:
            guard let proxy = ProxyClient.fromInfoPlist() else {
                return UnconfiguredClient(reason: String(localized: "Proxy is not configured (PROXY_URL and APP_TOKEN in Config.local.xcconfig)."))
            }
            return proxy
        }
    }
}

struct UnconfiguredClient: LLMClient {
    let reason: String
    struct NotConfigured: LocalizedError { let errorDescription: String? }
    func send(_ req: ChatRequest) async throws -> ChatResponse { throw NotConfigured(errorDescription: reason) }
}
