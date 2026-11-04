import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

struct ModelsTests {
    /// Pełna odpowiedź Messages API: thinking, fallback, text, tool_use, usage, stop_details.
    static let apiResponse = """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[
       {"type":"thinking","thinking":"","signature":"EqQB"},
       {"type":"text","text":"Dodaję."},
       {"type":"tool_use","id":"toolu_1","name":"create_calendar_event",
        "input":{"title":"Spotkanie","start":"2026-11-03T10:00:00+01:00","nested":{"n":[1,true,null]}}}
     ],
     "stop_reason":"tool_use","stop_sequence":null,"stop_details":null,
     "usage":{"input_tokens":10,"output_tokens":20}}
    """

    @Test func decodesApiResponse() throws {
        let r = try decodedResponse(Self.apiResponse)
        #expect(r.stop_reason == "tool_use")
        #expect(r.model == "claude-opus-5-5")
        #expect(r.stop_details == nil)
        #expect(r.content.map(\.type) == ["thinking", "text", "tool_use"])
        #expect(r.content[1].text == "Dodaję.")
        let call = r.content[2]
        #expect(call.id == "toolu_1")
        #expect(call.name == "create_calendar_event")
        #expect(call.input?["title"]?.string == "Spotkanie")
        #expect(call.input?["nested"]?["n"] == .array([.number(1), .bool(true), .null]))
    }

    @Test func decodesRefusalDetails() throws {
        let r = try decodedResponse("""
        {"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}}
        """)
        #expect(r.stop_reason == "refusal")
        #expect(r.stop_details?.category == "cyber")
        #expect(r.content.isEmpty)
    }

    @Test func unknownBlocksRoundTripUnchanged() throws {
        let block = """
        {"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"},"extra":[1,2]}
        """
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: Data(block.utf8))
        #expect(try jsonValue(decoded) == JSONDecoder().decode(JSONValue.self, from: Data(block.utf8)))
    }

    @Test func blockWithoutTypeIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"text":"x"}"#.utf8))
        }
    }

    @Test func localToolResultEncodesOnlySetFields() throws {
        #expect(try jsonValue(ContentBlock.toolResult(id: "t1", content: "ok")) == .object([
            "type": .string("tool_result"), "tool_use_id": .string("t1"), "content": .string("ok"),
        ]))
        #expect(try jsonValue(ContentBlock.toolResult(id: "t1", content: "x", isError: true))["is_error"] == .bool(true))
    }
}

struct ClientRequestTests {
    let chat = ChatRequest(system: "sys", messages: [Message(role: "user", content: [.text("hej")])],
                           tools: [ToolSpec(name: "a", description: "d", input_schema: .object([:]))])

    func body(_ r: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(r.httpBody))
    }

    @Test func directClientBuildsMessagesRequest() throws {
        let r = try AnthropicDirectClient(apiKey: "sk-test").makeRequest(chat)
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let b = try body(r)
        #expect(b["model"] == .string("claude-opus-5-5"))
        #expect(b["fallbacks"] == .string("default"))
        #expect(b["output_config"]?["effort"] == .string("low"))
        #expect(b["max_tokens"]?.double == 16_000)
        #expect(b["system"] == .string("sys"))
        #expect(b["tools"]?.arrayCount == 1)
        // Na Opus 5.5 te pola dają 400 albo są zbędne.
        for forbidden in ["temperature", "top_p", "top_k", "thinking", "tool_choice"] {
            #expect(b[forbidden] == nil, "\(forbidden) nie powinno być wysyłane")
        }
    }

    @Test func haikuHasNoServerFallback() throws {
        let r = try AnthropicDirectClient(apiKey: "k", model: "claude-haiku-5-5").makeRequest(chat)
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try body(r)["fallbacks"] == nil)
    }

    @Test func proxyClientSendsConversationOnly() throws {
        let r = try ProxyClient(baseURL: URL(string: "http://proxy.local:8787")!, appToken: "tok").makeRequest(chat)
        #expect(r.url?.absoluteString == "http://proxy.local:8787/v1/chat")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == nil)
        let b = try body(r)
        #expect(b["model"] == nil)
        #expect(b["messages"]?.arrayCount == 1)
    }

}

/// Wspólny `StubProtocol.handler` — testy sieciowe po kolei.
@Suite(.serialized)
struct NetworkTests {
    let chat = ClientRequestTests().chat

    @Test func httpErrorsAreSurfaced() async throws {
        StubProtocol.handler = { _ in (429, Data(#"{"error":"rate limited"}"#.utf8)) }
        let client = ProxyClient(baseURL: URL(string: "http://stub.local")!, appToken: "t", session: StubProtocol.session())
        do {
            _ = try await client.send(chat)
            Issue.record("powinien rzucić")
        } catch let e as LLMHTTPError {
            #expect(e.status == 429)
            #expect(e.service == "Proxy")
        }
    }

    @Test func successfulHttpResponseIsDecoded() async throws {
        StubProtocol.handler = { _ in (200, Data(ModelsTests.apiResponse.utf8)) }
        let client = AnthropicDirectClient(apiKey: "k", session: StubProtocol.session())
        let r = try await client.send(chat)
        #expect(r.stop_reason == "tool_use")
    }

    /// 200 z treścią, która nie jest odpowiedzią API (np. strona logowania sieci Wi-Fi): czytelny błąd
    /// z nazwą usługi zamiast surowego `DecodingError`.
    @Test(arguments: ["<html><body>Hotel Wi-Fi login</body></html>", "", #"{"content":"nie tablica"}"#],
          ["Proxy", "Anthropic"])
    func unreadableSuccessBodyIsAnInvalidResponse(_ body: String, _ service: String) async throws {
        StubProtocol.handler = { _ in (200, Data(body.utf8)) }
        let client: any LLMClient = service == "Proxy"
            ? ProxyClient(baseURL: URL(string: "http://stub.local")!, appToken: "t", session: StubProtocol.session())
            : AnthropicDirectClient(apiKey: "k", session: StubProtocol.session())
        do {
            _ = try await client.send(chat)
            Issue.record("powinien rzucić")
        } catch let e as LLMInvalidResponse {
            #expect(e.service == service)
            let message = try #require(e.errorDescription)
            #expect(message.contains(service))
            // Przyczyna zachowana do diagnostyki, ale jej surowy opis nie trafia do użytkownika.
            let underlying = try #require(e.underlying)
            #expect(message != underlying.localizedDescription)
        } catch {
            Issue.record("oczekiwany LLMInvalidResponse, jest \(error)")
        }
    }

    /// Brak sieci zostaje błędem systemowym (zlokalizowany komunikat iOS), nie „nieczytelną odpowiedzią”.
    @Test func offlineErrorIsNotMistakenForAnInvalidResponse() async throws {
        StubProtocol.handler = nil
        StubProtocol.failure = URLError(.notConnectedToInternet)
        defer { StubProtocol.failure = nil }
        let client = AnthropicDirectClient(apiKey: "k", session: StubProtocol.session())
        do {
            _ = try await client.send(chat)
            Issue.record("powinien rzucić")
        } catch let e as URLError {
            #expect(e.code == .notConnectedToInternet)
        } catch {
            Issue.record("oczekiwany URLError, jest \(error)")
        }
    }
}

extension JSONValue {
    var arrayCount: Int? { if case .array(let a) = self { return a.count }; return nil }
}

/// Podmiana sieci w URLSession — zero prawdziwych zapytań.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    /// Błąd transportu (np. brak sieci) zamiast odpowiedzi HTTP.
    nonisolated(unsafe) static var failure: URLError?

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
