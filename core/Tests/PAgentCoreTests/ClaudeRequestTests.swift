import Foundation
import Testing

@testable import PAgentCore

@Suite("DeepSeekModel")
struct DeepSeekModelTests {
    @Test("model IDs match the proxy allowlist")
    func modelIdentifiers() {
        // Duplicated in the proxy's ALLOWED_MODELS. Both copies are
        // deliberate: the proxy bounds the cost of a stolen token, the client
        // catches a typo at compile time.
        #expect(DeepSeekModel.v4Pro.rawValue == "deepseek-v4-pro")
        #expect(DeepSeekModel.flash.rawValue == "deepseek-flash")
        #expect(DeepSeekModel.allCases.count == 2)
    }

    @Test("both models support thinking and effort")
    func capabilityFlags() {
        // The Haiku-shaped exceptions are gone: thinking is on by default on
        // both DeepSeek models, and both accept `output_config.effort`
        // (`docs/DEEPSEEK.md`).
        for model in DeepSeekModel.allCases {
            #expect(model.supportsThinking)
            #expect(model.supportsEffort)
        }
    }

    @Test("context and output limits match the published figures")
    func limits() {
        for model in DeepSeekModel.allCases {
            #expect(model.contextWindow == 1_000_000)
            #expect(model.maxOutputTokens == 384_000)
        }
    }

    @Test("only Flash handles images")
    func visionSupport() {
        // v4-pro does not reject an image — it substitutes the literal text
        // `[Unsupported Image]`, which is worth knowing before sending one.
        #expect(DeepSeekModel.flash.supportsVision)
        #expect(DeepSeekModel.v4Pro.supportsVision == false)
    }
}

@Suite("Thinking")
struct ThinkingTests {
    @Test("encodes as enabled or disabled")
    func encodesMode() throws {
        let on = String(
            decoding: try DeterministicJSON.encoder.encode(Thinking.enabled()), as: UTF8.self)
        #expect(on.contains(#""type":"enabled""#))

        let off = String(
            decoding: try DeterministicJSON.encoder.encode(Thinking.disabled), as: UTF8.self)
        #expect(off.contains(#""type":"disabled""#))
    }

    @Test("omits display when thinking is off")
    func displayOnlyWhenEnabled() throws {
        let off = String(
            decoding: try DeterministicJSON.encoder.encode(Thinking.disabled), as: UTF8.self)
        #expect(off.contains("display") == false)
    }

    @Test("carries no budget_tokens")
    func noBudgetTokens() throws {
        // DeepSeek *ignores* `budget_tokens` rather than rejecting it, which
        // is worse than a 400: code could set it, read as though it had an
        // effect, and silently not. The type cannot express it.
        let json = String(
            decoding: try DeterministicJSON.encoder.encode(Thinking.enabled()), as: UTF8.self)
        #expect(json.contains("budget_tokens") == false)
    }

    @Test("decodes adaptive as enabled, which is what DeepSeek does with it")
    func decodesAdaptiveAsEnabled() throws {
        // A request built against Anthropic's surface round-trips, and decodes
        // to the behaviour it will actually get rather than to a mode this
        // backend cannot honour.
        let legacy = Data(#"{"type":"adaptive","display":"summarized"}"#.utf8)
        let decoded = try JSONDecoder().decode(Thinking.self, from: legacy)
        #expect(decoded.isEnabled)
        #expect(decoded.mode == .enabled)
    }

    @Test("rejects an unknown thinking type")
    func rejectsUnknownMode() {
        let nonsense = Data(#"{"type":"turbo"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Thinking.self, from: nonsense)
        }
    }

    @Test("defaults display to summarized, so the UI is not blank")
    func defaultsToSummarized() {
        #expect(Thinking.enabled().display == .summarized)
        #expect(Thinking.enabled(display: .omitted).display == .omitted)
    }
}

@Suite("Effort")
struct EffortTests {
    @Test("models only the three levels DeepSeek actually distinguishes")
    func threeLevels() {
        // `minimal`/`low` → low, `medium`/`high`/`xhigh` → high,
        // `max`/`ultra` → max. Keeping the aliases would invite an effort
        // sweep that measures noise and concludes something false about cost.
        #expect(Effort.allCases.map(\.rawValue).sorted() == ["high", "low", "max"])
    }
}

@Suite("MessagesRequest validation")
struct MessagesRequestValidationTests {
    private let prefix = CacheablePrefix(
        instructions: AgentInstructions("Instructions."),
        profileCard: ProfileCard(
            markdown: "## 画像",
            tokenCount: 10,
            includedSlugs: [],
            omittedSlugs: []
        ),
        tools: PAgentTools.standard
    )

