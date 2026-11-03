import Foundation

/// Co wychodzi do Anthropic: lista dla ekranu zgody (App Review 5.1.2(i)), zgodna z polityką
/// prywatności (renacode.com/hejo/privacy). Pozycje narzędzi pokazują się tylko dla narzędzi
/// obecnych w buildzie. Narzędzie albo pole jego `input_schema` bez pozycji wykrywają testy
/// (`undisclosed(specs:)` na `ToolRegistry.default` w StoreBuildTests).
/// Nowe dane wysyłane do modelu = nowa pozycja tutaj + podbicie `ConsentStore.currentVersion`
/// + zmiana polityki prywatności na stronie.
enum ConsentDisclosure {
    struct Item: Identifiable, Sendable {
        let id: String
        let text: LocalizedStringResource
        let systemImage: String
        /// Narzędzie → pola wejścia opisane tą pozycją; puste = dane wysyłane zawsze.
        let tools: [String: Set<String>]
    }

    static let all: [Item] = common + homeKit

    /// Tylko build lokalny (i pakiet z testami): CI szuka napisu `home_control` w binarce
    /// buildu sklepowego, więc nie może tam trafić nawet w opisie zgody.
    #if HOMEKIT_ENABLED || SWIFT_PACKAGE
    private static let homeKit = [
        Item(id: "homeKit",
             text: "Names of HomeKit accessories, rooms and scenes.",
             systemImage: "house", tools: ["home_control": ["action", "name"]]),
    ]
    #else
    private static let homeKit: [Item] = []
    #endif

    private static let common: [Item] = [
        Item(id: "speech",
             text: "The text of what you say (transcribed speech), not the audio.",
             systemImage: "text.quote", tools: [:]),
        // AgentLoop: znacznik czasu w każdej wiadomości, strefa i locale w prompcie systemowym.
        Item(id: "context",
             text: "The current date and time, your time zone, and this iPhone’s language and region.",
             systemImage: "clock", tools: [:]),
        // AgentLoop.history: dopisywana, wysyłana w całości z każdym zapytaniem; czyści ją Reset i restart.
        Item(id: "conversation",
             text: "The conversation so far: your earlier requests, the AI’s answers and the results of actions (for example calendar events read). It is sent again with every request until you tap Reset or restart the app.",
             systemImage: "bubble.left.and.bubble.right", tools: [:]),
        // list_calendar_events: predicateForEvents(calendars: nil), prefix(20), zakres z wejścia modelu.
        Item(id: "calendarRead",
             text: "Dates, times and titles of events from all calendars on this iPhone when a request needs your calendar. The AI chooses the date range (up to 20 events).",
             systemImage: "calendar", tools: ["list_calendar_events": ["from", "to"]]),
        Item(id: "calendarCreate",
             text: "Title, start and end time, and place of events you ask to create.",
             systemImage: "calendar.badge.plus",
             tools: ["create_calendar_event": ["title", "start", "end", "location"]]),
        Item(id: "reminders",
             text: "The text and due date of reminders you create.",
             systemImage: "checklist", tools: ["create_reminder": ["title", "due"]]),
        Item(id: "shortcuts",
             text: "Names of Shortcuts you ask to run and the text passed to them.",
             systemImage: "square.stack.3d.up", tools: ["run_shortcut": ["name", "input"]]),
    ]

    /// Pozycje dla buildu z podanymi narzędziami: zawsze wysyłane + te, których narzędzia są w buildzie.
    static func items(toolNames: [String]) -> [Item] {
        let present = Set(toolNames)
        return all.filter { $0.tools.isEmpty || !Set($0.tools.keys).isDisjoint(with: present) }
    }

    /// Narzędzia (`nazwa`) i pola wejścia (`nazwa.pole`) nieopisane na ekranie zgody.
    static func undisclosed(specs: [ToolSpec]) -> [String] {
        var disclosed: [String: Set<String>] = [:]
        for item in all { disclosed.merge(item.tools) { $0.union($1) } }
        return specs.flatMap { spec -> [String] in
            guard let fields = disclosed[spec.name] else { return [spec.name] }
            guard case .object(let props)? = spec.input_schema["properties"] else { return [] }
            return props.keys.sorted().filter { !fields.contains($0) }.map { "\(spec.name).\($0)" }
        }
    }
}
