import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

/// Ekran zgody musi wymieniać wszystko, co wychodzi do Anthropic (App Review 5.1.2(i)),
/// tak samo jak polityka prywatności (renacode.com/hejo/privacy). Sprawdzenie na prawdziwym
/// rejestrze narzędzi (`ToolRegistry.default`) jest w StoreBuildTests, bo narzędzia
/// (EventKit, UIKit, HomeKit) nie wchodzą do pakietu.
struct ConsentDisclosureTests {
    func spec(_ name: String, _ fields: [String]) -> ToolSpec {
        ToolSpec(name: name, description: "test",
                 input_schema: schema(Dictionary(uniqueKeysWithValues: fields.map { ($0, ("string", $0)) }),
                                      required: []))
    }

    @Test func disclosedToolWithDisclosedFieldsPasses() {
        #expect(ConsentDisclosure.undisclosed(specs: [spec("run_shortcut", ["name", "input"])]).isEmpty)
    }

    @Test func aNewToolIsReported() {
        #expect(ConsentDisclosure.undisclosed(specs: [spec("send_email", ["to"])]) == ["send_email"])
    }

    /// Nowe pole w znanym narzędziu (np. notatki wydarzenia) to nowe dane dla modelu.
    @Test func aNewFieldOfAKnownToolIsReported() {
        let s = spec("create_calendar_event", ["title", "start", "end", "location", "notes"])
        #expect(ConsentDisclosure.undisclosed(specs: [s]) == ["create_calendar_event.notes"])
    }

    /// Transkrypcja, czas/strefa/język i historia rozmowy idą przy każdym zapytaniu,
    /// niezależnie od narzędzi.
    @Test func alwaysSentDataIsListedEvenWithoutTools() {
        let ids = Set(ConsentDisclosure.items(toolNames: []).map(\.id))
        #expect(ids == ["speech", "context", "conversation"])
    }

    /// Pozycja narzędzia pojawia się tylko wtedy, gdy narzędzie jest w buildzie
    /// (HomeKit tylko w buildzie lokalnym).
    @Test func toolItemsFollowTheToolsInTheBuild() {
        let store = Set(ConsentDisclosure.items(toolNames: ["list_calendar_events", "create_calendar_event",
                                                            "create_reminder", "run_shortcut"]).map(\.id))
        #expect(store == ["speech", "context", "conversation", "calendarRead", "calendarCreate",
                          "reminders", "shortcuts"])
        // Pozycja HomeKit istnieje tylko w buildzie lokalnym (i w pakiecie), nie w sklepowym.
        #if HOMEKIT_ENABLED || SWIFT_PACKAGE
        #expect(ConsentDisclosure.items(toolNames: ["home_control"]).map(\.id).contains("homeKit"))
        #else
        #expect(!ConsentDisclosure.all.map(\.id).contains("homeKit"))
        #endif
    }

    /// Wiadomość użytkownika to znacznik czasu (pozycja „context”) i transkrypcja (pozycja „speech”).
    /// Nowy blok (np. lokalizacja) wymaga pozycji na ekranie zgody i podbicia wersji zgody.
    @MainActor
    @Test func userMessageCarriesOnlyTimeAndTranscript() async throws {
        let base = ScriptedClient([.reply(response("end_turn", [.text("ok")]))])
        let agent = AgentLoop(client: base, registry: ToolRegistry(tools: []),
                              now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await agent.run(userText: "co mam jutro?")
        let first = try #require(await base.requests.first)
        #expect(first.messages.count == 1)
        let blocks = first.messages[0].content
        #expect(blocks.count == 2)
        #expect(blocks.last?.text == "co mam jutro?")
    }
}
