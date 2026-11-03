import Foundation

/// Minimalny podzbiór Messages API potrzebny do pętli tool use.
/// JSON trzymamy jako `JSONValue`, żeby nie modelować każdego pola.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}

/// Blok treści wiadomości. Bloki z odpowiedzi modelu (np. `thinking` z podpisem, `fallback`)
/// muszą wrócić do API **bez zmian** w kolejnych zapytaniach, więc zachowujemy surowy JSON
/// (`raw`) i kodujemy właśnie jego; pola typowane służą tylko do odczytu.
struct ContentBlock: Codable, Sendable, Equatable {
    var type: String                  // "text" | "tool_use" | "tool_result" | "thinking" | ...
    var text: String?
    var id: String?                   // tool_use
    var name: String?                 // tool_use
    var input: JSONValue?             // tool_use
    var tool_use_id: String?          // tool_result
    var content: String?              // tool_result
    var is_error: Bool?               // tool_result
    /// Oryginalny JSON bloku z odpowiedzi API (nil dla bloków tworzonych lokalnie).
    var raw: JSONValue?

    init(type: String, text: String? = nil, id: String? = nil, name: String? = nil, input: JSONValue? = nil,
         tool_use_id: String? = nil, content: String? = nil, is_error: Bool? = nil) {
        self.type = type; self.text = text; self.id = id; self.name = name; self.input = input
        self.tool_use_id = tool_use_id; self.content = content; self.is_error = is_error
    }

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let type = raw["type"]?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Blok bez pola type"))
        }
        self.init(type: type, text: raw["text"]?.string, id: raw["id"]?.string, name: raw["name"]?.string,
                  input: raw["input"], tool_use_id: raw["tool_use_id"]?.string, content: raw["content"]?.string,
                  is_error: raw["is_error"]?.bool)
        self.raw = raw
    }

    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var o: [String: JSONValue] = ["type": .string(type)]
        if let text { o["text"] = .string(text) }
        if let id { o["id"] = .string(id) }
        if let name { o["name"] = .string(name) }
        if let input { o["input"] = input }
        if let tool_use_id { o["tool_use_id"] = .string(tool_use_id) }
        if let content { o["content"] = .string(content) }
        if let is_error { o["is_error"] = .bool(is_error) }
        try JSONValue.object(o).encode(to: encoder)
    }

    static func text(_ t: String) -> Self { .init(type: "text", text: t) }
    static func toolResult(id: String, content: String, isError: Bool = false) -> Self {
        .init(type: "tool_result", tool_use_id: id, content: content, is_error: isError ? true : nil)
    }
}

struct Message: Codable, Sendable, Equatable {
    var role: String                  // "user" | "assistant"
    var content: [ContentBlock]
}

struct ToolSpec: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var input_schema: JSONValue
}

/// To, co pętla agenta wysyła do dowolnego `LLMClient`. Model, limity i nagłówki dokłada klient.
struct ChatRequest: Codable, Sendable, Equatable {
    var system: String
    var messages: [Message]
    var tools: [ToolSpec]
}

struct StopDetails: Codable, Sendable, Equatable {
    var type: String?
    var category: String?
    var explanation: String?
}

struct ChatResponse: Codable, Sendable, Equatable {
    var content: [ContentBlock]
    var stop_reason: String?
    var stop_details: StopDetails?
    var model: String?
}
