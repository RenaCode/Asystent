import Foundation

/// Zgłoszenie odpowiedzi AI (App Review 1.2: aplikacje z treściami generowanymi przez AI dają sposób
/// na zgłoszenie treści). Użytkownik wysyła e-mail ze swojej aplikacji pocztowej — nic nie wychodzi
/// samo, a do RenaCode trafia tylko to, co zobaczy w szkicu wiadomości.
/// W pakiecie (a nie w `Settings/`), żeby `swift test` sprawdzał budowę adresu bez symulatora.
enum AnswerReport {
    static let recipient = "contact@renacode.com"
    /// Limit całego adresu `mailto:` po zakodowaniu (bajty) — z zapasem dla aplikacji pocztowych.
    static let maxURLLength = 4000

    /// Znaki dozwolone bez kodowania w wartości parametru (RFC 6068: bez `&`, `=`, `+`, `#`, `?`).
    private static let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))

    static func mailURL(answer: String) -> URL? {
        let subject = encode(String(localized: "Hejo: reported answer"))
        let head = String(localized: "Reported Hejo answer:") + "\r\n\r\n"
        let tail = "\r\n\r\n" + String(localized: "What is wrong with it:") + "\r\n"
        func url(_ text: String) -> String { "mailto:\(recipient)?subject=\(subject)&body=\(encode(head + text + tail))" }

        var text = normalizeNewlines(answer)
        if url(text).utf8.count > maxURLLength {
            // Skracanie po całych znakach (grafemach) — emoji z ZWJ i polskie litery nie zostają rozcięte.
            var kept = Substring(text)
            while !kept.isEmpty, url(kept + "…").utf8.count > maxURLLength {
                let over = url(kept + "…").utf8.count - maxURLLength
                // Co najmniej jeden znak; zakodowany znak ma do kilkunastu bajtów, więc dzielimy z zapasem.
                kept = kept.dropLast(max(1, over / 12))
            }
            text = kept + "…"
        }
        return URL(string: url(text))
    }

    /// Końce linii jako CRLF (RFC 6068).
    private static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
}
