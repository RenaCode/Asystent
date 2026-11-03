import Foundation

/// Każde narzędzie: opis dla Claude (JSON Schema) + lokalne wykonanie.
@MainActor
protocol AssistantTool {
    var spec: ToolSpec { get }
    /// Pytanie zadawane użytkownikowi głosem przed wykonaniem akcji destrukcyjnej lub
    /// nieodwracalnej. `nil` = akcja bezpieczna, bez potwierdzenia.
    func confirmationQuestion(for input: JSONValue) -> String?
    func run(_ input: JSONValue) async throws -> String
}

extension AssistantTool {
    func confirmationQuestion(for input: JSONValue) -> String? { nil }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor
struct ToolRegistry {
    let tools: [any AssistantTool]

    init(tools: [any AssistantTool]) {
        precondition(Set(tools.map(\.spec.name)).count == tools.count, "Zduplikowana nazwa narzędzia")
        self.tools = tools
    }

    var specs: [ToolSpec] { tools.map(\.spec) }

    func tool(named name: String) -> (any AssistantTool)? {
        tools.first { $0.spec.name == name }
    }

    func run(name: String, input: JSONValue) async throws -> String {
        guard let tool = tool(named: name) else { throw ToolError("Unknown tool \(name)") }
        return try await tool.run(input)
    }
}

// MARK: - Helpers

/// Skrót do budowy JSON Schema.
func schema(_ props: [String: (type: String, desc: String)], required: [String]) -> JSONValue {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(props.mapValues {
            .object(["type": .string($0.type), "description": .string($0.desc)])
        }),
        "required": .array(required.map { .string($0) }),
    ])
}

func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}
