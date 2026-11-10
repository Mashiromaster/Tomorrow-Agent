import Foundation

// MARK: - Model

/// The models the proxy permits.
///
/// The allowlist exists on both sides: here so a typo fails to compile, and in
/// the proxy so a stolen device token cannot reach an expensive model.
///
/// ## Why there are two, not three
///
/// §7.1 routes to three Claude tiers — Opus for multi-day planning, Sonnet for
/// single-day, Haiku as the on-device fallback. DeepSeek offers two models, and
/// the tiering collapses accordingly: `v4Pro` takes the Opus role, `flash`
/// takes both the Sonnet and the Haiku ones. See ``Router`` for what that does
/// to the routing table.
///
/// Verified facts live in `docs/DEEPSEEK.md`. The two that shape this type:
/// thinking mode is **on by default on both models**, and both accept
/// `output_config.effort` — so the per-model capability flags that existed for
/// Haiku 4.5 are gone.
public enum DeepSeekModel: String, Sendable, Codable, CaseIterable, Hashable {
    /// DeepSeek-V4-Pro. Multi-day, multi-constraint planning (§7.1).
    ///
    /// No vision: an image in the request is replaced with the literal text
    /// `[Unsupported Image]` rather than rejected, which is worth knowing
    /// before sending one.
    case v4Pro = "deepseek-v4-pro"

    /// DeepSeek-V4.1-Flash. Single-day planning, Q&A, and the cloud fallback
    /// for batch classification when the device has no Apple Intelligence or
    /// the on-device guardrail keeps misfiring (R2, R3).
    ///
    /// Supports vision in user messages and `tool_result` content.
    case flash = "deepseek-flash"

    /// Both models support thinking mode, and it is **enabled by default**.
    ///
    /// Kept as a property rather than dropped because the value is still
    /// per-model in principle, and because every call site that asks the
    /// question reads better than one that assumes.
    public var supportsThinking: Bool { true }

    /// Both models accept `output_config.effort`.
    public var supportsEffort: Bool { true }

    /// 1M on both models.
    public var contextWindow: Int { 1_000_000 }

    /// 384K on both models.
    ///
    /// Note the compat layer may *raise* an effective `max_tokens` above the
    /// requested value for some thinking-mode requests, so this is a ceiling
    /// for validation rather than a guarantee of truncation behaviour.
    public var maxOutputTokens: Int { 384_000 }

    public var supportsVision: Bool {
        switch self {
        case .flash: true
        case .v4Pro: false
        }
    }
}

// MARK: - Thinking and effort

/// Thinking mode: on or off.
///
/// ## Why this is two-state rather than `adaptive`
///
/// The Anthropic version of this type could only express `adaptive`, because
/// that was the only on-mode Opus 4.7+ accepted and `budget_tokens` returned a
/// 400. DeepSeek's surface is different: `enabled` and `disabled` are the real
/// states, `adaptive` is *accepted but silently treated as `enabled`*, and
/// `budget_tokens` is ignored rather than rejected.
///
/// A type that could only say `adaptive` would therefore be describing a mode
/// that does not exist here, and would make "thinking off" — which DeepSeek
/// supports and which the §6.1 batch-classification path wants — unexpressible
/// except by passing `nil` and hoping the default is right. It is not: thinking
/// is **on by default** on both models, so omitting the field enables it.
///
/// `budget_tokens` is still absent from this type. It is ignored rather than
/// rejected now, which makes it worse than useless: code could set it, read as
/// if it had an effect, and silently not.
public struct Thinking: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Codable, Hashable {
        case enabled
        case disabled
    }

    /// Whether reasoning is streamed back as `thinking` blocks.
    ///
    /// Not part of DeepSeek's documented surface — it is an Anthropic field the
    /// compat layer does not list. Kept because it is harmless if ignored and
    /// meaningful if honoured; DeepSeek *does* return `thinking` content blocks,
    /// so the question is only whether it can be suppressed.
    public enum Display: String, Sendable, Codable {
        case omitted
        case summarized
    }

    public let mode: Mode
    public let display: Display

    private init(mode: Mode, display: Display) {
        self.mode = mode
        self.display = display
    }

    /// Thinking on. The default for planning (§7.1).
    public static func enabled(display: Display = .summarized) -> Thinking {
        Thinking(mode: .enabled, display: display)
    }

    /// Thinking off.
    ///
    /// For the §6.1 batch-classification path, where reasoning buys nothing and
    /// costs output tokens. Must be explicit: omitting `thinking` enables it.
    public static let disabled = Thinking(mode: .disabled, display: .omitted)

    public var isEnabled: Bool { mode == .enabled }

    private enum CodingKeys: String, CodingKey {
        case type
        case display
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .type)
        // Only meaningful when thinking is on.
        if mode == .enabled {
            try container.encode(display, forKey: .display)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        switch rawType {
        case "enabled":
            mode = .enabled
        case "disabled":
            mode = .disabled
        case "adaptive":
            // Accepted for round-tripping a request built against Anthropic's
            // surface; DeepSeek treats it as `enabled`, so decode it as what it
            // actually does rather than preserving a mode we cannot honour.
            mode = .enabled
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unsupported thinking type: \(rawType)"
            )
        }

        display = try container.decodeIfPresent(Display.self, forKey: .display) ?? .omitted
    }
}

