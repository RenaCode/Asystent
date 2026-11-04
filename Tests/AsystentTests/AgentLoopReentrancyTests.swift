import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import AsystentCore
#else
@testable import Asystent
#endif

/// Klient, który w trakcie zapytania wywołuje akcję z zewnątrz (np. Reset albo drugie wysłanie
/// z UI), a potem zwraca zaplanowaną odpowiedź — tak jak użytkownik klikający w czasie „myślenia”.
@MainActor
final class InterruptingClient: LLMClient {
    var steps: [ScriptedClient.Step]
    /// Wywoływane przed zwróceniem odpowiedzi o tym numerze (0 = pierwsze zapytanie).
    var interrupt: [Int: @MainActor () async -> Void] = [:]
    private(set) var requests: [ChatRequest] = []

    init(_ steps: [ScriptedClient.Step]) { self.steps = steps }

    nonisolated func send(_ req: ChatRequest) async throws -> ChatResponse {
        try await handle(req)
    }

    private func handle(_ req: ChatRequest) async throws -> ChatResponse {
        let n = requests.count
        requests.append(req)
        if let action = interrupt[n] { await action() }
        guard !steps.isEmpty else { throw TestError.noMoreSteps }
        switch steps.removeFirst() {
        case .reply(let r): return r
        case .fail(let e): throw e
        }
    }
}

/// Potwierdzający, który w trakcie pytania wywołuje akcję (np. Reset) i odpowiada „tak”.
@MainActor
final class ResettingConfirmer: ActionConfirmer {
    var onConfirm: () -> Void = {}
    var asked = 0
    func confirm(_ question: String) async -> Bool { asked += 1; onConfirm(); return true }
}

@MainActor
struct AgentLoopReentrancyTests {
    let log = CallLog()

    func loop(_ client: InterruptingClient) -> AgentLoop {
        AgentLoop(client: client, registry: ToolRegistry(tools: [FakeTool(name: "a", log: log)]))
    }

    /// Reset w trakcie drugiej tury, a potem błąd sieci: wycofanie tury nie może sięgać
    /// poza (już pustą) historię — wcześniej `removeSubrange(checkpoint...)` wywracał apkę.
    @Test func resetDuringRequestThenErrorDoesNotCrash() async throws {
        let client = InterruptingClient([
            .reply(response("end_turn", [.text("pierwsza")])),
            .fail(TestError.boom),
        ])
        let agent = loop(client)
        _ = try await agent.run(userText: "1")
        client.interrupt[1] = { agent.reset() }
        // Błąd porzuconej tury (np. 401, brak sieci) nie może wrócić jako komunikat w nowej rozmowie.
        await #expect(throws: CancellationError.self) { try await agent.run(userText: "2") }
        #expect(agent.history.isEmpty)
    }

    @Test func resetDuringRequestThenRefusalDoesNotCrash() async throws {
        let client = InterruptingClient([
            .reply(response("end_turn", [.text("pierwsza")])),
            .reply(response("refusal", [])),
        ])
        let agent = loop(client)
        _ = try await agent.run(userText: "1")
        client.interrupt[1] = { agent.reset() }
        await #expect(throws: CancellationError.self) { try await agent.run(userText: "2") }
        #expect(agent.history.isEmpty)
    }

    /// Odpowiedź, która przyszła po Resecie, należy do porzuconej rozmowy: nie trafia do nowej
    /// historii (inaczej nowa rozmowa zaczynałaby się od wiadomości asystenta).
    @Test func replyArrivingAfterResetIsDiscarded() async throws {
        let client = InterruptingClient([
            .reply(response("end_turn", [.text("stara")])),
            .reply(response("end_turn", [.text("nowa")])),
        ])
        let agent = loop(client)
        client.interrupt[0] = { agent.reset() }
        _ = try? await agent.run(userText: "stare pytanie")
        #expect(agent.history.isEmpty)

        #expect(try await agent.run(userText: "nowe pytanie") == "nowa")
        #expect(client.requests.last?.messages.map(\.role) == ["user"])
    }

    /// Wynik narzędzia z porzuconej rozmowy też nie trafia do nowej historii.
    @Test func toolResultAfterResetIsDiscarded() async throws {
        let client = InterruptingClient([
            .reply(response("tool_use", [toolUse("t1", "a")])),
            .reply(response("end_turn", [.text("ok")])),
        ])
        let agent = loop(client)
        client.interrupt[0] = { agent.reset() }
        await #expect(throws: CancellationError.self) { try await agent.run(userText: "x") }
        #expect(log.inputs.isEmpty)
        #expect(agent.history.isEmpty)
        #expect(client.requests.count == 1)
    }

    /// Reset w czasie pytania o potwierdzenie przy kilku wywołaniach narzędzi w jednej odpowiedzi:
    /// „tak” z porzuconej rozmowy nie wykonuje akcji, a kolejne wywołania nie idą bez pytania.
    @Test func resetDuringConfirmationRunsNoToolOfTheAbandonedTurn() async throws {
        let client = InterruptingClient([
            .reply(response("tool_use", [toolUse("t1", "rm"), toolUse("t2", "rm"), toolUse("t3", "a")])),
            .reply(response("end_turn", [.text("ok")])),
        ])
        let confirmer = ResettingConfirmer()
        let agent = AgentLoop(
            client: client,
            registry: ToolRegistry(tools: [FakeTool(name: "rm", log: log, needsConfirmation: true),
                                           FakeTool(name: "a", log: log)]),
            confirmer: confirmer)
        confirmer.onConfirm = { agent.reset() }
        await #expect(throws: CancellationError.self) { try await agent.run(userText: "usuń") }
        #expect(log.inputs.isEmpty)
        #expect(confirmer.asked == 1)
        #expect(agent.history.isEmpty)
        #expect(client.requests.count == 1)
    }

    /// Drugie wysłanie, zanim pierwsza tura się skończy (np. wpisany tekst w czasie pytania
    /// o potwierdzenie): bez blokady obie tury przeplatały historię, a API odrzucało
    /// `tool_use` bez `tool_result`. Drugie wywołanie ma się nie udać, pierwsze — dokończyć.
    @Test func concurrentRunIsRejectedAndFirstTurnCompletes() async throws {
        let client = InterruptingClient([
            .reply(response("tool_use", [toolUse("t1", "a")])),
            .reply(response("end_turn", [.text("gotowe")])),
        ])
        let agent = loop(client)
        var secondError: (any Error)?
        client.interrupt[0] = {
            do { _ = try await agent.run(userText: "wtrącenie") } catch { secondError = error }
        }
        #expect(try await agent.run(userText: "pierwsze") == "gotowe")
        #expect(secondError as? AgentLoop.AgentError == .busy)
        #expect(agent.history.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(client.requests.count == 2)
    }
}