    private func build(
        model: DeepSeekModel = .v4Pro,
        maxTokens: Int = 64_000,
        stream: Bool = true,
        thinking: Thinking? = .enabled(),
        outputConfig: OutputConfig? = OutputConfig(effort: .high),
        toolChoice: ToolChoice? = nil,
        messages: [ClaudeMessage] = [.user([.text("hi")])]
    ) throws -> MessagesRequest {
        try MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            stream: stream,
            thinking: thinking,
            outputConfig: outputConfig,
            toolChoice: toolChoice,
            prefix: prefix,
            messages: messages
        )
    }

    @Test("accepts a well-formed streaming request")
    func acceptsValid() throws {
        let request = try build()
        #expect(request.stream)
        #expect(request.model == .v4Pro)
    }

    @Test("requires streaming above the non-streaming ceiling")
    func requiresStreamingForLargeOutputs() {
        // §7.3: a non-streaming request over ~16k races an HTTP timeout, and
        // the resulting 524 looks like a proxy bug rather than a client one.
        #expect(throws: ClaudeRequestError.streamingRequiredForMaxTokens(
            maxTokens: 64_000, ceiling: 16_000
        )) {
            try build(maxTokens: 64_000, stream: false)
        }
    }

    @Test("allows a large non-streaming request at exactly the ceiling")
    func ceilingIsInclusive() throws {
        let request = try build(maxTokens: 16_000, stream: false)
        #expect(request.maxTokens == 16_000)
    }

    @Test("rejects max_tokens above the model's own limit")
    func rejectsOverModelLimit() {
        // Both DeepSeek models cap at 384K.
        #expect(throws: ClaudeRequestError.maxTokensExceedsModelLimit(
            maxTokens: 400_000, limit: 384_000, model: .flash
        )) {
            try build(model: .flash, maxTokens: 400_000, thinking: .disabled, outputConfig: nil)
        }
    }

    @Test("rejects a forced tool choice while thinking is enabled")
    func rejectsForcedToolChoiceWithThinking() {
        // DeepSeek returns a 400 for `tool_choice: {"type": "tool"}` in
        // thinking mode (`docs/DEEPSEEK.md`). Caught at construction so it
        // surfaces at the call site rather than mid-turn from the server.
        #expect(throws: ClaudeRequestError.forcedToolChoiceRequiresThinkingDisabled) {
            try build(thinking: .enabled(), toolChoice: .tool(name: "search_calendar"))
        }
    }

    @Test("rejects a forced tool choice when thinking is merely omitted")
    func rejectsForcedToolChoiceWithDefaultThinking() {
        // The subtle half: thinking is **on by default** on both models, so a
        // nil `thinking` is not "off". Checking only for an explicit
        // `.enabled()` would let this through to a server-side 400.
        #expect(throws: ClaudeRequestError.forcedToolChoiceRequiresThinkingDisabled) {
            try build(thinking: nil, toolChoice: .tool(name: "search_calendar"))
        }
    }

    @Test("allows a forced tool choice once thinking is disabled")
    func allowsForcedToolChoiceWithoutThinking() throws {
        let request = try build(
            thinking: .disabled,
            toolChoice: .tool(name: "search_calendar")
        )
        #expect(request.toolChoice == .tool(name: "search_calendar"))
        #expect(request.thinking?.isEnabled == false)
    }

    @Test("allows auto and none tool choices with thinking on")
    func allowsUnforcedToolChoices() throws {
        #expect(try build(toolChoice: .auto).toolChoice == .auto)
        #expect(try build(toolChoice: .none).toolChoice == .none)
    }

    @Test("builds the Flash fallback request §6.1 needs")
    func flashFallbackIsExpressible() throws {
        // R2's degradation path, now on Flash. Thinking is explicitly off:
        // batch classification does not want reasoning, and omitting the field
        // would enable it.
        let request = try build(
            model: .flash,
            maxTokens: 4_000,
            thinking: .disabled,
            outputConfig: nil
        )
        #expect(request.thinking?.isEnabled == false)
        #expect(request.outputConfig == nil)
    }

    @Test("rejects an empty conversation")
    func rejectsEmptyMessages() {
        #expect(throws: ClaudeRequestError.emptyMessages) {
            try build(messages: [])
        }
    }

    @Test("requires the first message to be from the user")
    func rejectsAssistantFirst() {
        #expect(throws: ClaudeRequestError.firstMessageMustBeUser(actual: .assistant)) {
            try build(messages: [.assistant([.text("unprompted")])])
        }
    }
}

