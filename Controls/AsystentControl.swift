import SwiftUI
import WidgetKit

/// Kontrolka do Control Center i na ekran blokady (zamiast latarki/aparatu).
struct AsystentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "asystent.control") {
            ControlWidgetButton(action: StartListeningIntent()) {
                Label("Asystent", systemImage: "waveform")
            }
        }
        .displayName("Asystent")
        .description("Start talking to Asystent.")
    }
}

@main
struct AsystentControlsBundle: WidgetBundle {
    var body: some Widget {
        AsystentControl()
    }
}
