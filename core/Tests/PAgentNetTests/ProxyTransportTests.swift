import Foundation
import Testing

import PAgentCore

@testable import PAgentNet

@Suite("Request construction")
struct RequestConstructionTests {
    @Test("posts to /v1/messages with the device token as a bearer")
    func basicRequest() async throws {
        let http = StubHTTP([.ok(sse: sseTurn)])
        let transport = ProxyTransport.stubbed(http: http)

        _ = try await collect(try await transport.send(try testRequest()))

        let sent = http.requests[0]
        #expect(sent.url.absoluteString == "https://proxy.test/v1/messages")
        #expect(sent.method == "POST")
        #expect(sent.headers["authorization"] == "Bearer token-1")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.headers["content-type"] == "application/json")
    }

    @Test("asks for an event stream only when streaming")
    func acceptHeader() async throws {
        let streaming = StubHTTP([.ok(sse: sseTurn)])
        _ = try await collect(
            try await ProxyTransport.stubbed(http: streaming).send(try testRequest(stream: true))
        )
        #expect(streaming.requests[0].headers["accept"] == "text/event-stream")

        let whole = StubHTTP([.ok(json: #"{"content":[],"stop_reason":"end_turn"}"#)])
        _ = try await collect(
            try await ProxyTransport.stubbed(http: whole).send(
                try testRequest(model: .flash, stream: false, maxTokens: 4_000,
                                thinking: nil, outputConfig: nil)
            )
        )
        #expect(whole.requests[0].headers["accept"] == nil)
    }

    @Test("relays beta headers so opt-ins need no proxy deploy")
    func betaHeaders() async throws {
        let http = StubHTTP([.ok(sse: sseTurn)])
        let transport = ProxyTransport.stubbed(
            http: http,
            betaHeaders: ["task-budgets-2026-03-13", "context-management-2025-06-27"]
        )

        _ = try await collect(try await transport.send(try testRequest()))

        #expect(
            http.requests[0].headers["anthropic-beta"]
                == "task-budgets-2026-03-13,context-management-2025-06-27"
        )
    }

    @Test("sends no beta header when there are no opt-ins")
    func noBetaHeaderByDefault() async throws {
        // Adaptive thinking and `output_config.effort` are GA on the §4.3
        // models; sending an empty beta header would be noise at best.
        let http = StubHTTP([.ok(sse: sseTurn)])
        _ = try await collect(try await ProxyTransport.stubbed(http: http).send(try testRequest()))
        #expect(http.requests[0].headers["anthropic-beta"] == nil)
    }

    @Test("sends exactly the bytes MessagesRequest encoded")
    func bodyIsTheEncodedRequest() async throws {
        // R8, transport edge. The proxy forwards bytes verbatim and the
        // encoder is deterministic; this checks the transport does not
        // interpose a re-encode of its own.
        let http = StubHTTP([.ok(sse: sseTurn)])
        let request = try testRequest()

        _ = try await collect(try await ProxyTransport.stubbed(http: http).send(request))

        #expect(http.requests[0].body == (try request.encoded()))
    }

    @Test("two identical requests produce identical bytes")
    func identicalRequestsAreByteIdentical() async throws {
        let http = StubHTTP([.ok(sse: sseTurn)])
        let transport = ProxyTransport.stubbed(http: http)

        _ = try await collect(try await transport.send(try testRequest()))
        _ = try await collect(try await transport.send(try testRequest()))

        #expect(http.requests[0].body == http.requests[1].body)
    }
}

@Suite("Authentication")
struct AuthenticationTests {
    @Test("refreshes the token once after a 401 and retries")
    func retriesOnceAfter401() async throws {
        // A 15-minute token (§2.3) expiring mid-session is the expected case,
        // not an error — the user should see nothing.
        let http = StubHTTP([.error(401, source: .proxy), .ok(sse: sseTurn)])
        let tokens = StubTokenProvider()
        let transport = ProxyTransport.stubbed(http: http, tokens: tokens)

        let events = try await collect(try await transport.send(try testRequest()))

        #expect(http.requestCount == 2)
        #expect(tokens.refreshCount == 1)
        // The retry carries the new token...
        #expect(http.requests[0].headers["authorization"] == "Bearer token-1")
        #expect(http.requests[1].headers["authorization"] == "Bearer token-2")
        // ...and the turn completes normally.
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }

    @Test("resends the same bytes on the retry")
    func retryIsByteIdentical() async throws {
        // The subtler half of R8: a re-encode before the retry could change
        // the bytes, so the cache entry the first attempt wrote would not be
        // read by the second — a silent full-price request.
        let http = StubHTTP([.error(401, source: .proxy), .ok(sse: sseTurn)])

        _ = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try testRequest())
        )

        #expect(http.requestCount == 2)
        #expect(http.requests[1].body == http.requests[0].body)
    }

