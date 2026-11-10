import Foundation

/// Why the model stopped.
///
/// §7.3 requires every one of these to be branched on. `refusal` especially:
/// the response is a *successful* HTTP 200 with an empty `content` array, so
/// code that reads `content[0]` without checking first crashes on exactly the
/// requests a user is most likely to report.
public enum StopReason: String, Sendable, Codable, Hashable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case toolUse = "tool_use"
    /// A server-side tool hit its iteration limit. Send the turn back
    /// unchanged and the server resumes — do **not** append a "continue"
    /// message.
    case pauseTurn = "pause_turn"
    case refusal
    /// The context window ran out, as distinct from `max_tokens`.
    case modelContextWindowExceeded = "model_context_window_exceeded"
}

/// Token accounting from a response.
public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }

    /// The R8 acceptance signal: Phase 1 wants cache hit rate >80%, and this
    /// is the only way to observe it (§10 Phase 1, §7.3).
    public var cacheHit: Bool { cacheReadInputTokens > 0 }
}

/// What the UI and the agent loop need out of a stream, as it arrives.
///
/// Deliberately coarser than the wire protocol: the loop cares about "a tool
/// was requested" and "the turn ended", not about `content_block_start`
/// bookkeeping.
public enum StreamEvent: Sendable, Hashable {
    /// Usage from `message_start`. Carries `cache_read_input_tokens`, so this
    /// is where cache-hit telemetry comes from.
    case started(Usage)
    /// Incremental summarised reasoning. Only arrives when the request set
    /// `display: "summarized"`; otherwise §7.3's "long blank pause".
    case thinkingDelta(String)
    /// Incremental assistant text.
    case textDelta(String)
    /// A complete `tool_use` block, with `input` already parsed as JSON.
    case toolUse(id: String, name: String, input: JSONValue)
    /// A complete thinking block, to be replayed verbatim next turn.
    case thinking(text: String, signature: String?)
    /// The turn ended. `usage` is cumulative.
    case finished(stopReason: StopReason?, usage: Usage)
}

public enum StreamParseError: Error, Sendable, Equatable {
    /// The stream carried an `error` event — the API's in-band failure channel.
    case upstreamError(type: String, message: String)
    /// A `tool_use` block's accumulated `input_json_delta` was not valid JSON.
    case malformedToolInput(name: String, json: String)
}

/// Incremental SSE parser for the Messages API.
///
/// Hand-written because there is no official Anthropic Swift SDK and the
/// client only ever talks to our own proxy (§4.1). Two things make it more
/// than a `JSONDecoder` call:
///
/// 1. **Chunk boundaries are arbitrary.** `URLSession` hands over whatever
///    arrived; a `data:` line can be split mid-JSON and mid-UTF-8. Bytes are
///    therefore buffered until a line terminator, never parsed per-chunk.
/// 2. **`tool_use.input` streams as text fragments.** The block arrives empty
///    and is filled by `input_json_delta` pieces that are only valid JSON once
///    concatenated. The parser accumulates them per block index and parses at
///    `content_block_stop` — §7.3's "工具输入一律 JSON 解析".
///
/// Not an actor: it is driven serially from one task per request, and making
/// it one would add a hop per delta on the latency path §7.4 is trying to keep
/// short.
public struct SSEParser: ~Copyable, Sendable {
    /// Guards against a non-SSE body (an HTML error page from an intermediary)
    /// growing the buffer without bound.
    static let maxPendingBytes = 1 << 20

    private var pending = Data()
    private var decoder = IncrementalUTF8Decoder()

    /// Per-block-index accumulation state.
    private enum PartialBlock {
        case text
        case thinking(text: String, signature: String?)
        case toolUse(id: String, name: String, json: String)
    }

    private var partials: [Int: PartialBlock] = [:]
    private var usage = Usage()
    private var stopReason: StopReason?

    public init() {}

    /// Feeds bytes in, gets whatever events completed out.
    public mutating func consume(_ bytes: Data) throws -> [StreamEvent] {
        pending.append(bytes)

        var events: [StreamEvent] = []
        while let terminator = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = pending[pending.startIndex..<terminator]
            pending.removeSubrange(pending.startIndex...terminator)
            if let event = try handle(line: decoder.decode(lineBytes)) {
                events.append(contentsOf: event)
            }
        }

        // A body with no newlines is not SSE. Drop it rather than accumulate.
        if pending.count > Self.maxPendingBytes {
            pending.removeAll(keepingCapacity: false)
        }