/// Reasoning depth.
///
/// ## Three of these are aliases
///
/// DeepSeek maps requested effort onto three actual levels rather than
/// rejecting unknown values:
///
/// ```
/// minimal, low        → low
/// medium, high, xhigh → high
/// max, ultra          → max
/// ```
///
/// So `medium` and `xhigh` are indistinguishable from `high`. The enum keeps
/// only the three distinct levels, because an `effort` sweep across aliases
/// would measure noise and conclude something false about cost.
public enum Effort: String, Sendable, Codable, CaseIterable, Hashable {
    case low
    case high
    case max
}

public struct OutputConfig: Sendable, Hashable, Codable {
    public let effort: Effort

    public init(effort: Effort) {
        self.effort = effort
    }
}

// MARK: - The cacheable prefix

/// Frozen agent instructions.
///
/// ## The compile-time half of R8
///
/// The initialiser takes a `StaticString`, which can only come from a literal:
/// Swift does not allow interpolation into one. So
///
/// ```swift
/// AgentInstructions("Current time is \(Date())")   // does not compile
/// ```
///
/// is rejected by the compiler, not by a test or a review comment. R8 asks for
/// "系统提示构造函数禁止传入时变参数（类型层面约束）" and this is that constraint:
/// the system prompt physically cannot carry a clock, a UUID, or a per-request
/// counter, because none of those can be spelled as a literal.
///
/// Time belongs in the user turn — see ``currentTimeBlock(at:timeZone:)``.
public struct AgentInstructions: Sendable, Hashable {
    public let text: String

    public init(_ frozen: StaticString) {
        self.text = frozen.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    }
}

/// `tools → system` — the stable region every request shares.
///
/// ## Caching is automatic, and that changes what this type is for
///
/// Against Anthropic this was the *explicitly marked* cached region: §7.3 put a
/// `cache_control` breakpoint on the final system block. DeepSeek caches on
/// disk automatically and **ignores `cache_control`** entirely
/// (`docs/DEEPSEEK.md`), so there is no marker to place and no minimum prefix
/// length to clear.
///
/// What survives is the part that was always doing the real work: byte
/// stability. DeepSeek matches a request against a persisted *cache prefix
/// unit* and requires a **full match** — a single differing byte in this region
/// means no hit, exactly as before. So the R8 guarantees around
/// ``AgentInstructions`` and ``ToolSet`` ordering matter just as much; only the
/// marking mechanism went away.
///
/// The card is last because it is the only part that changes, and only after a
/// nightly digest.
public struct CacheablePrefix: Sendable, Hashable {
    public let instructions: AgentInstructions
    public let profileCard: ProfileCard
    public let tools: ToolSet

    public init(instructions: AgentInstructions, profileCard: ProfileCard, tools: ToolSet) {
        self.instructions = instructions
        self.profileCard = profileCard
        self.tools = tools
    }