    @Test("gives up after a second 401 instead of looping")
    func doesNotRetryTwice() async throws {
        // Two rejections mean the device is no longer trusted — a revoked
        // key, a rotated proxy secret. Retrying further never terminates.
        let http = StubHTTP([.error(401, message: "device is not enrolled", source: .proxy)])
        let transport = ProxyTransport.stubbed(http: http)

        await #expect(throws: ProxyTransportError.unauthenticated(message: "device is not enrolled")) {
            _ = try await collect(try await transport.send(try testRequest()))
        }
        #expect(http.requestCount == 2)
    }

    @Test("treats a 403 the same as a 401")
    func retriesOn403() async throws {
        let http = StubHTTP([.error(403, source: .proxy), .ok(sse: sseTurn)])
        let tokens = StubTokenProvider()

        _ = try await collect(
            try await ProxyTransport.stubbed(http: http, tokens: tokens).send(try testRequest())
        )

        #expect(tokens.refreshCount == 1)
        #expect(http.requestCount == 2)
    }

    @Test("reports a failed attestation as needing re-enrolment")
    func attestationFailure() async throws {
        // No Secure Enclave key, App Attest unavailable, or the proxy refused
        // the assertion. All of them mean the same thing to the UI.
        let http = StubHTTP([.ok(sse: sseTurn)])
        let transport = ProxyTransport.stubbed(http: http, tokens: StubTokenProvider(failing: true))

        do {
            _ = try await collect(try await transport.send(try testRequest()))
            Issue.record("expected the send to fail")
        } catch let error as ProxyTransportError {
            guard case .unauthenticated = error else {
                Issue.record("expected .unauthenticated, got \(error)")
                return
            }
        }
        // Nothing was sent, so no quota was spent.
        #expect(http.requestCount == 0)
    }
}

@Suite("Error mapping")
struct ErrorMappingTests {
    private func sendExpectingFailure(_ reply: StubReply) async -> ProxyTransportError? {
        let http = StubHTTP([reply])
        do {
            _ = try await collect(
                try await ProxyTransport.stubbed(http: http).send(try testRequest())
            )
            return nil
        } catch let error as ProxyTransportError {
            return error
        } catch {
            return nil
        }
    }

    @Test("a proxy 429 is an exhausted monthly quota")
    func proxyQuota() async throws {
        // §4.2's cap does not clear until the month rolls over, so this is
        // not worth retrying — and the UI has to say something different.
        let error = await sendExpectingFailure(
            .error(429, type: "rate_limit_error", message: "monthly request quota exhausted",
                   source: .proxy, retryAfter: "86400")
        )

        guard case .quotaExhausted(let message, let retryAfter) = error else {
            Issue.record("expected .quotaExhausted, got \(String(describing: error))")
            return
        }
        #expect(message.contains("quota exhausted"))
        #expect(retryAfter == 86_400)
        #expect(error?.isTransient == false)
    }

