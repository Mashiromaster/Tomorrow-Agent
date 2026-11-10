import Foundation

import PAgentCore

@testable import PAgentNet

// MARK: - Async coordination

/// A one-shot gate, for ordering steps inside a single test.
///
/// Needed because the interesting transport behaviour is concurrent — a
/// refresh arriving while a mint is in flight, two requests racing one
/// expired token — and asserting on it requires knowing the first step has
/// actually begun rather than hoping a sleep was long enough.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumable = waiting
        waiting = []
        for continuation in resumable { continuation.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

// MARK: - HTTP stub

/// One scripted reply.
struct StubReply: Sendable {
    var status: Int
    var headers: [String: String]
    /// Body chunks, yielded in order. Several chunks exercise the incremental
    /// parser; one chunk is the simple case.
    var chunks: [Data]
    /// When set, the call throws instead of replying — offline, TLS, DNS.
    var failure: ProxyTransportError?

    static func ok(sse frames: [String]) -> StubReply {
        StubReply(
            status: 200,
            headers: ["content-type": "text/event-stream"],
            chunks: frames.map { Data($0.utf8) },
            failure: nil
        )
    }

    static func ok(json: String) -> StubReply {
        StubReply(
            status: 200,
            headers: ["content-type": "application/json"],
            chunks: [Data(json.utf8)],
            failure: nil
        )
    }

    static func error(
        _ status: Int,
        type: String = "api_error",
        message: String = "something went wrong",
        source: ErrorSource? = nil,
        retryAfter: String? = nil
    ) -> StubReply {
        var headers = ["content-type": "application/json"]
        if let source { headers["x-pagent-error-source"] = source.rawValue }
        if let retryAfter { headers["retry-after"] = retryAfter }

        let body = """
            {"type":"error","error":{"type":"\(type)","message":"\(message)"},"request_id":"req_1"}
            """
        return StubReply(status: status, headers: headers, chunks: [Data(body.utf8)], failure: nil)
    }

    /// A non-JSON error body, as a gateway or captive portal would return.
    static func html(_ status: Int) -> StubReply {
        StubReply(
            status: status,
            headers: ["content-type": "text/html"],
            chunks: [Data("<html><body>502 Bad Gateway</body></html>".utf8)],
            failure: nil
        )
    }

    static func transportFailure(_ message: String = "offline") -> StubReply {
        StubReply(
            status: 0, headers: [:], chunks: [],
            failure: .transport(message: message)
        )
    }
}

/// What the transport actually sent.
struct RecordedRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
}

/// Replays `replies` in order and records every request.
///
/// The last reply repeats once exhausted, so a test that only cares about the
/// first exchange does not have to pad the script.
final class StubHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [StubReply]
    private var recorded: [RecordedRequest] = []

    init(_ replies: [StubReply]) {
        precondition(!replies.isEmpty, "a stub needs at least one reply")
        self.replies = replies
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }
    var requestCount: Int { lock.withLock { recorded.count } }

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data
    ) async throws -> PAgentNet.StreamingResponse {
        let reply: StubReply = lock.withLock {
            recorded.append(
                RecordedRequest(url: url, method: method, headers: headers, body: body)
            )
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }

        if let failure = reply.failure { throw failure }

        return PAgentNet.StreamingResponse(
            status: reply.status,
            headers: reply.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in reply.chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }
}

// MARK: - Token stub

/// Hands out predictable tokens and counts how often it was asked.
final class StubTokenProvider: DeviceTokenProviding, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var issued = 0
    private(set) var refreshCount = 0
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var tokenCount: Int { lock.withLock { issued } }

    func token() async throws -> DeviceToken {
        if failing { throw Failure() }
        return lock.withLock {
            issued += 1
            return DeviceToken(value: "token-\(issued)", expiresAt: .distantFuture)
        }
    }

    func refreshedToken() async throws -> DeviceToken {
        lock.withLock { refreshCount += 1 }
        return try await token()
    }
}

// MARK: - Fixtures

/// A realistic cacheable prefix.
let testPrefix = CacheablePrefix(
    instructions: PAgentPrompt.v1,
    profileCard: ProfileCard(
        markdown: "## 画像\n口味：川菜偏好强。",
        tokenCount: 30,
        includedSlugs: ["cuisine.sichuan"],
        omittedSlugs: []
    ),
    tools: PAgentTools.standard
)

func testRequest(
    model: DeepSeekModel = .v4Pro,
    stream: Bool = true,
    maxTokens: Int = 64_000,
    thinking: Thinking? = .enabled(),
    outputConfig: OutputConfig? = OutputConfig(effort: .high),
    userText: String = "周六下午安排点事"
) throws -> MessagesRequest {
    try MessagesRequest(
        model: model,
        maxTokens: maxTokens,
        stream: stream,
        thinking: thinking,
        outputConfig: outputConfig,
        prefix: testPrefix,
        messages: [.user([.text(userText)])]
    )
}

func sseFrame(_ event: String, _ json: String) -> String {
    "event: \(event)\ndata: \(json)\n\n"
}

/// A complete, successful streamed turn.
let sseTurn: [String] = [
    sseFrame(
        "message_start",
        """
        {"type":"message_start","message":{"id":"msg_1","usage":\
        {"input_tokens":3142,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":12288,"output_tokens":1}}}
        """
    ),
    sseFrame(
        "content_block_start",
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#
    ),
    sseFrame(
        "content_block_delta",
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"周六下午"}}"#
    ),
    sseFrame("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
    sseFrame(
        "message_delta",
        """
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},\
        "usage":{"output_tokens":2048}}
        """
    ),
    sseFrame("message_stop", #"{"type":"message_stop"}"#),
]

extension ProxyTransport {
    /// A transport wired to stubs.
    static func stubbed(
        http: StubHTTP,
        tokens: any DeviceTokenProviding = StubTokenProvider(),
        betaHeaders: [String] = []
    ) -> ProxyTransport {
        ProxyTransport(
            baseURL: URL(string: "https://proxy.test")!,
            tokenProvider: tokens,
            http: http,
            betaHeaders: betaHeaders
        )
    }
}

/// Drains a transport stream into an array.
func collect(
    _ stream: AsyncThrowingStream<StreamEvent, any Error>
) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
