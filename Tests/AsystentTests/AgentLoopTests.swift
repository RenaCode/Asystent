import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

@MainActor
struct AgentLoopTests {
    let log = CallLog()

    func loop(_ client: ScriptedClient, tools: [any AssistantTool]? = nil, confirmer: (any ActionConfirmer)? = nil) -> AgentLoop {
        AgentLoop(client: client, registry: ToolRegistry(tools: tools ?? [FakeTool(name: "a", log: log)]), confirmer: confirmer)
    }

    @Test func endTurnReturnsTextAndKeepsHistory() async throws {
        let client = ScriptedClient([.reply(response("end_turn", [.text("Cześć"), .text("!")]))])
        let agent = loop(client)
        let reply = try await agent.run(userText: "hej")
        #expect(reply == "Cześć !")
        #expect(agent.history.map(\.role) == ["user", "assistant"])
        // Bieżący czas idzie osobnym blokiem w wiadomości użytkownika, tekst użytkownika — ostatni.
        #expect(agent.history[0].content.last?.text == "hej")
        #expect(await client.requests.first?.tools.map(\.name) == ["a"])
    }

    @Test func toolUseRunsToolAndSendsResult() async throws {
        let client = ScriptedClient([
            .reply(response("tool_use", [.text("Sprawdzam."), toolUse("t1", "a", .object(["x": .string("1")]))])),
            .reply(response("end_turn", [.text("Gotowe")])),
        ])
        let agent = loop(client)
        #expect(try await agent.run(userText: "zrób") == "Gotowe")
        #expect(log.inputs == [.object(["x": .string("1")])])

        let second = try #require(await client.requests.last)
        let results = try #require(second.messages.last)
        #expect(results.role == "user")
        #expect(results.content.map(\.type) == ["tool_result"])
        #expect(results.content[0].tool_use_id == "t1")
        #expect(results.content[0].content == "a ok")
        #expect(results.content[0].is_error == nil)
    }

    @Test func parallelToolCallsReturnAllResultsInOneMessage() async throws {
        let client = ScriptedClient([
            .reply(response("tool_use", [toolUse("t1", "a"), toolUse("t2", "b")])),
            .reply(response("end_turn", [.text("ok")])),
        ])
        let agent = loop(client, tools: [FakeTool(name: "a", log: log), FakeTool(name: "b", log: log)])
        _ = try await agent.run(userText: "x")
        let last = try #require(await client.requests.last?.messages.last)
        #expect(last.content.compactMap(\.tool_use_id) == ["t1", "t2"])
    }

    @Test func toolErrorAndUnknownToolAreReportedAsErrors() async throws {
        let client = ScriptedClient([
            .reply(response("tool_use", [toolUse("t1", "bad"), toolUse("t2", "ghost")])),
            .reply(response("end_turn", [.text("ok")])),
        ])
        let agent = loop(client, tools: [FakeTool(name: "bad", log: log, fails: true)])
        _ = try await agent.run(userText: "x")
        let last = try #require(await client.requests.last?.messages.last)
        #expect(last.content.map(\.is_error) == [true, true])
    }

    @Test func refusalDoesNotRunToolsAndRollsBackTurn() async throws {
        let client = ScriptedClient([
            .reply(response("refusal", [.text("częściowa treść"), toolUse("t1", "a")])),
        ])
        let agent = loop(client)
        let reply = try await agent.run(userText: "x")
        #expect(reply == AgentLoop.Replies.refusal)
        #expect(log.inputs.isEmpty)
        #expect(agent.history.isEmpty)
    }

    @Test func maxTokensDoesNotRunTruncatedToolCall() async throws {
        let client = ScriptedClient([.reply(response("max_tokens", [toolUse("t1", "a")]))])
        let agent = loop(client)
        #expect(try await agent.run(userText: "x") == AgentLoop.Replies.truncated)
        #expect(log.inputs.isEmpty)
        #expect(agent.history.isEmpty)
    }

    @Test func toolUseStopWithoutCallsIsMalformed() async throws {
        let client = ScriptedClient([.reply(response("tool_use", [.text("hmm")]))])
        let agent = loop(client)
        await #expect(throws: AgentLoop.AgentError.malformedResponse) { try await agent.run(userText: "x") }
        #expect(agent.history.isEmpty)
    }

    @Test func endTurnWithToolUseBlockDoesNotRunIt() async throws {
        // Narzędzia uruchamiamy tylko przy stop_reason == "tool_use".
        let client = ScriptedClient([.reply(response("end_turn", [.text("ok"), toolUse("t1", "a")]))])
        let agent = loop(client)
        #expect(try await agent.run(userText: "x") == "ok")
        #expect(log.inputs.isEmpty)
    }