@Suite("Request encoding")
struct RequestEncodingTests {
    private let prefix = CacheablePrefix(
        instructions: AgentInstructions("Instructions."),
        profileCard: ProfileCard(
            markdown: "## 画像\n口味：川菜。",
            tokenCount: 10,
            includedSlugs: [],
            omittedSlugs: []
        ),
        tools: PAgentTools.standard
    )

    private func encodedBody(_ messages: [ClaudeMessage]) throws -> String {
        let request = try MessagesRequest(
            model: .v4Pro,
            maxTokens: 64_000,
            prefix: prefix,
            messages: messages
        )
        return String(decoding: try request.encoded(), as: UTF8.self)
    }

    @Test("emits the §7.3 request shape")
    func emitsExpectedShape() throws {
        let json = try encodedBody([.user([.text("周六下午安排点事")])])

        #expect(json.contains("\"model\":\"deepseek-v4-pro\""))
        #expect(json.contains("\"max_tokens\":64000"))
        #expect(json.contains("\"stream\":true"))
        #expect(json.contains("\"type\":\"enabled\""))
        #expect(json.contains("\"effort\":\"high\""))
        #expect(json.contains("\"input_schema\""))
        // Never these — all three return a 400 on 4.7+.
        #expect(json.contains("temperature") == false)
        #expect(json.contains("top_p") == false)
        #expect(json.contains("budget_tokens") == false)
    }

    @Test("encodes a tool_use block with parsed input")
    func encodesToolUse() throws {
        let json = try encodedBody([
            .user([.text("周六几点有空")]),
            .assistant([
                .toolUse(
                    id: "toolu_1",
                    name: "search_calendar",
                    input: ["start": "2026-11-14T00:00:00Z", "end": "2026-11-15T00:00:00Z"]
                )
            ]),
            .user([.toolResult(toolUseID: "toolu_1", content: "free 14:00-18:00", isError: false)]),
        ])

        #expect(json.contains("\"type\":\"tool_use\""))
        #expect(json.contains("\"name\":\"search_calendar\""))
        #expect(json.contains("\"tool_use_id\":\"toolu_1\""))
        #expect(json.contains("\"content\":\"free 14:00-18:00\""))
    }

    @Test("omits is_error when false, keeping equivalent requests byte-identical")
    func omitsFalseIsError() throws {
        let ok = try encodedBody([
            .user([.text("q")]),
            .assistant([.toolUse(id: "t1", name: "get_routine", input: ["day_of_week": 6])]),
            .user([.toolResult(toolUseID: "t1", content: "ok", isError: false)]),
        ])
        #expect(ok.contains("is_error") == false)

        let failed = try encodedBody([
            .user([.text("q")]),
            .assistant([.toolUse(id: "t1", name: "get_routine", input: ["day_of_week": 6])]),
            .user([.toolResult(toolUseID: "t1", content: "calendar denied", isError: true)]),
        ])
        #expect(failed.contains("\"is_error\":true"))
    }

