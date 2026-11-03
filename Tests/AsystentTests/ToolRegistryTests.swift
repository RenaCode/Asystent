import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

@MainActor
struct ToolRegistryTests {
    let log = CallLog()

    @Test func specsAndLookup() async throws {
        let reg = ToolRegistry(tools: [FakeTool(name: "a", log: log), FakeTool(name: "b", log: log)])
        #expect(reg.specs.map(\.name) == ["a", "b"])
        #expect(reg.tool(named: "b") != nil)
        #expect(reg.tool(named: "zz") == nil)
        #expect(try await reg.run(name: "a", input: .object([:])) == "a ok")
        await #expect(throws: ToolError.self) { try await reg.run(name: "zz", input: .object([:])) }
    }

    @Test func schemaHelperBuildsStrictObject() {
        let s = schema(["title": ("string", "Tytuł")], required: ["title"])
        #expect(s["type"] == .string("object"))
        #expect(s["additionalProperties"] == .bool(false))
        #expect(s["required"] == .array([.string("title")]))
        #expect(s["properties"]?["title"]?["type"] == .string("string"))
    }

    @Test func parsesIsoDates() {
        #expect(parseISODate("2026-11-03T10:00:00+01:00") != nil)
        #expect(parseISODate("2026-11-03T10:00:00.250Z") != nil)
        #expect(parseISODate("jutro o 10") == nil)
        #expect(parseISODate(nil) == nil)
    }
}

struct ConfirmationParserTests {
    @Test(arguments: [
        ("Tak", true), ("tak, potwierdzam", true), ("Yes please", true),
        ("Nie", false), ("nie, anuluj", false), ("no", false), ("tak... nie", false),
        ("yesterday", nil), ("nietakt", nil), ("", nil),
    ] as [(String, Bool?)])
    func parses(_ text: String, _ expected: Bool?) {
        #expect(ConfirmationParser.parse(text) == expected)
    }
}
