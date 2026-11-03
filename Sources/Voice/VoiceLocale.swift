import Foundation

/// Język mowy (STT i TTS): polski, jeśli to preferowany język użytkownika, w przeciwnym razie angielski.
enum VoiceLocale {
    static var current: Locale {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: preferred.hasPrefix("pl") ? "pl-PL" : "en-US")
    }
}