    @Test("an upstream 429 is a temporary rate limit")
    func upstreamRateLimit() async throws {
        // Same status code, opposite remedy. The proxy's own
        // `x-pagent-error-source` is what separates them.
        let error = await sendExpectingFailure(
            .error(429, type: "rate_limit_error", message: "Overloaded",
                   source: .upstream, retryAfter: "30")
        )

        guard case .rateLimited(_, let retryAfter) = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == 30)
        #expect(error?.isTransient == true)
    }

    @Test("a 400 is a bug on this side, not worth retrying")
    func badRequest() async throws {
        let error = await sendExpectingFailure(
            .error(400, type: "invalid_request_error",
                   message: "model `claude-fable-5` is not permitted by this proxy", source: .proxy)
        )

        guard case .invalidRequest(let message) = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(message.contains("not permitted"))
        #expect(error?.isTransient == false)
    }

    @Test("a 413 is also an invalid request")
    func tooLarge() async throws {
        let error = await sendExpectingFailure(.error(413, type: "request_too_large"))
        guard case .invalidRequest = error else {
            Issue.record("expected .invalidRequest, got \(String(describing: error))")
            return
        }
    }

    @Test("a 5xx keeps the status and reads as transient")
    func serverError() async throws {
        let error = await sendExpectingFailure(
            .error(529, type: "overloaded_error", message: "Overloaded", source: .upstream)
        )

        guard case .http(let status, let type, _, let source) = error else {
            Issue.record("expected .http, got \(String(describing: error))")
            return
        }
        #expect(status == 529)
        #expect(type == "overloaded_error")
        #expect(source == .upstream)
        #expect(error?.isTransient == true)
    }

    @Test("an unreadable error body still maps by status code")
    func htmlErrorBody() async throws {
        // A gateway or captive portal returns HTML. Failing to decode must
        // not turn a 502 into a *different* error than the status already
        // reported.
        let error = await sendExpectingFailure(.html(502))

        guard case .http(let status, _, let message, let source) = error else {
            Issue.record("expected .http, got \(String(describing: error))")
            return
        }
        #expect(status == 502)
        #expect(message.contains("502"))
        // No proxy header on a gateway response.
        #expect(source == .unknown)
    }

    @Test("a connection failure surfaces as a transport error")
    func transportFailure() async throws {
        let error = await sendExpectingFailure(.transportFailure("The Internet connection appears to be offline."))

        guard case .transport(let message) = error else {
            Issue.record("expected .transport, got \(String(describing: error))")
            return
        }
        #expect(message.contains("offline"))
        #expect(error?.isTransient == true)
    }

    @Test("retry-after is only read in the delta-seconds form")
    func retryAfterParsing() {
        // The HTTP-date form is legal but neither the proxy nor the Claude
        // API sends it, and a wrong date parse would mean a wildly wrong
        // backoff. Better to report nothing than a guess.
        let seconds = StreamingResponse(
            status: 429, headers: ["Retry-After": "120"],
            body: AsyncThrowingStream { $0.finish() }
        )
        #expect(seconds.retryAfter == 120)

        let httpDate = StreamingResponse(
            status: 429, headers: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"],
            body: AsyncThrowingStream { $0.finish() }
        )
        #expect(httpDate.retryAfter == nil)
    }

    @Test("header lookup ignores the server's capitalisation")
    func headersAreCaseInsensitive() {
        let response = StreamingResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream", "X-PAgent-Error-Source": "upstream"],
            body: AsyncThrowingStream { $0.finish() }
        )
        #expect(response.header("content-type") == "text/event-stream")
        #expect(response.errorSource == .upstream)
    }

    @Test("an unrecognised error source reads as unknown rather than guessing")
    func unknownErrorSource() {
        let response = StreamingResponse(
            status: 500, headers: ["x-pagent-error-source": "something-new"],
            body: AsyncThrowingStream { $0.finish() }
        )
        #expect(response.errorSource == .unknown)
    }
}

