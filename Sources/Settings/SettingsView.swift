import SwiftUI

struct SettingsView: View {
    @Environment(AssistantSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BackendMode = .direct
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var error: String?

    private let settings = AssistantSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $mode) {
                        Text("Own API key").tag(BackendMode.direct)
                        Text("Self-hosted proxy").tag(BackendMode.proxy)
                    }
                } footer: {
                    Text(mode == .direct
                         ? "Requests go straight from this iPhone to api.anthropic.com and are billed to your key."
                         : "Requests go to the proxy set in Config.local.xcconfig at build time.")
                }

                if mode == .direct {
                    Section {
                        SecureField(hasKey ? "Key saved — paste to replace" : "sk-ant-…", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("apiKeyField")
                        if hasKey {
                            Button("Remove key", role: .destructive) {
                                do { try settings.keychain.delete(); hasKey = false } catch { self.error = error.localizedDescription }
                            }
                        }
                    } header: {
                        Text("Anthropic API key")
                    } footer: {
                        Text("Stored only in this device's Keychain. Create a key at console.anthropic.com.")
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                mode = settings.mode
                hasKey = settings.hasAPIKey
            }
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !key.isEmpty { try settings.keychain.save(key) }
            settings.mode = mode
            apiKey = ""
            session.reloadSettings()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
