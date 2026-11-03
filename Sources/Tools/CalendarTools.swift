import EventKit

@MainActor
enum EventStoreProvider {
    static let store = EKEventStore()
}

struct CalendarTool: AssistantTool {
    let spec = ToolSpec(
        name: "create_calendar_event",
        description: "Dodaje wydarzenie do domyślnego kalendarza użytkownika.",
        input_schema: schema([
            "title": ("string", "Tytuł wydarzenia"),
            "start": ("string", "Początek, ISO 8601 z offsetem"),
            "end": ("string", "Koniec, ISO 8601 z offsetem (domyślnie +1h)"),
            "location": ("string", "Miejsce (opcjonalnie)"),
        ], required: ["title", "start"])
    )

    func run(_ input: JSONValue) async throws -> String {
        let store = EventStoreProvider.store
        guard try await store.requestFullAccessToEvents() else { throw ToolError("Brak dostępu do kalendarza") }
        guard let title = input["title"]?.string, let start = parseISODate(input["start"]?.string) else {
            throw ToolError("Brak tytułu lub poprawnej daty początku")
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = parseISODate(input["end"]?.string) ?? start.addingTimeInterval(3600)
        e.location = input["location"]?.string
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent)
        return "Dodano: \(title), \(start.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct ListEventsTool: AssistantTool {
    let spec = ToolSpec(
        name: "list_calendar_events",
        description: "Zwraca wydarzenia z kalendarza w podanym przedziale czasu.",
        input_schema: schema([
            "from": ("string", "Początek przedziału, ISO 8601"),
            "to": ("string", "Koniec przedziału, ISO 8601"),
        ], required: ["from", "to"])
    )

    func run(_ input: JSONValue) async throws -> String {
        let store = EventStoreProvider.store
        guard try await store.requestFullAccessToEvents() else { throw ToolError("Brak dostępu do kalendarza") }
        guard let from = parseISODate(input["from"]?.string), let to = parseISODate(input["to"]?.string) else {
            throw ToolError("Niepoprawny przedział dat")
        }
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        if events.isEmpty { return "Brak wydarzeń." }
        return events.prefix(20).map {
            "\($0.startDate.formatted(date: .abbreviated, time: .shortened)) – \($0.title ?? "bez tytułu")"
        }.joined(separator: "\n")
    }
}

struct ReminderTool: AssistantTool {
    let spec = ToolSpec(
        name: "create_reminder",
        description: "Tworzy przypomnienie w aplikacji Przypomnienia.",
        input_schema: schema([
            "title": ("string", "Treść przypomnienia"),
            "due": ("string", "Termin, ISO 8601 z offsetem (opcjonalnie)"),
        ], required: ["title"])
    )

    func run(_ input: JSONValue) async throws -> String {
        let store = EventStoreProvider.store
        guard try await store.requestFullAccessToReminders() else { throw ToolError("Brak dostępu do przypomnień") }
        guard let title = input["title"]?.string else { throw ToolError("Brak treści") }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        if let due = parseISODate(input["due"]?.string) {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(r, commit: true)
        return "Przypomnienie utworzone: \(title)"
    }
}
