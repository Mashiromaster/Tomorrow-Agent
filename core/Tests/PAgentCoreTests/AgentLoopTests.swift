import Foundation
import Testing

@testable import PAgentCore

/// Replays a scripted sequence of rounds and records what it was sent.
///
/// Each element of `rounds` is one turn's worth of events, so a test can set
/// up "ask for two tools, then finish" and assert on the message array the
/// loop built in between.
private final class ScriptedTransport: MessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[StreamEvent]]
    private(set) var received: [MessagesRequest] = []

    init(rounds: [[StreamEvent]]) {
        self.rounds = rounds
    }

    func send(_ request: MessagesRequest) async throws -> AsyncThrowingStream<StreamEvent, any Error> {
        let events: [StreamEvent] = lock.withLock {
            received.append(request)
            return rounds.isEmpty ? [] : rounds.removeFirst()
        }

        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Fails the whole stream, to exercise transport-level errors.
private struct FailingTransport: MessagesTransport {
    struct Failure: Error, Equatable {}

    func send(_ request: MessagesRequest) async throws -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: Failure())
        }
    }
}

/// Records calls, optionally failing or blocking, so concurrency and error
/// handling can be observed.
private final class RecordingExecutor: ToolExecuting, @unchecked Sendable {
    struct ToolFailure: Error {}

    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var peakConcurrency = 0
    private var active = 0

    private let failing: Set<String>
    private let delay: Duration

    init(failing: Set<String> = [], delay: Duration = .zero) {
        self.failing = failing
        self.delay = delay
    }

    func execute(name: String, input: JSONValue) async throws -> String {
        lock.withLock {
            calls.append(name)
            active += 1
            peakConcurrency = max(peakConcurrency, active)
        }
        defer { lock.withLock { active -= 1 } }

        if delay != .zero { try? await Task.sleep(for: delay) }
        if failing.contains(name) { throw ToolFailure() }
        return "result from \(name)"
    }
}

private let testPrefix = CacheablePrefix(
    instructions: AgentInstructions("You are PAgent. Propose, never commit."),
    profileCard: ProfileCard(
        markdown: "## 画像\n口味：川菜。",
        tokenCount: 20,
        includedSlugs: [],
        omittedSlugs: []
    ),
    tools: PAgentTools.standard
)

private func baseRequest() throws -> MessagesRequest {
    try MessagesRequest(
        model: .v4Pro,
        maxTokens: 64_000,
        prefix: testPrefix,
        messages: [.user([.text("周六下午安排点事")])]
    )
}

private func finished(_ reason: StopReason, output: Int = 100, cacheRead: Int = 0) -> StreamEvent {
    .finished(
        stopReason: reason,
        usage: Usage(inputTokens: 50, outputTokens: output, cacheReadInputTokens: cacheRead)
    )
}

