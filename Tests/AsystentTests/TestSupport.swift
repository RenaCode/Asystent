import Foundation
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

/// Atrapa LLMClient: zwraca zaplanowane odpowiedzi po kolei i zapamiętuje zapytania.
actor ScriptedClient: LLMClient {
    enum Step { case reply(ChatResponse), fail(any Error) }
    private var steps: [Step]
    private(set) var requests: [ChatRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ req: ChatRequest) async throws -> ChatResponse {
        requests.append(req)
        guard !steps.isEmpty else { throw TestError.noMoreSteps }
        switch steps.removeFirst() {
        case .reply(let r): return r
        case .fail(let e): throw e
        }
    }
}

enum TestError: Error { case noMoreSteps, boom }

/// Narzędzie testowe: zapisuje wywołania, opcjonalnie wymaga potwierdzenia albo rzuca błąd.
@MainActor
final class CallLog { var inputs: [JSONValue] = [] }

@MainActor
struct FakeTool: AssistantTool {
    var name: String
    var log: CallLog
    var needsConfirmation = false
    var fails = false

    var spec: ToolSpec { ToolSpec(name: name, description: "test", input_schema: schema(["x": ("string", "x")], required: [])) }

    func confirmationQuestion(for input: JSONValue) -> String? { needsConfirmation ? "Sure?" : nil }

    func run(_ input: JSONValue) async throws -> String {
        log.inputs.append(input)
        if fails { throw ToolError("nope") }
        return "\(name) ok"
    }
}

@MainActor
final class FakeConfirmer: ActionConfirmer {
    var answer: Bool
    var asked: [String] = []
    init(answer: Bool) { self.answer = answer }
    func confirm(_ question: String) async -> Bool { asked.append(question); return answer }
}

func toolUse(_ id: String, _ name: String, _ input: JSONValue = .object([:])) -> ContentBlock {
    ContentBlock(type: "tool_use", id: id, name: name, input: input)
}

func response(_ stop: String?, _ content: [ContentBlock]) -> ChatResponse {
    ChatResponse(content: content, stop_reason: stop)
}

/// Odpowiedź tak, jak przychodzi z API (przez dekoder), żeby bloki miały `raw`.
func decodedResponse(_ json: String) throws -> ChatResponse {
    try JSONDecoder().decode(ChatResponse.self, from: Data(json.utf8))
}

func jsonValue<T: Encodable>(_ v: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
}
