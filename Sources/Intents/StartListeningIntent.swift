import AppIntents

/// Jeden intent dla wszystkich wyzwalaczy: fraza Siri, Back Tap (przez Skrót), ControlWidget.
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hejo"
    static let description = IntentDescription("Opens Hejo and starts listening right away.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await AssistantSession.shared.startListening()
        #endif
        return .result()
    }
}
