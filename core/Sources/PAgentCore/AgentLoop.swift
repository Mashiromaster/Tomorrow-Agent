import Foundation

/// Sends a request through the proxy and streams the response back.
///
/// Abstracted so the loop can be tested without a network, and because the
/// `URLSession` implementation needs iOS types that do not belong in this
/// package.
public protocol MessagesTransport: Sendable {
    func send(_ request: MessagesRequest) async throws -> AsyncThrowingStream<StreamEvent, any Error>
}

/// Runs a tool on the device.
///
/// Every tool in `PAgentTools.standard` is read-only, so an implementation of
/// this protocol can never mutate the user's calendar (§7.2). Returning a
/// `String` keeps the result shape identical to what goes back on the wire.
public protocol ToolExecuting: Sendable {
    func execute(name: String, input: JSONValue) async throws -> String
}

/// Progress for the UI, forwarded as it happens.
///
/// §7.4 relies on streaming for *perceived* latency: a multi-round tool-using
/// turn takes real seconds, and showing summarised reasoning and text as they
/// arrive is what keeps it from feeling stalled.
public enum AgentActivity: Sendable, Hashable {
    case thinking(String)
    case text(String)
    case callingTool(name: String)
    case toolFinished(name: String, failed: Bool)
    case roundCompleted(index: Int, usage: Usage)
}

public enum AgentLoopError: Error, Sendable, Equatable {
    /// The model declined. §7.3: check this *before* reading `content`, which
    /// is empty on a refusal.
    case refused
    /// `max_tokens` hit mid-answer — the output is truncated, not complete.
    case outputTruncated
    case contextWindowExceeded
    /// The loop made no progress within its round budget.
    case roundLimitReached(limit: Int)
    /// The model asked for a tool that is not in the tool set. Returned to the
    /// model as a tool error rather than thrown, so this is for the case where
    /// it persists.
    case unknownTool(name: String)
}

/// One completed turn.
public struct AgentTurn: Sendable, Hashable {
    public let assistantText: String
    /// Full message history including this turn, ready to continue from.
    public let messages: [ClaudeMessage]
    public let usage: Usage
    public let rounds: Int

    /// Sum over all rounds. A turn can hit cache on round one and miss on a
    /// later one if the growing message array pushed past a breakpoint.
    public var cacheHit: Bool { usage.cacheReadInputTokens > 0 }
}

/// The agent loop — **on the device**, by design (§3.1).
///
/// Running it here rather than in the proxy is what lets the proxy stay
/// stateless and ignorant of personal data: the device owns the `messages`
/// array, executes tools in-process against EventKit and MapKit, and appends
/// results locally. The proxy only ever adds an API key and forwards bytes.
///
/// The cost is an extra round trip per tool round on a mobile network, which
/// §7.4 mitigates with prefetch, parallel execution, and streaming.
public struct AgentLoop: Sendable {
    /// Enough for a realistic multi-day plan; low enough that a model stuck
    /// in a tool loop stops burning the user's quota.
    public static let defaultRoundLimit = 12

    private let transport: any MessagesTransport
    private let executor: any ToolExecuting
    private let roundLimit: Int

    public init(
        transport: any MessagesTransport,
        executor: any ToolExecuting,
        roundLimit: Int = AgentLoop.defaultRoundLimit
    ) {
        self.transport = transport
        self.executor = executor
        self.roundLimit = roundLimit
    }