@Suite("Streaming responses")
struct StreamingResponseTests {
    @Test("parses a streamed turn into events")
    func parsesSSE() async throws {
        let http = StubHTTP([.ok(sse: sseTurn)])
        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try testRequest())
        )

        guard case .started(let usage) = events.first else {
            Issue.record("expected .started first, got \(events)")
            return
        }
        #expect(usage.cacheReadInputTokens == 12_288)
        #expect(usage.cacheHit)

        let text = events.compactMap { event -> String? in
            if case .textDelta(let delta) = event { return delta }
            return nil
        }.joined()
        #expect(text == "周六下午")

        guard case .finished(let stopReason, let final) = events.last else {
            Issue.record("expected .finished last, got \(events)")
            return
        }
        #expect(stopReason == .endTurn)
        #expect(final.outputTokens == 2048)
    }

    @Test("survives frames split across chunk boundaries")
    func survivesChunking() async throws {
        // The real transport hands over whatever arrived. A frame cut
        // mid-JSON, or mid-UTF-8 inside a Chinese character, has to produce
        // the same events.
        let whole = sseTurn.joined()
        for chunkSize in [1, 7, 64, 500] {
            var chunks: [Data] = []
            let bytes = Array(whole.utf8)
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                chunks.append(Data(bytes[index..<end]))
                index = end
            }

            let http = StubHTTP([
                StubReply(status: 200, headers: ["content-type": "text/event-stream"],
                          chunks: chunks, failure: nil)
            ])
            let events = try await collect(
                try await ProxyTransport.stubbed(http: http).send(try testRequest())
            )

            let text = events.compactMap { event -> String? in
                if case .textDelta(let delta) = event { return delta }
                return nil
            }.joined()
            #expect(text == "周六下午", "chunkSize=\(chunkSize)")
            #expect(events.count == 3, "chunkSize=\(chunkSize)")
        }
    }

    @Test("surfaces an in-band error event")
    func inBandError() async throws {
        // The API can report a failure inside a 200 stream. Silently ending
        // the turn would look like an empty answer.
        let http = StubHTTP([
            .ok(sse: [
                sseTurn[0],
                sseFrame(
                    "error",
                    #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
                ),
            ])
        ])

        await #expect(throws: StreamParseError.self) {
            _ = try await collect(
                try await ProxyTransport.stubbed(http: http).send(try testRequest())
            )
        }
    }

    @Test("reports a mid-stream disconnect as a transport failure")
    func midStreamDisconnect() async throws {
        // Partial usage has already been emitted, so cost is still
        // attributable — but the turn did not finish and must not look like
        // it did.
        let http = StubHTTP([
            StubReply(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [Data(sseTurn[0].utf8)],
                failure: nil
            )
        ])

        // A body that simply ends early yields no `finished` event.
        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try testRequest())
        )
        #expect(events.count == 1)
        #expect(events.contains { if case .finished = $0 { true } else { false } } == false)
    }

    @Test("accumulates a tool call streamed as JSON fragments")
    func toolUseAcrossFragments() async throws {
        let http = StubHTTP([
            .ok(sse: [
                sseTurn[0],
                sseFrame(
                    "content_block_start",
                    """
                    {"type":"content_block_start","index":0,"content_block":\
                    {"type":"tool_use","id":"toolu_1","name":"search_places"}}
                    """
                ),
                sseFrame(
                    "content_block_delta",
                    #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#
                ),
                sseFrame(
                    "content_block_delta",
                    #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"独立书店\"}"}}"#
                ),
                sseFrame("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
                sseFrame(
                    "message_delta",
                    """
                    {"type":"message_delta","delta":{"stop_reason":"tool_use"},\
                    "usage":{"output_tokens":120}}
                    """
                ),
                sseFrame("message_stop", #"{"type":"message_stop"}"#),
            ])
        ])

        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try testRequest())
        )

        guard
            case .toolUse(let id, let name, let input) = events.first(where: {
                if case .toolUse = $0 { return true }
                return false
            })
        else {
            Issue.record("expected a toolUse event, got \(events)")
            return
        }
        #expect(id == "toolu_1")
        #expect(name == "search_places")
        #expect(input["query"]?.stringValue == "独立书店")
    }
}

@Suite("Non-streaming responses")
struct NonStreamingResponseTests {
    private func haikuRequest() throws -> MessagesRequest {
        // §6.1's cloud fallback for batch classification: short, no thinking,
        // no effort, no need to stream.
        try testRequest(
            model: .flash, stream: false, maxTokens: 4_000,
            thinking: nil, outputConfig: nil
        )
    }