    /// Rough token count of the prefix.
    ///
    /// `instructions` and the card are measured; tool JSON is approximated.
    /// Useful for sizing and for the cost model, not for a caching decision —
    /// see the note on ``CacheablePrefix``.
    public func estimatedTokens(using counter: any TokenCounting) throws -> Int {
        let toolsJSON = try DeterministicJSON.encoder.encode(tools.tools)
        let toolsText = String(decoding: toolsJSON, as: UTF8.self)
        return try counter.tokenCount(for: instructions.text)
            + profileCard.tokenCount
            + counter.tokenCount(for: toolsText)
    }
}

// MARK: - Messages

public enum MessageRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
}

public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// Replayed verbatim on the next turn. Editing or dropping a thinking
    /// block breaks the turn; reading it is fine.
    case thinking(text: String, signature: String?)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
        case thinking
        case signature
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
            // Omitted when false: the API defaults it, and an absent key is
            // one fewer byte that can differ between two equivalent requests.
            if isError { try container.encode(true, forKey: .isError) }
        case .thinking(let text, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .thinking)
            try container.encodeIfPresent(signature, forKey: .signature)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decode(String.self, forKey: .content),
                isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        case "thinking":
            self = .thinking(
                text: try container.decode(String.self, forKey: .thinking),
                signature: try container.decodeIfPresent(String.self, forKey: .signature)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unsupported content block type: \(other)"
            )
        }
    }
}

public struct ClaudeMessage: Sendable, Hashable, Codable {
    public let role: MessageRole
    public let content: [ContentBlock]

    public init(role: MessageRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: [ContentBlock]) -> ClaudeMessage {
        ClaudeMessage(role: .user, content: content)
    }

    public static func assistant(_ content: [ContentBlock]) -> ClaudeMessage {
        ClaudeMessage(role: .assistant, content: content)
    }
}

/// The current time, rendered for a **user turn**.
///
/// This is the other half of R8. The clock has to reach the model somehow —
/// "周六下午" is meaningless without it — and this is the sanctioned place:
/// after the cache breakpoint, where a per-request value costs nothing.
/// ``AgentInstructions`` cannot accept it by construction.
public func currentTimeBlock(at now: Date, timeZone: TimeZone) -> ContentBlock {
    let formatStyle = Date.ISO8601FormatStyle(timeZone: timeZone).timeZone(separator: .colon)
    return .text("当前时间：\(now.formatted(formatStyle))（时区 \(timeZone.identifier)）")
}

// MARK: - Request

public enum ClaudeRequestError: Error, Sendable, Equatable {
    case streamingRequiredForMaxTokens(maxTokens: Int, ceiling: Int)
    case maxTokensExceedsModelLimit(maxTokens: Int, limit: Int, model: DeepSeekModel)
    case emptyMessages
    case firstMessageMustBeUser(actual: MessageRole)
    /// `tool_choice: {"type": "tool"}` with thinking enabled returns a 400
    /// (`docs/DEEPSEEK.md`). Caught here so it surfaces at the call site rather
    /// than as a server error mid-turn.
    case forcedToolChoiceRequiresThinkingDisabled
}

/// Which tool the model is allowed or required to call.
///
/// Narrower than Anthropic's surface, because DeepSeek collapses part of it:
/// `any` is **treated as `auto`** and does not force a call, and
/// `disable_parallel_tool_use` is ignored throughout. Modelling `any`
/// separately would promise forcing we do not get, so it is absent.
public enum ToolChoice: Sendable, Hashable, Codable {
    /// The model decides. The default.
    case auto
    /// Tools are available but must not be called.
    case none
    /// Force one named tool. **Requires thinking disabled** — see
    /// ``ClaudeRequestError/forcedToolChoiceRequiresThinkingDisabled``.
    case tool(name: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case .none:
            try container.encode("none", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "auto": self = .auto
        case "none": self = .none
        case "any":
            // Decoded as what it actually does rather than as what it says.
            self = .auto
        case "tool":
            self = .tool(name: try container.decode(String.self, forKey: .name))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unsupported tool_choice: \(other)"
            )
        }
    }
}