    @Test("round-trips content blocks through Codable")
    func roundTripsBlocks() throws {
        let blocks: [ContentBlock] = [
            .text("plain"),
            .toolUse(id: "t1", name: "search_places", input: ["query": "独立书店"]),
            .toolResult(toolUseID: "t1", content: "3 results", isError: false),
            .thinking(text: "considering", signature: "sig"),
        ]

        let data = try DeterministicJSON.encoder.encode(blocks)
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: data)
        #expect(decoded == blocks)
    }

    @Test("rejects an unknown content block type rather than dropping it")
    func rejectsUnknownBlock() {
        // Silently dropping an unrecognised block would corrupt a replayed
        // assistant turn, which the API then rejects for a different reason.
        let data = Data(#"[{"type":"video","url":"x"}]"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([ContentBlock].self, from: data)
        }
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("decodes integers as integers, not doubles")
    func preservesIntegers() throws {
        // `4096` re-encoding as `4096.0` would change the bytes of a replayed
        // tool_use block and break the cached prefix it sits behind.
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("4096".utf8))
        #expect(decoded == .int(4096))

        let reencoded = String(decoding: try DeterministicJSON.encoder.encode(decoded), as: UTF8.self)
        #expect(reencoded == "4096")
    }

    @Test("round-trips a nested tool input")
    func roundTripsNested() throws {
        let value: JSONValue = [
            "from": ["latitude": .double(30.25), "longitude": .double(120.16)],
            "mode": "transit",
            "depart_at": "2026-11-14T14:00:00+08:00",
        ]

        let data = try DeterministicJSON.encoder.encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("reads tool arguments by parsing, never by string matching")
    func accessorsReadParsedValues() throws {
        // §7.3: escaping behaviour differs between models, so a substring
        // check that works on one silently mismatches on another.
        let raw = Data(#"{"query":"独立书店","radius_meters":2000,"open_at":null}"#.utf8)
        let input = try JSONDecoder().decode(JSONValue.self, from: raw)

        #expect(input["query"]?.stringValue == "独立书店")
        #expect(input["radius_meters"]?.intValue == 2000)
        #expect(input["open_at"] == .null)
        #expect(input["missing"] == nil)
    }

    @Test("reads an integer argument the model wrote as a float")
    func tolerantIntegerReading() throws {
        // A model asked for `day_of_week: 6` may emit `6` or `6.0`.
        let asFloat = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"day_of_week":6.0}"#.utf8))
        #expect(asFloat["day_of_week"]?.intValue == 6)
        // But a genuine fraction is not silently truncated.
        let fractional = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"x":6.5}"#.utf8))
        #expect(fractional["x"]?.intValue == nil)
        #expect(fractional["x"]?.doubleValue == 6.5)
    }

    @Test("sorts object keys on encode")
    func sortsKeys() throws {
        let value: JSONValue = ["zebra": 1, "alpha": 2, "mu": 3]
        let json = String(decoding: try DeterministicJSON.encoder.encode(value), as: UTF8.self)
        #expect(json == #"{"alpha":2,"mu":3,"zebra":1}"#)
    }
}

@Suite("Tool surface")
struct ToolSurfaceTests {
    @Test("no tool can write to the calendar")
    func noMutatingTools() {
        // The most load-bearing security decision in the design (§7.2, §9.4):
        // the model can only ever produce an `ItineraryProposal`, which the
        // user sees and confirms. Shared web content is untrusted input, so a
        // prompt-injected model must have no path to EventKit at all.
        //
        // Adding a write tool here would convert that structural guarantee
        // into a prompt-engineering one. This test is the tripwire.
        let forbidden = ["create", "write", "add", "delete", "update", "modify", "remove", "commit", "save", "set"]

        for name in PAgentTools.standard.names {
            for verb in forbidden {
                #expect(
                    name.contains(verb) == false,
                    "tool `\(name)` looks like a mutation; writes must stay out of the tool set (§7.2)"
                )
            }
        }
    }

    @Test("every tool is a read: search, get, or lookup")
    func allToolsAreReads() {
        for name in PAgentTools.standard.names {
            let isRead = name.hasPrefix("search_") || name.hasPrefix("get_")
            #expect(isRead, "tool `\(name)` does not read like a query")
        }
    }

    @Test("create_calendar_events specifically does not exist")
    func calendarWriteToolIsAbsent() {
        #expect(PAgentTools.standard.definition(named: "create_calendar_events") == nil)
    }

    @Test("every tool has a schema the model can rely on")
    func schemasAreWellFormed() {
        for tool in PAgentTools.standard.tools {
            #expect(tool.description.isEmpty == false)
            #expect(tool.inputSchema["type"]?.stringValue == "object")
            #expect(tool.inputSchema["properties"]?.objectValue != nil)
            #expect(tool.inputSchema["required"]?.arrayValue != nil)
            // `additionalProperties: false` keeps the model from inventing
            // arguments the device-side executor would ignore.
            #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        }
    }

    @Test("search_calendar documents the title-redaction behaviour")
    func calendarToolDocumentsRedaction() {
        // §7.2 replaces event titles with categories unless the user opts in.
        // The model needs the time structure, not "和 X 谈离职" — and the
        // description is where it learns that is what it is getting.
        let description = PAgentTools.searchCalendar.description
        #expect(description.contains("categor"))
    }
}
