import SwiftUI

struct ContentView: View {
    @Environment(AssistantSession.self) private var session
    @State private var typed = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.lines) { line in
                            Text("**\(line.role == .user ? String(localized: "You") : String(localized: "Assistant")):** \(line.text)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("conversation")

                if session.phase == .listening {
                    Text(session.transcript.isEmpty ? String(localized: "Listening…") : session.transcript)
                        .foregroundStyle(.secondary)
                }
                if case .error(let msg) = session.phase {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                        .accessibilityIdentifier("errorText")
                }

                if case .confirming = session.phase {
                    HStack(spacing: 24) {
                        Button("No", role: .cancel) { session.answerConfirmation(false) }
                        Button("Yes") { session.answerConfirmation(true) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button {
                        Task {
                            if session.phase == .listening { await session.stopListeningAndSend() }
                            else { await session.startListening() }
                        }
                    } label: {
                        Image(systemName: session.phase == .listening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 72))
                    }
                    .accessibilityLabel(session.phase == .listening ? Text("Stop listening") : Text("Start listening"))
                    .disabled(session.phase == .thinking)
                }

                // Wejście tekstowe — przydatne do testów w symulatorze
                HStack {
                    TextField("Type a command", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("commandField")
                    Button("Send") {
                        let t = typed; typed = ""
                        Task { await session.send(t) }
                    }
                    .disabled(typed.isEmpty || session.phase == .thinking)
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .navigationTitle("Asystent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { session.reset() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("Settings"))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
