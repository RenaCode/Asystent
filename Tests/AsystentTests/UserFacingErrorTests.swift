import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

/// Komunikaty błędów HTTP widoczne dla użytkownika: zamiast surowego JSON-a z API — co się stało
/// i co zrobić (zły klucz, brak środków, limit, przeciążenie). Treść sprawdzana po angielsku, więc
/// w aplikacji uruchomionej w innym języku zestaw jest pomijany (w `swift test` zawsze angielski).
@Suite(.enabled(if: Locale.preferredLanguages.first?.hasPrefix("en") ?? true, "komunikaty po angielsku"))
struct UserFacingErrorTests {
    private func message(_ status: Int, _ body: String, service: String = "Anthropic") -> String {
        LLMHTTPError(service: service, status: status, body: body).errorDescription ?? ""
    }

    @Test func invalidKeyPointsToSettings() {
        let m = message(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        #expect(m.contains("API key"))
        #expect(m.contains("Settings"))
        #expect(!m.contains("{"))
    }

    @Test func proxyRejectingTokenDoesNotBlameTheAPIKey() {
        let m = message(401, #"{"error":"unauthorized"}"#, service: "Proxy")
        #expect(!m.contains("API key"))
        #expect(m.contains("APP_TOKEN"))
    }

    @Test func lowCreditBalanceIsExplained() {
        // Anthropic: 400 invalid_request_error z tekstem o saldzie albo 402 billing_error.
        let m400 = message(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#)
        let m402 = message(402, #"{"type":"error","error":{"type":"billing_error","message":"Billing problem."}}"#)
        for m in [m400, m402] {
            #expect(m.contains("credit"))
            #expect(m.contains("Anthropic Console"))
        }
    }

    @Test func permissionErrorIsNotCalledAnInvalidKey() {
        let m = message(403, #"{"type":"error","error":{"type":"permission_error","message":"Your API key does not have permission to use the specified resource."}}"#)
        #expect(m.contains("permission"))
        #expect(!m.contains("rejected"))
    }

    @Test func rateLimitAndOverloadAskToRetry() {
        for status in [429, 529, 503, 500] {
            let m = message(status, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
            #expect(m.contains("try again"), "status \(status): \(m)")
            #expect(!m.contains("{"))
        }
        #expect(message(529, "").contains("529"))
    }

    @Test func otherErrorsShowStatusAndTheAPIMessageOnly() {
        let m = message(404, #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-x"}}"#)
        #expect(m.contains("404"))
        #expect(m.contains("model: claude-x"))
        #expect(!m.contains("not_found_error"))
        #expect(!m.contains("{"))
    }

    /// Proxy (`proxy/server.js`) odpowiada `{"error":"…"}` — tekst błędu bez JSON-a.
    @Test func proxyErrorShowsItsMessageWithoutJSON() {
        let m = message(400, #"{"error":"upstream rejected the request"}"#, service: "Proxy")
        #expect(m.contains("400"))
        #expect(m.contains("upstream rejected the request"))
        #expect(!m.contains("{"))
    }

    @Test func nonJSONBodyIsShortened() {
        // 418 trafia do gałęzi ogólnej, która pokazuje treść odpowiedzi.
        let m = message(418, String(repeating: "x", count: 1000) + "TAIL")
        #expect(m.contains("418"))
        #expect(m.contains(String(repeating: "x", count: 100)))
        #expect(!m.contains("TAIL"))
        #expect(m.count < 400)
    }

    @Test func badRequestWithoutCreditTextKeepsTheAPIMessage() {
        let m = message(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: field required"}}"#)
        #expect(m.contains("messages: field required"))
        #expect(!m.contains("credit"))
    }
}

/// Brak zgody to osobny błąd: nie może wyglądać jak problem z kluczem i nie może dojść do sieci.
struct ConsentErrorStaysDistinctTests {
    struct RejectingKeyClient: LLMClient {
        func send(_ req: ChatRequest) async throws -> ChatResponse {
            throw LLMHTTPError(service: "Anthropic", status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#)
        }
    }

    @Test func missingConsentIsReportedBeforeTheKeyIsTried() async {
        let client = ConsentGatedClient(base: RejectingKeyClient(), consent: ConsentStore(defaults: scratchDefaults(), scope: "direct"))
        do {
            _ = try await client.send(.init(system: "", messages: [], tools: []))
            Issue.record("powinien rzucić")
        } catch is ConsentRequired {
        } catch {
            Issue.record("oczekiwany ConsentRequired, jest \(error)")
        }
    }
}

/// „Report answer” (App Review 1.2 dla treści generowanych przez AI): e-mail do RenaCode z treścią
/// zgłaszanej odpowiedzi, wysyłany przez użytkownika z jego aplikacji pocztowej.
struct AnswerReportTests {
    private func body(_ url: URL) throws -> String {
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return parts.queryItems?.first { $0.name == "body" }?.value ?? ""
    }

    @Test func mailtoAddressedToRenaCodeWithTheAnswer() throws {
        let answer = "Odpowiedź z błędem & znakiem #1? a+b=c"
        let url = try #require(AnswerReport.mailURL(answer: answer))
        #expect(url.scheme == "mailto")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "contact@renacode.com")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"]?.contains("Hejo") == true)
        #expect(items["body"]?.contains(answer) == true)
        // Znaki z zapytania URL nie mogą rozbić parametrów.
        #expect(items.count == 2)
    }

    /// RFC 6068: zarezerwowane znaki zakodowane, końce linii jako CRLF (`%0D%0A`).
    @Test func encodingFollowsRFC6068() throws {
        let s = try #require(AnswerReport.mailURL(answer: "a+b=c & d#e?f\ng")).absoluteString
        let query = String(s.drop { $0 != "?" }.dropFirst())
        for code in ["%2B", "%3D", "%26", "%23", "%3F", "%0D%0A"] { #expect(query.contains(code), "\(code)") }
        let raw = query.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).last ?? "" }
        for value in raw { #expect(!value.contains { "+=#? \n\r".contains($0) }, "\(value)") }
        #expect(!query.contains("%0A%0A") && !query.replacingOccurrences(of: "%0D%0A", with: "").contains("%0A"))
    }

    @Test func longAnswerIsTruncatedByEncodedLengthWithEllipsis() throws {
        // Polskie znaki i emoji z ZWJ: wiele bajtów na znak po zakodowaniu.
        let answer = String(repeating: "żółć 👨‍👩‍👧 ", count: 400) + "TAIL"
        let url = try #require(AnswerReport.mailURL(answer: answer))
        #expect(url.absoluteString.utf8.count <= AnswerReport.maxURLLength)
        let b = try body(url)
        #expect(!b.contains("TAIL"))
        #expect(b.contains("…"))
        #expect(b.contains("żółć 👨‍👩‍👧"))
        // Skrócenie po całych znakach: rodzina z ZWJ nie zostaje rozcięta.
        let kept = b.components(separatedBy: "…").first ?? ""
        #expect(kept.unicodeScalars.last != "\u{200D}")
    }

    @Test func shortAnswerIsNotMarkedAsTruncated() throws {
        #expect(try !body(#require(AnswerReport.mailURL(answer: "Krótka odpowiedź"))).contains("…"))
    }
}
