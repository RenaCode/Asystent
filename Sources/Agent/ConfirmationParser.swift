import Foundation

/// Rozpoznaje odpowiedź tak/nie w transkrypcji (pl + en). Sprawdzane całe słowa,
/// żeby „nietak” czy „yesterday” nie przeszły.
enum ConfirmationParser {
    static let yes: Set<String> = ["tak", "potwierdzam", "zgoda", "jasne", "yes", "yeah", "confirm", "sure"]
    static let no: Set<String> = ["nie", "anuluj", "stop", "no", "cancel", "nope"]

    static func parse(_ text: String) -> Bool? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        // Przeczenie wygrywa: „nie, tak nie” = nie.
        if words.contains(where: no.contains) { return false }
        if words.contains(where: yes.contains) { return true }
        return nil
    }
}
