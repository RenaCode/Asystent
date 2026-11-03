import UIKit

/// Furtka do akcji systemowych, których nie da się zrobić z apki (Wi-Fi, tryby skupienia,
/// wiadomości itp.): uruchamia Skrót użytkownika po nazwie.
/// Uwaga: iOS przełącza na apkę Skróty; `x-success` wraca do Asystenta.
struct RunShortcutTool: AssistantTool {
    let spec = ToolSpec(
        name: "run_shortcut",
        description: """
        Uruchamia Skrót (Shortcuts) użytkownika o podanej nazwie. Używaj do akcji systemowych \
        niedostępnych innymi narzędziami. Dostępne skróty: \(Self.knownShortcuts.joined(separator: ", ")).
        """,
        input_schema: schema([
            "name": ("string", "Dokładna nazwa Skrótu"),
            "input": ("string", "Tekst przekazany do Skrótu (opcjonalnie)"),
        ], required: ["name"])
    )

    /// Lista skrótów, które użytkownik przygotował — edytuj pod siebie.
    static let knownShortcuts = ["Tryb skupienia", "Wyślij wiadomość", "Nawiguj do domu"]

    /// Skrót może zrobić wszystko (wysłać wiadomość, usunąć dane) — zawsze pytamy.
    func confirmationQuestion(for input: JSONValue) -> String? {
        let name = input["name"]?.string ?? "?"
        return String(localized: "Run the shortcut “\(name)”?")
    }

    func run(_ input: JSONValue) async throws -> String {
        guard let name = input["name"]?.string else { throw ToolError("Brak nazwy skrótu") }
        var c = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        c.queryItems = [
            .init(name: "name", value: name),
            .init(name: "x-success", value: "asystent://done"),
        ]
        if let text = input["input"]?.string {
            c.queryItems?.append(contentsOf: [.init(name: "input", value: "text"), .init(name: "text", value: text)])
        }
        guard let url = c.url, await UIApplication.shared.open(url) else {
            throw ToolError("Nie udało się uruchomić skrótu \(name)")
        }
        return "Uruchomiono skrót \(name)"
    }
}