        return events
    }

    /// Call when the body ends, to flush a final unterminated line.
    public mutating func finish() throws -> [StreamEvent] {
        guard !pending.isEmpty else { return [] }
        let line = decoder.decode(pending[...])
        pending.removeAll(keepingCapacity: false)
        return try handle(line: line) ?? []
    }

    private mutating func handle(line rawLine: String) throws -> [StreamEvent]? {
        // `event:` lines are redundant — every payload carries its own `type`.
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return nil }

        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }

        let frame: WireFrame
        do {
            frame = try JSONDecoder().decode(WireFrame.self, from: data)
        } catch {
            // An unreadable frame is not worth failing the whole turn over;
            // the API may add event types we do not model yet.
            return nil
        }
        return try apply(frame)
    }

    private mutating func apply(_ frame: WireFrame) throws -> [StreamEvent]? {
        switch frame.type {
        case "message_start":
            if let incoming = frame.message?.usage { usage = incoming }
            return [.started(usage)]

        case "content_block_start":
            guard let index = frame.index, let block = frame.contentBlock else { return nil }
            switch block.type {
            case "text":
                partials[index] = .text
            case "thinking":
                partials[index] = .thinking(text: block.thinking ?? "", signature: block.signature)
            case "tool_use":
                guard let id = block.id, let name = block.name else { return nil }
                partials[index] = .toolUse(id: id, name: name, json: "")
            default:
                return nil
            }
            return nil

        case "content_block_delta":
            guard let index = frame.index, let delta = frame.delta else { return nil }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text else { return nil }
                return [.textDelta(text)]
            case "thinking_delta":
                guard let text = delta.thinking else { return nil }
                if case .thinking(let existing, let signature) = partials[index] {
                    partials[index] = .thinking(text: existing + text, signature: signature)
                }
                return [.thinkingDelta(text)]
            case "signature_delta":
                guard let signature = delta.signature,
                    case .thinking(let text, let existing) = partials[index]
                else { return nil }
                partials[index] = .thinking(text: text, signature: (existing ?? "") + signature)
                return nil
            case "input_json_delta":
                guard let fragment = delta.partialJSON,
                    case .toolUse(let id, let name, let json) = partials[index]
                else { return nil }
                partials[index] = .toolUse(id: id, name: name, json: json + fragment)
                return nil
            default:
                return nil
            }

        case "content_block_stop":
            guard let index = frame.index, let partial = partials.removeValue(forKey: index) else {
                return nil
            }
            switch partial {
            case .text:
                return nil
            case .thinking(let text, let signature):
                return [.thinking(text: text, signature: signature)]
            case .toolUse(let id, let name, let json):
                // A tool call with no arguments streams no deltas at all.
                let source = json.isEmpty ? "{}" : json
                guard let data = source.data(using: .utf8),
                    let input = try? JSONDecoder().decode(JSONValue.self, from: data)
                else {
                    throw StreamParseError.malformedToolInput(name: name, json: source)
                }
                return [.toolUse(id: id, name: name, input: input)]
            }

        case "message_delta":
            if let incoming = frame.usage {
                // `message_delta` carries cumulative output tokens and omits
                // the input/cache figures, so merging field-by-field keeps
                // what `message_start` established.
                usage.outputTokens = incoming.outputTokens
                if incoming.inputTokens > 0 { usage.inputTokens = incoming.inputTokens }
            }
            if let reason = frame.delta?.stopReason {
                stopReason = StopReason(rawValue: reason)
            }
            return nil

        case "message_stop":
            return [.finished(stopReason: stopReason, usage: usage)]

        case "error":
            throw StreamParseError.upstreamError(
                type: frame.error?.type ?? "api_error",
                message: frame.error?.message ?? "the API reported an error"
            )

        case "ping":
            return nil

        default:
            return nil
        }
    }
}

/// Decodes UTF-8 across chunk boundaries.
///
/// `String(decoding:as:)` on a chunk that ends mid-codepoint yields a
/// replacement character, which would corrupt any non-ASCII text — and this
/// app's content is largely Chinese. Lines are assembled from bytes before
/// decoding, and this type holds the few trailing bytes of a split sequence.
private struct IncrementalUTF8Decoder {
    private var carry: [UInt8] = []

    mutating func decode(_ bytes: Data.SubSequence) -> String {
        var buffer = carry
        buffer.append(contentsOf: bytes)
        carry.removeAll(keepingCapacity: true)

        var decoder = UTF8()
        var iterator = buffer.makeIterator()
        var result = ""
        var consumed = 0
        var scalarStart = 0

        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                result.unicodeScalars.append(scalar)
                consumed += UTF8.width(scalar)
                scalarStart = consumed
            case .emptyInput:
                break loop
            case .error:
                // Either genuinely invalid bytes or a sequence cut short at the
                // end of this line. Keep the tail for the next feed and emit
                // what decoded cleanly.
                carry = Array(buffer[scalarStart...])
                return result
            }
        }

        return result
    }
}

// MARK: - Wire shapes

/// Lenient view of an SSE frame: every field optional, since one struct spans
/// all event types and unknown types must not fail decoding.
private struct WireFrame: Decodable {
    struct Message: Decodable {
        let usage: Usage?
    }

    struct Block: Decodable {
        let type: String
        let id: String?
        let name: String?
        let thinking: String?
        let signature: String?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let signature: String?
        let partialJSON: String?
        let stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case thinking
            case signature
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }

    let type: String
    let index: Int?
    let message: Message?
    let contentBlock: Block?
    let delta: Delta?
    let usage: Usage?
    let error: APIError?

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case message
        case contentBlock = "content_block"
        case delta
        case usage
        case error
    }
}