public struct MessagesRequest: Sendable, Hashable {
    /// Matches the proxy's own ceiling. Above this a non-streaming request
    /// races an HTTP timeout (§7.3), which surfaces as a 524 that looks like a
    /// proxy bug rather than a client one.
    public static let nonStreamingMaxTokensCeiling = 16_000

    public let model: DeepSeekModel
    public let maxTokens: Int
    public let stream: Bool
    public let thinking: Thinking?
    public let outputConfig: OutputConfig?
    public let toolChoice: ToolChoice?
    public let prefix: CacheablePrefix
    public let messages: [ClaudeMessage]

    public init(
        model: DeepSeekModel,
        maxTokens: Int,
        stream: Bool = true,
        // Explicit rather than nil: thinking is **on by default** on both
        // DeepSeek models, so omitting the field enables it. Spelling it out
        // means the request says what it does.
        thinking: Thinking? = .enabled(),
        outputConfig: OutputConfig? = OutputConfig(effort: .high),
        toolChoice: ToolChoice? = nil,
        prefix: CacheablePrefix,
        messages: [ClaudeMessage]
    ) throws {
        guard let first = messages.first else { throw ClaudeRequestError.emptyMessages }
        guard first.role == .user else {
            throw ClaudeRequestError.firstMessageMustBeUser(actual: first.role)
        }
        guard maxTokens <= model.maxOutputTokens else {
            throw ClaudeRequestError.maxTokensExceedsModelLimit(
                maxTokens: maxTokens, limit: model.maxOutputTokens, model: model
            )
        }
        if !stream, maxTokens > Self.nonStreamingMaxTokensCeiling {
            throw ClaudeRequestError.streamingRequiredForMaxTokens(
                maxTokens: maxTokens, ceiling: Self.nonStreamingMaxTokensCeiling
            )
        }
        // Thinking defaults to on, so a `nil` here means enabled — which is why
        // this checks the effective state rather than just a non-nil value.
        if case .tool = toolChoice, thinking?.isEnabled ?? true {
            throw ClaudeRequestError.forcedToolChoiceRequiresThinkingDisabled
        }

        self.model = model
        self.maxTokens = maxTokens
        self.stream = stream
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.toolChoice = toolChoice
        self.prefix = prefix
        self.messages = messages
    }
}

// MARK: - Encoding

/// One encoder for the whole package, with sorted keys.
///
/// Key order is the part of byte stability the client controls. `.sortedKeys`
/// makes the output a pure function of the values, so the same prefix
/// serialises to the same bytes across launches, Swift versions, and
/// dictionary seeds — which is what the cache's prefix match requires (R8).
enum DeterministicJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// A system block.
///
/// No `cache_control`: DeepSeek caches automatically and ignores the marker
/// (`docs/DEEPSEEK.md`). Sending it would be an inert key that still has to be
/// byte-identical across requests — cost with no benefit.
private struct SystemBlock: Encodable {
    let text: String

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
    }
}

extension MessagesRequest: Encodable {
    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case stream
        case thinking
        case outputConfig = "output_config"
        case toolChoice = "tool_choice"
        case system
        case tools
        case messages
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encode(systemBlocks(), forKey: .system)
        try container.encode(prefix.tools.tools, forKey: .tools)
        try container.encode(messages, forKey: .messages)
    }

    private func systemBlocks() -> [SystemBlock] {
        [
            SystemBlock(text: prefix.instructions.text),
            // The card is last because it is the only part that changes, and
            // only after a nightly digest.
            SystemBlock(text: prefix.profileCard.markdown),
        ]
    }

    public func encoded() throws -> Data {
        try DeterministicJSON.encoder.encode(self)
    }

    /// The prefix bytes alone — `tools` plus `system`, without the messages.
    ///
    /// Exposed so a test can assert that two requests differing only in their
    /// user turn produce an identical prefix. That is the client-side mirror
    /// of the proxy's byte-stability test, and together they cover both places
    /// a timestamp could leak into the cache key.
    public func encodedCacheablePrefix() throws -> Data {
        struct Prefix: Encodable {
            let tools: [ToolDefinition]
            let system: [SystemBlock]
        }
        return try DeterministicJSON.encoder.encode(
            Prefix(tools: prefix.tools.tools, system: systemBlocks())
        )
    }
}
