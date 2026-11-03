/// Rejestracja narzędzi aplikacji. Nowe narzędzie = nowy plik + wpis tutaj.
extension ToolRegistry {
    @MainActor
    static let `default`: ToolRegistry = {
        var tools: [any AssistantTool] = [
            CalendarTool(),
            ListEventsTool(),
            ReminderTool(),
        ]
        #if HOMEKIT_ENABLED
        tools.append(HomeKitTool())
        #endif
        tools.append(RunShortcutTool())
        return ToolRegistry(tools: tools)
    }()
}
