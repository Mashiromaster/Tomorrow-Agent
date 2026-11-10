import Foundation
import Testing

@testable import PAgentCore

/// Builds an SSE frame the way the API does.
private func frame(_ type: String, _ json: String) -> String {
    "event: \(type)\ndata: \(json)\n\n"
}

private let messageStart = frame(
    "message_start",
    """
    {"type":"message_start","message":{"id":"msg_1","usage":\
    {"input_tokens":3142,"cache_creation_input_tokens":0,\
    "cache_read_input_tokens":12288,"output_tokens":1}}}
    """
)

private let messageStop = frame("message_stop", #"{"type":"message_stop"}"#)

private func messageDelta(stopReason: String, outputTokens: Int = 2048) -> String {
    frame(
        "message_delta",
        """
        {"type":"message_delta","delta":{"stop_reason":"\(stopReason)"},\
        "usage":{"output_tokens":\(outputTokens)}}
        """
    )
}

/// Feeds a stream through the parser in fixed-size byte chunks.
private func parse(_ stream: String, chunkSize: Int? = nil) throws -> [StreamEvent] {
    var parser = SSEParser()
    var events: [StreamEvent] = []

    let bytes = Data(stream.utf8)
    let size = chunkSize ?? bytes.count
    var offset = bytes.startIndex
    while offset < bytes.endIndex {
        let end = min(bytes.index(offset, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex, bytes.endIndex)
        events.append(contentsOf: try parser.consume(bytes[offset..<end]))
        offset = end
    }
    events.append(contentsOf: try parser.finish())
    return events
}

@Suite("Usage")
struct UsageTests {
    @Test("cacheHit reflects the only observable cache signal")
    func cacheHitFlag() {
        // §10 Phase 1's acceptance bar is >80% hit rate, and
        // `cache_read_input_tokens` is the only way to see it (§7.3).
        #expect(Usage(cacheReadInputTokens: 12_288).cacheHit)
        #expect(Usage(cacheReadInputTokens: 0).cacheHit == false)
    }

    @Test("decodes with missing fields defaulted to zero")
    func tolerantDecoding() throws {
        let partial = Data(#"{"input_tokens":100}"#.utf8)
        let usage = try JSONDecoder().decode(Usage.self, from: partial)
        #expect(usage.inputTokens == 100)
        #expect(usage.cacheReadInputTokens == 0)
    }
}

@Suite("SSEParser")
struct SSEParserTests {
    @Test("reports usage from message_start, including the cache read")
    func readsStartUsage() throws {
        let events = try parse(messageStart + messageStop)

        guard case .started(let usage) = events.first else {
            Issue.record("expected a started event, got \(events)")
            return
        }
        #expect(usage.inputTokens == 3142)
        #expect(usage.cacheReadInputTokens == 12_288)
        #expect(usage.cacheHit)
    }

    @Test("streams text deltas in order")
    func streamsText() throws {
        let stream =
            messageStart
            + frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"周六"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"下午"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "end_turn")
            + messageStop

        let deltas = try parse(stream).compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        #expect(deltas == ["周六", "下午"])
    }

    @Test("accumulates a tool input across input_json_delta fragments")
    func accumulatesToolInput() throws {
        // The crux of §7.3's "工具输入一律 JSON 解析": the block arrives empty
        // and is filled by fragments that are only valid JSON once joined.
        // Parsing any single fragment would fail.
        let stream =
            messageStart
            + frame(
                "content_block_start",
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_places"}}"#
            )
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"独立书店\","}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"radius_meters\":2000}"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "tool_use")
            + messageStop

        let events = try parse(stream)
        guard case .toolUse(let id, let name, let input) = events.first(where: {
            if case .toolUse = $0 { return true }
            return false
        }) else {
            Issue.record("expected a toolUse event, got \(events)")
            return
        }

        #expect(id == "toolu_1")
        #expect(name == "search_places")
        #expect(input["query"]?.stringValue == "独立书店")
        #expect(input["radius_meters"]?.intValue == 2000)
    }

    @Test("handles a tool call with no arguments")
    func emptyToolInput() throws {
        // A no-argument tool streams no deltas at all, so the accumulated
        // JSON is the empty string rather than `{}`.
        let stream =
            messageStart
            + frame(
                "content_block_start",
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_routine"}}"#
            )
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "tool_use")
            + messageStop

        let events = try parse(stream)
        guard case .toolUse(_, _, let input) = events.first(where: {
            if case .toolUse = $0 { return true }
            return false
        }) else {
            Issue.record("expected a toolUse event")
            return
        }
        #expect(input == .object([:]))
    }

    @Test("accumulates two parallel tool calls independently")
    func parallelToolCalls() throws {
        // Interleaved by block index, which is how the API actually sends
        // them — one accumulator per index is the reason this works.
        let stream =
            messageStart
            + frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t0","name":"search_places"}}"#)
            + frame("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"get_travel_time"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"a\"}"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"mode\":\"transit\"}"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "tool_use")
            + messageStop

        let calls = try parse(stream).compactMap { event -> (String, JSONValue)? in
            if case .toolUse(_, let name, let input) = event { return (name, input) }
            return nil
        }

        #expect(calls.count == 2)
        // Stop order, not start order.
        #expect(calls[0].0 == "get_travel_time")
        #expect(calls[0].1["mode"]?.stringValue == "transit")
        #expect(calls[1].0 == "search_places")
        #expect(calls[1].1["query"]?.stringValue == "a")
    }

    @Test("throws rather than guessing when a tool input is malformed")
    func malformedToolInput() {
        let stream =
            messageStart
            + frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"search_places"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)

        #expect(throws: StreamParseError.self) {
            try parse(stream)
        }
    }

    @Test("collects a thinking block with its signature for verbatim replay")
    func collectsThinking() throws {
        let stream =
            messageStart
            + frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"考虑通勤"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"时间"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sigABC"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "end_turn")
            + messageStop

        let events = try parse(stream)

        // Deltas stream for the UI (§7.4 point 3)...
        let deltas = events.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }
        #expect(deltas == ["考虑通勤", "时间"])

        // ...and the assembled block is kept, because it must be replayed
        // unchanged on the next turn or the API rejects it.
        guard case .thinking(let text, let signature) = events.first(where: {
            if case .thinking = $0 { return true }
            return false
        }) else {
            Issue.record("expected an assembled thinking block")
            return
        }
        #expect(text == "考虑通勤时间")
        #expect(signature == "sigABC")
    }

    @Test("surfaces every stop reason §7.3 requires branching on")
    func reportsStopReasons() throws {
        for raw in ["end_turn", "max_tokens", "tool_use", "pause_turn", "refusal", "model_context_window_exceeded"] {
            let events = try parse(messageStart + messageDelta(stopReason: raw) + messageStop)
            guard case .finished(let stopReason, _) = events.last else {
                Issue.record("expected a finished event for \(raw)")
                return
            }
            #expect(stopReason == StopReason(rawValue: raw))
        }
    }

    @Test("a refusal is a normal stop reason, not a transport error")
    func refusalIsAStopReason() throws {
        // The API returns HTTP 200 with an empty `content` array. The parser
        // must report it cleanly so the caller can check before indexing.
        let events = try parse(messageStart + messageDelta(stopReason: "refusal", outputTokens: 0) + messageStop)
        guard case .finished(let stopReason, _) = events.last else {
            Issue.record("expected a finished event")
            return
        }
        #expect(stopReason == .refusal)
    }

    @Test("merges cumulative output tokens without losing the cache figures")
    func mergesUsage() throws {
        // `message_delta` carries cumulative output tokens and omits the
        // input/cache fields; a wholesale replace would zero the cache read
        // and make every turn look like a miss.
        let events = try parse(messageStart + messageDelta(stopReason: "end_turn") + messageStop)

        guard case .finished(_, let usage) = events.last else {
            Issue.record("expected a finished event")
            return
        }
        #expect(usage.outputTokens == 2048)
        #expect(usage.inputTokens == 3142)
        #expect(usage.cacheReadInputTokens == 12_288)
    }

    @Test("throws on an in-band error event")
    func inBandError() {
        let stream = messageStart + frame(
            "error",
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        )

        #expect(throws: StreamParseError.upstreamError(type: "overloaded_error", message: "Overloaded")) {
            try parse(stream)
        }
    }

    @Test("ignores pings and unknown event types")
    func ignoresNoise() throws {
        let stream =
            frame("ping", #"{"type":"ping"}"#)
            + messageStart
            + frame("something_new", #"{"type":"something_new","payload":1}"#)
            + messageDelta(stopReason: "end_turn")
            + messageStop

        // An unknown type must not fail the turn — the API may add events we
        // do not model yet.
        let events = try parse(stream)
        #expect(events.count == 2)
    }

    @Test("survives arbitrary chunk boundaries, including mid-UTF-8")
    func survivesChunking() throws {
        // `URLSession` delivers whatever arrived. A one-byte chunk size
        // splits every multi-byte Chinese character, which is the case a
        // naive `String(decoding:)` per chunk corrupts into U+FFFD.
        let stream =
            messageStart
            + frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#)
            + frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"周六下午去城西的独立书店"}}"#)
            + frame("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + messageDelta(stopReason: "end_turn")
            + messageStop

        for chunkSize in [1, 2, 3, 7, 13, 64, 512] {
            let text = try parse(stream, chunkSize: chunkSize)
                .compactMap { event -> String? in
                    if case .textDelta(let delta) = event { return delta }
                    return nil
                }
                .joined()

            #expect(text == "周六下午去城西的独立书店", "chunkSize=\(chunkSize)")
        }
    }

    @Test("tolerates CRLF line endings")
    func tolerantOfCRLF() throws {
        let events = try parse(
            (messageStart + messageDelta(stopReason: "end_turn") + messageStop)
                .replacingOccurrences(of: "\n", with: "\r\n")
        )
        guard case .started(let usage) = events.first else {
            Issue.record("expected a started event")
            return
        }
        #expect(usage.cacheReadInputTokens == 12_288)
    }

    @Test("ignores a malformed frame instead of failing the turn")
    func ignoresMalformedFrame() throws {
        let stream =
            messageStart
            + "data: {not valid json\n\n"
            + messageDelta(stopReason: "end_turn")
            + messageStop

        let events = try parse(stream)
        #expect(events.count == 2)
    }

    @Test("reports partial usage when the connection drops mid-stream")
    func partialStream() throws {
        // The input cost was already paid, so it still needs attributing.
        let events = try parse(messageStart)
        guard case .started(let usage) = events.first else {
            Issue.record("expected a started event")
            return
        }
        #expect(usage.inputTokens == 3142)
        // No `finished` event, because the turn never ended.
        #expect(events.count == 1)
    }

    @Test("does not accumulate unbounded state on a body that is not SSE")
    func boundedBuffer() throws {
        // An HTML error page from an intermediary has no newlines at all.
        var parser = SSEParser()
        let blob = Data(repeating: UInt8(ascii: "x"), count: 2 << 20)
        let events = try parser.consume(blob)
        #expect(events.isEmpty)
        // And the parser still works afterwards.
        #expect(try parser.consume(Data(messageStart.utf8)).count == 1)
    }
}