@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("returns the assistant text when the model finishes without tools")
    func simpleTurn() async throws {
        let transport = ScriptedTransport(rounds: [[
            .started(Usage(inputTokens: 50, cacheReadInputTokens: 12_288)),
            .textDelta("周六"),
            .textDelta("下午有空"),
            finished(.endTurn, cacheRead: 12_288),
        ]])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        let turn = try await loop.run(try baseRequest())

        #expect(turn.assistantText == "周六下午有空")
        #expect(turn.rounds == 1)
        #expect(turn.cacheHit)
    }

    @Test("executes a requested tool and continues the turn")
    func singleToolRound() async throws {
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_calendar", input: ["start": "a", "end": "b"]),
                finished(.toolUse),
            ],
            [
                .textDelta("你周六 14:00 之后有空"),
                finished(.endTurn),
            ],
        ])
        let executor = RecordingExecutor()
        let loop = AgentLoop(transport: transport, executor: executor)

        let turn = try await loop.run(try baseRequest())

        #expect(executor.calls == ["search_calendar"])
        #expect(turn.rounds == 2)
        #expect(turn.assistantText == "你周六 14:00 之后有空")
    }

    @Test("puts every tool_result in a single user message")
    func toolResultsAreMerged() async throws {
        // §7.3's quietest trap: splitting results across several user
        // messages is accepted by the API and then silently stops the model
        // issuing parallel tool calls for the rest of the conversation. The
        // symptom is a latency regression with no error anywhere.
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_places", input: ["query": "书店"]),
                .toolUse(id: "t2", name: "search_places", input: ["query": "咖啡"]),
                .toolUse(id: "t3", name: "get_travel_time", input: ["mode": "transit"]),
                finished(.toolUse),
            ],
            [.textDelta("done"), finished(.endTurn)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        _ = try await loop.run(try baseRequest())

        // Second request carries the history the loop assembled.
        let followUp = transport.received[1]
        let userMessages = followUp.messages.filter { $0.role == .user }

        // The original question, plus exactly one message holding all three
        // results — not three messages.
        #expect(userMessages.count == 2)
        let resultBlocks = userMessages[1].content.filter {
            if case .toolResult = $0 { return true }
            return false
        }
        #expect(resultBlocks.count == 3)
    }

    @Test("orders tool results to match the tool_use blocks")
    func resultOrderMatchesCalls() async throws {
        // They complete out of order under concurrency; the API pairs them by
        // id, but keeping the order aligned makes transcripts readable and
        // avoids depending on that leniency.
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_calendar", input: [:]),
                .toolUse(id: "t2", name: "search_places", input: [:]),
                .toolUse(id: "t3", name: "get_routine", input: [:]),
                finished(.toolUse),
            ],
            [finished(.endTurn)],
        ])
        let loop = AgentLoop(
            transport: transport,
            executor: RecordingExecutor(delay: .milliseconds(5))
        )

        _ = try await loop.run(try baseRequest())

        let results = transport.received[1].messages.last!.content.compactMap { block -> String? in
            if case .toolResult(let id, _, _) = block { return id }
            return nil
        }
        #expect(results == ["t1", "t2", "t3"])
    }

    @Test("runs a round's tools concurrently")
    func toolsRunConcurrently() async throws {
        // §7.4 point 2: three MapKit searches in one round should cost one
        // round of latency, not three. They are independent.
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_places", input: [:]),
                .toolUse(id: "t2", name: "search_places", input: [:]),
                .toolUse(id: "t3", name: "search_places", input: [:]),
                finished(.toolUse),
            ],
            [finished(.endTurn)],
        ])
        let executor = RecordingExecutor(delay: .milliseconds(30))
        let loop = AgentLoop(transport: transport, executor: executor)

        _ = try await loop.run(try baseRequest())

        #expect(executor.peakConcurrency > 1)
    }

    @Test("returns a failed tool as an error result rather than dropping it")
    func toolFailureBecomesErrorResult() async throws {
        // An unanswered `tool_use` makes the API reject the next request. And
        // a described failure is often something the model can route around
        // on its own — "calendar access denied" is actionable.
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_calendar", input: [:]),
                .toolUse(id: "t2", name: "search_places", input: [:]),
                finished(.toolUse),
            ],
            [.textDelta("recovered"), finished(.endTurn)],
        ])
        let loop = AgentLoop(
            transport: transport,
            executor: RecordingExecutor(failing: ["search_calendar"])
        )

        let turn = try await loop.run(try baseRequest())

        let results = transport.received[1].messages.last!.content.compactMap { block -> (String, Bool)? in
            if case .toolResult(let id, _, let isError) = block { return (id, isError) }
            return nil
        }
        #expect(results.count == 2)
        #expect(results.first { $0.0 == "t1" }?.1 == true)
        #expect(results.first { $0.0 == "t2" }?.1 == false)
        #expect(turn.assistantText == "recovered")
    }

    @Test("resumes a pause_turn without injecting a continue message")
    func pauseTurnResumes() async throws {
        // §7.3: the assistant turn goes back unchanged and the server picks
        // up where it left off. Appending a "please continue" user message
        // corrupts the turn.
        let transport = ScriptedTransport(rounds: [
            [.textDelta("partial"), finished(.pauseTurn)],
            [.textDelta(" complete"), finished(.endTurn)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        let turn = try await loop.run(try baseRequest())

        #expect(turn.rounds == 2)
        #expect(turn.assistantText == "partial complete")

        // Exactly one user message — the original question.
        let userMessages = transport.received[1].messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        let injectedContinue = userMessages.contains { message in
            message.content.contains { block in
                if case .text(let text) = block { return text.lowercased().contains("continue") }
                return false
            }
        }
        #expect(injectedContinue == false)
    }

    @Test("replays thinking blocks verbatim across rounds")
    func replaysThinkingBlocks() async throws {
        // Editing or dropping a thinking block makes the API reject the turn.
        let transport = ScriptedTransport(rounds: [
            [
                .thinking(text: "需要先查日历", signature: "sigXYZ"),
                .toolUse(id: "t1", name: "search_calendar", input: [:]),
                finished(.toolUse),
            ],
            [finished(.endTurn)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        _ = try await loop.run(try baseRequest())

        let assistantBlocks = transport.received[1].messages
            .first { $0.role == .assistant }?.content ?? []
        #expect(assistantBlocks.contains(.thinking(text: "需要先查日历", signature: "sigXYZ")))
    }

    @Test("throws on a refusal instead of reading an empty content array")
    func refusalThrows() async throws {
        // §7.3's crash risk: a refusal is HTTP 200 with empty `content`, so
        // `content[0]` goes out of bounds. The check comes first.
        let transport = ScriptedTransport(rounds: [[finished(.refusal, output: 0)]])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        await #expect(throws: AgentLoopError.refused) {
            try await loop.run(try baseRequest())
        }
    }

    @Test("reports a truncated output distinctly from a finished one")
    func truncationThrows() async throws {
        let transport = ScriptedTransport(rounds: [[.textDelta("half an ans"), finished(.maxTokens)]])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        await #expect(throws: AgentLoopError.outputTruncated) {
            try await loop.run(try baseRequest())
        }
    }

    @Test("distinguishes a context-window overflow from max_tokens")
    func contextOverflowThrows() async throws {
        // Different remedies: one wants a bigger max_tokens, the other wants
        // the conversation compacted.
        let transport = ScriptedTransport(rounds: [[finished(.modelContextWindowExceeded)]])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        await #expect(throws: AgentLoopError.contextWindowExceeded) {
            try await loop.run(try baseRequest())
        }
    }

    @Test("stops at the round limit rather than looping on the user's quota")
    func roundLimitIsEnforced() async throws {
        let endlessToolCalls = Array(
            repeating: [
                StreamEvent.toolUse(id: "t", name: "search_places", input: [:]),
                finished(.toolUse),
            ],
            count: 10
        )
        let loop = AgentLoop(
            transport: ScriptedTransport(rounds: endlessToolCalls),
            executor: RecordingExecutor(),
            roundLimit: 3
        )

        await #expect(throws: AgentLoopError.roundLimitReached(limit: 3)) {
            try await loop.run(try baseRequest())
        }
    }

    @Test("propagates a transport failure")
    func transportFailurePropagates() async throws {
        let loop = AgentLoop(transport: FailingTransport(), executor: RecordingExecutor())

        await #expect(throws: FailingTransport.Failure.self) {
            try await loop.run(try baseRequest())
        }
    }

    @Test("accumulates usage across every round")
    func accumulatesUsage() async throws {
        // Cost attribution (R5) is per *turn*, not per request, and a turn
        // can hit cache on the first round and miss on a later one as the
        // message array grows.
        let transport = ScriptedTransport(rounds: [
            [
                .toolUse(id: "t1", name: "search_calendar", input: [:]),
                finished(.toolUse, output: 100, cacheRead: 12_288),
            ],
            [finished(.endTurn, output: 250, cacheRead: 12_288)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        let turn = try await loop.run(try baseRequest())

        #expect(turn.usage.outputTokens == 350)
        #expect(turn.usage.cacheReadInputTokens == 24_576)
        #expect(turn.usage.inputTokens == 100)
    }

    @Test("keeps the cacheable prefix identical across every round of a turn")
    func prefixIsStableAcrossRounds() async throws {
        // A multi-round turn is where R8 pays off most: rounds 2..n should
        // all read the prefix from cache. If the loop rebuilt the prefix per
        // round, every round would pay full input price.
        let transport = ScriptedTransport(rounds: [
            [.toolUse(id: "t1", name: "search_calendar", input: [:]), finished(.toolUse)],
            [.toolUse(id: "t2", name: "search_places", input: [:]), finished(.toolUse)],
            [finished(.endTurn)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        _ = try await loop.run(try baseRequest())

        #expect(transport.received.count == 3)
        let prefixes = try transport.received.map { try $0.encodedCacheablePrefix() }
        #expect(Set(prefixes).count == 1)
    }

    @Test("reports activity for the UI as it happens")
    func reportsActivity() async throws {
        // §7.4 point 3: streaming reasoning and text as they arrive is what
        // keeps a multi-second turn from feeling stalled.
        let transport = ScriptedTransport(rounds: [
            [
                .thinkingDelta("查日历"),
                .toolUse(id: "t1", name: "search_calendar", input: [:]),
                finished(.toolUse),
            ],
            [.textDelta("好"), finished(.endTurn)],
        ])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        let recorder = ActivityRecorder()
        _ = try await loop.run(try baseRequest()) { recorder.append($0) }

        let activities = recorder.activities
        #expect(activities.contains(.thinking("查日历")))
        #expect(activities.contains(.callingTool(name: "search_calendar")))
        #expect(activities.contains(.toolFinished(name: "search_calendar", failed: false)))
        #expect(activities.contains(.text("好")))
        #expect(activities.contains { if case .roundCompleted = $0 { return true } else { return false } })
    }

    @Test("reports a tool failure in the activity stream")
    func reportsToolFailure() async throws {
        let transport = ScriptedTransport(rounds: [
            [.toolUse(id: "t1", name: "search_calendar", input: [:]), finished(.toolUse)],
            [finished(.endTurn)],
        ])
        let loop = AgentLoop(
            transport: transport,
            executor: RecordingExecutor(failing: ["search_calendar"])
        )

        let recorder = ActivityRecorder()
        _ = try await loop.run(try baseRequest()) { recorder.append($0) }

        #expect(recorder.activities.contains(.toolFinished(name: "search_calendar", failed: true)))
    }

    @Test("returns a history that can be continued from")
    func historyIsResumable() async throws {
        let transport = ScriptedTransport(rounds: [[.textDelta("第一轮"), finished(.endTurn)]])
        let loop = AgentLoop(transport: transport, executor: RecordingExecutor())

        let turn = try await loop.run(try baseRequest())

        // The returned history ends with the assistant's reply, so appending
        // the next user message produces a valid request.
        #expect(turn.messages.last?.role == .assistant)
        let continued = try MessagesRequest(
            model: .v4Pro,
            maxTokens: 64_000,
            prefix: testPrefix,
            messages: turn.messages + [.user([.text("再加一项")])]
        )
        #expect(continued.messages.count == turn.messages.count + 1)
    }
}

/// Collects activity callbacks, which arrive from the loop's task group.
private final class ActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentActivity] = []

    func append(_ activity: AgentActivity) {
        lock.withLock { storage.append(activity) }
    }

    var activities: [AgentActivity] {
        lock.withLock { storage }
    }
}
