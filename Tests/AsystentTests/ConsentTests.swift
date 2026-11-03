import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

/// Osobne UserDefaults na test, żeby nie dotykać ustawień aplikacji-gospodarza.
func scratchDefaults() -> UserDefaults {
    let name = "consent-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
struct ConsentTests {
    @Test func grantAndRevoke() {
        let store = ConsentStore(defaults: scratchDefaults(), scope: "direct")
        #expect(!store.isGranted)
        #expect(store.grantedAt == nil)

        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.grant(now: when)
        #expect(store.isGranted)
        #expect(store.grantedAt == when)

        store.revoke()
        #expect(!store.isGranted)
        #expect(store.grantedAt == nil)
    }

    @Test func consentIsPerModeAndPerVersion() {
        let defaults = scratchDefaults()
        ConsentStore(defaults: defaults, scope: "direct").grant()
        #expect(!ConsentStore(defaults: defaults, scope: "proxy").isGranted)

        // Zgoda na starszy tekst ekranu nie wystarcza.
        defaults.set(ConsentStore.currentVersion - 1, forKey: "consent.direct.version")
        #expect(!ConsentStore(defaults: defaults, scope: "direct").isGranted)
    }

    @Test func noConsentMeansNoRequestLeaves() async throws {
        let base = ScriptedClient([.reply(response("end_turn", [.text("hej")]))])
        let consent = ConsentStore(defaults: scratchDefaults(), scope: "direct")
        let agent = AgentLoop(client: ConsentGatedClient(base: base, consent: consent),
                              registry: ToolRegistry(tools: []))

        await #expect(throws: ConsentRequired.self) { try await agent.run(userText: "co mam jutro?") }
        #expect(await base.requests.isEmpty)
        #expect(agent.history.isEmpty)

        consent.grant()
        #expect(try await agent.run(userText: "co mam jutro?") == "hej")
        #expect(await base.requests.count == 1)
    }

    @Test func revokedConsentBlocksTheNextRequest() async throws {
        let base = ScriptedClient([.reply(response("end_turn", [.text("1")]))])
        let consent = ConsentStore(defaults: scratchDefaults(), scope: "direct")
        consent.grant()
        let client = ConsentGatedClient(base: base, consent: consent)
        _ = try await client.send(.init(system: "", messages: [], tools: []))

        consent.revoke()
        await #expect(throws: ConsentRequired.self) { try await client.send(.init(system: "", messages: [], tools: [])) }
        #expect(await base.requests.count == 1)
    }
}
