import SwiftUI

@main
struct AsystentApp: App {
    @State private var session = AssistantSession.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .onOpenURL { url in
                    // asystent://listen — z Back Tap (Skrót „Otwórz URL”) lub widgetu
                    if url.host == "listen" { Task { await session.startListening() } }
                }
        }
    }
}