    @Test("replays a whole response as the same event sequence")
    func wholeResponseBecomesEvents() async throws {
        // The loop should not need to know which transport mode produced a
        // turn.
        let http = StubHTTP([
            .ok(
                json: """
                    {"id":"msg_1","type":"message","role":"assistant",
                     "content":[{"type":"text","text":"cuisine.sichuan"}],
                     "stop_reason":"end_turn",
                     "usage":{"input_tokens":500,"output_tokens":12,
                              "cache_read_input_tokens":4096}}
                    """
            )
        ])

        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try haikuRequest())
        )

        guard case .started(let usage) = events.first else {
            Issue.record("expected .started, got \(events)")
            return
        }
        #expect(usage.inputTokens == 500)
        #expect(usage.cacheReadInputTokens == 4096)

        guard case .textDelta(let text) = events[1] else {
            Issue.record("expected a text delta, got \(events)")
            return
        }
        #expect(text == "cuisine.sichuan")

        guard case .finished(let stopReason, _) = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        #expect(stopReason == .endTurn)
    }

    @Test("a refusal arrives as a stop reason, not a crash")
    func refusal() async throws {
        // §7.3: a refusal is a successful HTTP 200 with an *empty* content
        // array. Code that reads `content[0]` breaks here, which is why the
        // loop checks `stop_reason` first.
        let http = StubHTTP([
            .ok(json: #"{"id":"msg_1","content":[],"stop_reason":"refusal","usage":{"input_tokens":20,"output_tokens":0}}"#)
        ])

        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try haikuRequest())
        )

        // started, then finished — nothing in between.
        #expect(events.count == 2)
        guard case .finished(let stopReason, _) = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        #expect(stopReason == .refusal)
    }

    @Test("carries a tool call out of a whole response")
    func toolUseInWholeResponse() async throws {
        let http = StubHTTP([
            .ok(
                json: """
                    {"id":"msg_1",
                     "content":[{"type":"tool_use","id":"toolu_9","name":"get_routine",
                                 "input":{"day_of_week":6}}],
                     "stop_reason":"tool_use",
                     "usage":{"input_tokens":100,"output_tokens":30}}
                    """
            )
        ])

        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try haikuRequest())
        )

        guard case .toolUse(let id, let name, let input) = events[1] else {
            Issue.record("expected a toolUse event, got \(events)")
            return
        }
        #expect(id == "toolu_9")
        #expect(name == "get_routine")
        #expect(input["day_of_week"]?.intValue == 6)
    }

    @Test("an undecodable success body is reported, not silently empty")
    func malformedBody() async throws {
        let http = StubHTTP([.ok(json: #"{"unexpected":true}"#)])

        do {
            _ = try await collect(
                try await ProxyTransport.stubbed(http: http).send(try haikuRequest())
            )
            Issue.record("expected a failure")
        } catch let error as ProxyTransportError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
            #expect(error.isTransient == false)
        }
    }

    @Test("an unknown stop reason is reported as absent rather than invented")
    func unknownStopReason() async throws {
        let http = StubHTTP([
            .ok(json: #"{"content":[],"stop_reason":"something_new","usage":{"output_tokens":1}}"#)
        ])

        let events = try await collect(
            try await ProxyTransport.stubbed(http: http).send(try haikuRequest())
        )

        guard case .finished(let stopReason, _) = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        // The loop treats `nil` as a normal end of turn, which is the safe
        // reading of a reason we do not model yet.
        #expect(stopReason == nil)
    }
}

@Suite("End to end with the agent loop")
struct AgentLoopIntegrationTests {
    /// Executes tools without touching EventKit or MapKit.
    private struct Executor: ToolExecuting {
        func execute(name: String, input: JSONValue) async throws -> String {
            "result from \(name)"
        }
    }

    @Test("drives a two-round tool-using turn through the real transport")
    func multiRoundTurn() async throws {
        // The transport and the loop have only been tested apart; this is the
        // seam between them.
        let toolRound = [
            sseTurn[0],
            sseFrame(
                "content_block_start",
                """
                {"type":"content_block_start","index":0,"content_block":\
                {"type":"tool_use","id":"toolu_1","name":"search_calendar"}}
                """
            ),
            sseFrame(
                "content_block_delta",
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
            ),
            sseFrame("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            sseFrame(
                "message_delta",
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":50}}"#
            ),
            sseFrame("message_stop", #"{"type":"message_stop"}"#),
        ]

        let http = StubHTTP([.ok(sse: toolRound), .ok(sse: sseTurn)])
        let loop = AgentLoop(
            transport: ProxyTransport.stubbed(http: http),
            executor: Executor()
        )

        let turn = try await loop.run(try testRequest())

        #expect(turn.rounds == 2)
        #expect(turn.assistantText == "周六下午")
        // Usage accumulates across both rounds.
        #expect(turn.usage.outputTokens == 2098)
        #expect(turn.cacheHit)

        // And the second request carried the tool result back.
        #expect(http.requestCount == 2)
        let secondBody = String(decoding: http.requests[1].body, as: UTF8.self)
        #expect(secondBody.contains("tool_result"))
        #expect(secondBody.contains("result from search_calendar"))
    }

    @Test("the cacheable prefix is byte-identical across rounds")
    func prefixStableAcrossRounds() async throws {
        // Rounds 2..n should read the prefix from cache. If anything in the
        // transport or the loop rebuilt it per round, every round would pay
        // full input price (R8).
        let toolRound = [
            sseTurn[0],
            sseFrame(
                "content_block_start",
                """
                {"type":"content_block_start","index":0,"content_block":\
                {"type":"tool_use","id":"t1","name":"get_routine"}}
                """
            ),
            sseFrame("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            sseFrame(
                "message_delta",
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}"#
            ),
            sseFrame("message_stop", #"{"type":"message_stop"}"#),
        ]

        let http = StubHTTP([.ok(sse: toolRound), .ok(sse: sseTurn)])
        let loop = AgentLoop(
            transport: ProxyTransport.stubbed(http: http),
            executor: Executor()
        )
        _ = try await loop.run(try testRequest())

        #expect(http.requestCount == 2)

        // Compare the serialised prefix region of each body: everything up to
        // `"messages"`, which sorts last among the top-level keys that matter
        // here and is the only part that legitimately differs.
        func prefixRegion(_ body: Data) -> String {
            let text = String(decoding: body, as: UTF8.self)
            guard let range = text.range(of: #""messages""#) else { return text }
            return String(text[text.startIndex..<range.lowerBound])
        }
        #expect(prefixRegion(http.requests[1].body) == prefixRegion(http.requests[0].body))
    }

    @Test("a refusal mid-loop surfaces as AgentLoopError.refused")
    func refusalPropagates() async throws {
        let http = StubHTTP([
            .ok(sse: [
                sseTurn[0],
                sseFrame(
                    "message_delta",
                    #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#
                ),
                sseFrame("message_stop", #"{"type":"message_stop"}"#),
            ])
        ])
        let loop = AgentLoop(
            transport: ProxyTransport.stubbed(http: http),
            executor: Executor()
        )

        await #expect(throws: AgentLoopError.refused) {
            _ = try await loop.run(try testRequest())
        }
    }

    @Test("a quota failure propagates out of the loop untranslated")
    func quotaErrorPropagates() async throws {
        // The UI needs the typed error — \"you are out of requests this
        // month\" is a different message from \"something went wrong\".
        let http = StubHTTP([
            .error(429, type: "rate_limit_error", message: "monthly request quota exhausted",
                   source: .proxy, retryAfter: "3600")
        ])
        let loop = AgentLoop(
            transport: ProxyTransport.stubbed(http: http),
            executor: Executor()
        )

        do {
            _ = try await loop.run(try testRequest())
            Issue.record("expected a failure")
        } catch let error as ProxyTransportError {
            guard case .quotaExhausted(_, let retryAfter) = error else {
                Issue.record("expected .quotaExhausted, got \(error)")
                return
            }
            #expect(retryAfter == 3600)
        }
    }
}