    /// Runs until the model stops asking for tools.
    ///
    /// `onActivity` is called on the loop's task as events arrive.
    public func run(
        _ request: MessagesRequest,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> AgentTurn {
        var messages = request.messages
        var total = Usage()
        var transcript = ""
        var round = 0

        while round < roundLimit {
            round += 1

            let turnRequest = try MessagesRequest(
                model: request.model,
                maxTokens: request.maxTokens,
                stream: request.stream,
                thinking: request.thinking,
                outputConfig: request.outputConfig,
                prefix: request.prefix,
                messages: messages
            )

            let round_ = try await collect(turnRequest, onActivity: onActivity)
            total.add(round_.usage)
            transcript += round_.text
            onActivity(.roundCompleted(index: round, usage: round_.usage))

            switch round_.stopReason {
            case .refusal:
                // Checked before anything reads `content`: on a refusal the
                // array is empty and indexing it would crash (§7.3).
                throw AgentLoopError.refused

            case .maxTokens:
                throw AgentLoopError.outputTruncated

            case .modelContextWindowExceeded:
                throw AgentLoopError.contextWindowExceeded

            case .pauseTurn:
                // A server-side tool hit its iteration cap. The assistant turn
                // goes back unchanged and the server resumes; appending a
                // "continue" user message here would corrupt the turn.
                messages.append(.assistant(round_.assistantBlocks))
                continue

            case .toolUse:
                messages.append(.assistant(round_.assistantBlocks))
                let results = await executeConcurrently(round_.toolCalls, onActivity: onActivity)
                // **One** user message holding every `tool_result`. Splitting
                // them across messages is accepted by the API and silently
                // stops the model issuing parallel tool calls thereafter
                // (§7.3) — a performance regression with no error to catch.
                messages.append(.user(results))
                continue

            case .endTurn, .stopSequence, .none:
                messages.append(.assistant(round_.assistantBlocks))
                return AgentTurn(
                    assistantText: transcript,
                    messages: messages,
                    usage: total,
                    rounds: round
                )
            }
        }

        throw AgentLoopError.roundLimitReached(limit: roundLimit)
    }

    // MARK: - One round

    private struct RoundResult {
        var text = ""
        var assistantBlocks: [ContentBlock] = []
        var toolCalls: [(id: String, name: String, input: JSONValue)] = []
        var usage = Usage()
        var stopReason: StopReason?
    }

    private func collect(
        _ request: MessagesRequest,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> RoundResult {
        var result = RoundResult()

        for try await event in try await transport.send(request) {
            switch event {
            case .started(let usage):
                result.usage = usage

            case .thinkingDelta(let text):
                onActivity(.thinking(text))

            case .textDelta(let text):
                result.text += text
                onActivity(.text(text))

            case .thinking(let text, let signature):
                // Replayed verbatim on the next round. Editing or dropping a
                // thinking block makes the API reject the turn.
                result.assistantBlocks.append(.thinking(text: text, signature: signature))

            case .toolUse(let id, let name, let input):
                result.assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                result.toolCalls.append((id: id, name: name, input: input))

            case .finished(let stopReason, let usage):
                result.stopReason = stopReason
                result.usage = usage
            }
        }

        // Text lands after the thinking blocks, matching the order the API
        // returned it in.
        if !result.text.isEmpty {
            let insertionPoint = result.assistantBlocks.firstIndex { block in
                if case .toolUse = block { return true }
                return false
            }
            result.assistantBlocks.insert(
                .text(result.text),
                at: insertionPoint ?? result.assistantBlocks.endIndex
            )
        }

        return result
    }

    // MARK: - Tools

    /// Runs the round's tool calls concurrently.
    ///
    /// §7.4 point 2: a model that asks for three `search_places` lookups in
    /// one round should pay for one round trip, not three. MapKit searches are
    /// independent, so the only ordering requirement is on the *results*.
    private func executeConcurrently(
        _ calls: [(id: String, name: String, input: JSONValue)],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async -> [ContentBlock] {
        guard !calls.isEmpty else { return [] }

        let executor = self.executor
        let outcomes = await withTaskGroup(
            of: (Int, ContentBlock).self,
            returning: [(Int, ContentBlock)].self
        ) { group in
            for (offset, call) in calls.enumerated() {
                group.addTask {
                    onActivity(.callingTool(name: call.name))
                    do {
                        let output = try await executor.execute(name: call.name, input: call.input)
                        onActivity(.toolFinished(name: call.name, failed: false))
                        return (
                            offset,
                            .toolResult(toolUseID: call.id, content: output, isError: false)
                        )
                    } catch {
                        onActivity(.toolFinished(name: call.name, failed: true))
                        // A failed tool still returns a `tool_result`. Dropping
                        // it leaves a `tool_use` unanswered, which the API
                        // rejects — and the model can often recover from a
                        // described failure on its own.
                        return (
                            offset,
                            .toolResult(
                                toolUseID: call.id,
                                content: "tool failed: \(error.localizedDescription)",
                                isError: true
                            )
                        )
                    }
                }
            }

            var collected: [(Int, ContentBlock)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        // Results are ordered to match the `tool_use` blocks, even though they
        // completed out of order.
        return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

extension Usage {
    fileprivate mutating func add(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
    }
}
