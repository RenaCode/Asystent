import AppIntents

/// Rejestruje frazy w Siri bez konfiguracji po stronie użytkownika.
/// Każda fraza MUSI zawierać \(.applicationName). Wersje polskie: AppShortcuts.xcstrings.
struct AsystentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask",
            systemImageName: "waveform"
        )
    }
}