    @Test func unknownOrMissingStopReasonThrows() async throws {
        for stop in ["something_new", nil] as [String?] {
            let agent = loop(ScriptedClient([.reply(response(stop, [.text("x")]))]))
            await #expect(throws: AgentLoop.AgentError.self) { try await agent.run(userText: "x") }
            #expect(agent.history.isEmpty)
        }
    }

    @Test func clientErrorRollsBackHistory() async throws {
        let client = ScriptedClient([
            .reply(response("end_turn", [.text("pierwsza")])),
            .reply(response("tool_use", [toolUse("t1", "a")])),
            .fail(TestError.boom),
        ])
        let agent = loop(client)
        _ = try await agent.run(userText: "1")
        await #expect(throws: TestError.self) { try await agent.run(userText: "2") }
        #expect(agent.history.count == 2)
    }

    @Test func stopsAfterMaxSteps() async throws {
        let steps = (0..<20).map { ScriptedClient.Step.reply(response("tool_use", [toolUse("t\($0)", "a")])) }
        let agent = loop(ScriptedClient(steps))
        #expect(try await agent.run(userText: "x") == AgentLoop.Replies.tooManySteps)
        #expect(log.inputs.count == agent.maxSteps)
        #expect(agent.history.isEmpty)
    }

    @Test func pauseTurnIsResentUnchanged() async throws {
        let client = ScriptedClient([
            .reply(response("pause_turn", [.text("pół")])),
            .reply(response("end_turn", [.text("całość")])),
        ])
        let agent = loop(client)
        #expect(try await agent.run(userText: "x") == "całość")
        let second = try #require(await client.requests.last)
        #expect(second.messages.map(\.role) == ["user", "assistant"])
    }

    /// Bloki thinking są związane z prefiksem: system, narzędzia i wcześniejsze wiadomości muszą
    /// wracać bajt w bajt, a historia tylko rosnąć.
    @Test func historyIsAppendOnlyAndSystemPromptFrozen() async throws {
        let first = try decodedResponse("""
        {"content":[{"type":"thinking","thinking":"","signature":"sig-1"},
                    {"type":"tool_use","id":"t1","name":"a","input":{"x":"1"}}],
         "stop_reason":"tool_use"}
        """)
        let client = ScriptedClient([
            .reply(first),
            .reply(response("end_turn", [.text("ok")])),
            .reply(response("end_turn", [.text("ok2")])),
        ])
        let agent = loop(client)
        _ = try await agent.run(userText: "1")
        _ = try await agent.run(userText: "2")

        let reqs = await client.requests
        #expect(reqs.count == 3)
        #expect(Set(reqs.map(\.system)).count == 1)
        for (prev, next) in zip(reqs, reqs.dropFirst()) {
            let p = try jsonValue(prev.messages), n = try jsonValue(next.messages)
            guard case .array(let pa) = p, case .array(let na) = n else { Issue.record("not arrays"); return }
            #expect(Array(na.prefix(pa.count)) == pa)
            #expect(try jsonValue(prev.tools) == jsonValue(next.tools))
        }
        // Blok thinking wraca dokładnie w tej postaci, w jakiej przyszedł.
        let assistant = try jsonValue(reqs[1].messages[1])
        #expect(assistant["content"] == .array([
            .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig-1")]),
            .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("a"), "input": .object(["x": .string("1")])]),
        ]))
    }

    @Test func destructiveToolNeedsConfirmation() async throws {
        for answer in [false, true] {
            let log = CallLog()
            let confirmer = FakeConfirmer(answer: answer)
            let client = ScriptedClient([
                .reply(response("tool_use", [toolUse("t1", "rm")])),
                .reply(response("end_turn", [.text("ok")])),
            ])
            let agent = loop(client, tools: [FakeTool(name: "rm", log: log, needsConfirmation: true)], confirmer: confirmer)
            _ = try await agent.run(userText: "usuń")
            #expect(confirmer.asked == ["Sure?"])
            #expect(log.inputs.count == (answer ? 1 : 0))
            let result = try #require(await client.requests.last?.messages.last?.content.first)
            #expect(result.is_error == (answer ? nil : true))
        }
    }

    @Test func destructiveToolWithoutConfirmerIsNeverRun() async throws {
        let client = ScriptedClient([
            .reply(response("tool_use", [toolUse("t1", "rm")])),
            .reply(response("end_turn", [.text("ok")])),
        ])
        let agent = loop(client, tools: [FakeTool(name: "rm", log: log, needsConfirmation: true)])
        _ = try await agent.run(userText: "usuń")
        #expect(log.inputs.isEmpty)
    }

    @Test func resetStartsFreshConversation() async throws {
        let agent = loop(ScriptedClient([.reply(response("end_turn", [.text("ok")]))]))
        _ = try await agent.run(userText: "x")
        agent.reset()
        #expect(agent.history.isEmpty)
    }
}
