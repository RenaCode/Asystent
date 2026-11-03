// Testy aplikacji (nie pakietu): rejestr narzędzi, Info.plist i ustawienia z buildu.
#if !SWIFT_PACKAGE
import Foundation
import Testing
@testable import Asystent

@MainActor
struct StoreBuildTests {
    /// HOMEKIT_ENABLED ustawia project-local.yml na aplikacji i na testach; build sklepowy go nie ma.
    @Test func homeKitOnlyInLocalBuild() {
        let names = ToolRegistry.default.specs.map(\.name)
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSHomeKitUsageDescription")
        #if HOMEKIT_ENABLED
        #expect(names.contains("home_control"))
        #expect(usage != nil)
        #else
        #expect(!names.contains("home_control"))
        #expect(usage == nil)
        #endif
        #expect(names.contains("create_calendar_event"))
    }

    @Test func displayNameIsHejo() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hejo")
        #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
    }

    @Test func proxyIsNotOfferedWithoutBuildConfig() {
        let defaults = scratchDefaults()
        defaults.set(BackendMode.proxy.rawValue, forKey: AssistantSettings.modeKey)
        let store = AssistantSettings(defaults: defaults, proxyAvailable: false)
        #expect(store.availableModes == [.direct])
        #expect(store.mode == .direct)

        let selfHosted = AssistantSettings(defaults: defaults, proxyAvailable: true)
        #expect(selfHosted.mode == .proxy)
    }

    @Test func clientWithoutConsentSendsNothing() async throws {
        let keychain = KeychainStore(service: "asystent.tests.\(UUID().uuidString)")
        try keychain.save("sk-ant-test")
        defer { try? keychain.delete() }
        let settings = AssistantSettings(defaults: scratchDefaults(), keychain: keychain, proxyAvailable: false)

        URLProtocol.registerClass(CountingProtocol.self)
        defer { URLProtocol.unregisterClass(CountingProtocol.self) }
        CountingProtocol.count = 0

        let client = settings.makeClient()
        await #expect(throws: ConsentRequired.self) {
            try await client.send(.init(system: "", messages: [], tools: []))
        }
        #expect(CountingProtocol.count == 0)

        // Kontrola, że licznik w ogóle widzi ruch: po zgodzie zapytanie dochodzi do sieci.
        settings.consent.grant()
        _ = try? await settings.makeClient().send(.init(system: "", messages: [], tools: []))
        #expect(CountingProtocol.count == 1)
    }
}

/// Przechwytuje każde zapytanie z `URLSession.shared` i odpowiada błędem bez wyjścia do sieci.
final class CountingProtocol: URLProtocol {
    nonisolated(unsafe) static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
#endif
