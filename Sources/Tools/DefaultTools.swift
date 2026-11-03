/// Rejestracja narzędzi aplikacji. Nowe narzędzie = nowy plik + wpis tutaj.
extension ToolRegistry {
    @MainActor
    static let `default` = ToolRegistry(tools: [
        CalendarTool(),
        ListEventsTool(),
        ReminderTool(),
        HomeKitTool(),
        RunShortcutTool(),
    ])
}
