import Foundation

/// Zgoda użytkownika na wysyłanie jego zapytań do zewnętrznego AI (App Review 5.1.2(i)).
/// Zapis lokalny: wersja tekstu ekranu zgody + data, osobno dla każdego trybu (inny odbiorca danych).
/// Zmiana zakresu wysyłanych danych = podbicie `currentVersion`, więc stara zgoda przestaje wystarczać.
/// `@unchecked`: `UserDefaults` jest bezpieczne wątkowo, ale SDK nie oznacza go jako `Sendable`.
struct ConsentStore: @unchecked Sendable {
    static let currentVersion = 1
    var defaults: UserDefaults = .standard
    /// Tryb połączenia (`BackendMode.rawValue`).
    var scope: String

    private var versionKey: String { "consent.\(scope).version" }
    private var dateKey: String { "consent.\(scope).date" }

    var isGranted: Bool { defaults.integer(forKey: versionKey) == Self.currentVersion }
    var grantedAt: Date? { isGranted ? defaults.object(forKey: dateKey) as? Date : nil }

    func grant(now: Date = .now) {
        defaults.set(Self.currentVersion, forKey: versionKey)
        defaults.set(now, forKey: dateKey)
    }

    func revoke() {
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: dateKey)
    }
}

struct ConsentRequired: LocalizedError {
    var errorDescription: String? {
        String(localized: "Allow sending your requests to Anthropic first (Settings → Privacy).")
    }
}

/// Ostatnia zapora: bez zgody zapytanie nie opuszcza telefonu, nawet gdy UI czegoś nie dopilnuje.
/// Zgoda sprawdzana przy każdym wysłaniu, więc jej cofnięcie działa od razu.
struct ConsentGatedClient: LLMClient {
    let base: any LLMClient
    let consent: ConsentStore

    func send(_ req: ChatRequest) async throws -> ChatResponse {
        guard consent.isGranted else { throw ConsentRequired() }
        return try await base.send(req)
    }
}
