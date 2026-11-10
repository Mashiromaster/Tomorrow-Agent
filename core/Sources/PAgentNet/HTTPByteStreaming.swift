import Foundation

/// One HTTP response, with its body still arriving.
public struct StreamingResponse: Sendable {
    public let status: Int
    /// Lowercased header names, so lookups do not depend on what the server
    /// chose to capitalise.
    public let headers: [String: String]
    /// Body chunks, in order. Chunk boundaries are arbitrary — see
    /// ``PAgentCore/SSEParser``, which is built for exactly that.
    public let body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Where the failure came from, per the proxy's own header.
    public var errorSource: ErrorSource {
        guard let raw = header("x-pagent-error-source") else { return .unknown }
        return ErrorSource(rawValue: raw) ?? .unknown
    }

    /// `retry-after`, in seconds.
    ///
    /// Only the delta-seconds form is read. The HTTP-date form is legal but
    /// neither the proxy nor the Claude API sends it, and guessing at a date
    /// parse would risk a wildly wrong backoff.
    public var retryAfter: TimeInterval? {
        guard let raw = header("retry-after"), let seconds = Double(raw) else { return nil }
        return max(0, seconds)
    }

    /// Reads the whole body. For error responses, which are small.
    public func collect() async throws -> Data {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return data
    }
}

/// Performs an HTTP request and streams the response back.
///
/// Abstracted so ``ProxyTransport``'s logic — token refresh, retry-once,
/// status mapping, incremental parsing — is testable without a server. Those
/// are the paths that only run when something is already wrong, which is
/// precisely when they are hardest to exercise by hand.
public protocol HTTPByteStreaming: Sendable {
    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data
    ) async throws -> StreamingResponse
}

// MARK: - URLSession adapter

/// `URLSession`-backed implementation.
///
/// Deliberately thin: everything it does is translate between Foundation's
/// types and the protocol above. Nothing that could be wrong in an
/// interesting way lives here, because nothing here is covered by the test
/// suite — it needs a real socket.
public struct URLSessionByteStreaming: HTTPByteStreaming {
    private let session: URLSession

    /// A session configured for streaming.
    ///
    /// `timeoutIntervalForRequest` bounds the wait for *the next byte*, not
    /// the whole response — which is the behaviour a streaming request needs.
    /// A multi-day plan at `effort: high` can legitimately run for minutes
    /// (§7.3 requires streaming for exactly this reason), so a wall-clock cap
    /// would kill healthy requests; a stalled connection still trips the
    /// per-byte timeout.
    public static func makeSession(
        requestTimeout: TimeInterval = 90,
        resourceTimeout: TimeInterval = 15 * 60
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // Nothing here is cacheable, and a cached SSE response would be a
        // correctness problem rather than a speed-up.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // `httpShouldUsePipelining` is deliberately not set: deprecated as of
        // iOS 18.4, and it only ever applied to the classic loader that
        // HTTP/2 and HTTP/3 replaced.
        return URLSession(configuration: configuration)
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data
    ) async throws -> StreamingResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // One call. Destructuring two separate `bytes(for:)` calls would send
        // the request twice — and bill twice.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ProxyTransportError.transport(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProxyTransportError.malformedResponse(message: "response was not HTTP")
        }

        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String {
                result[name] = value
            }
        }

        return StreamingResponse(
            status: http.statusCode,
            headers: headerFields,
            body: AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // Batched, but flushed on every newline.
                        //
                        // Yielding per byte would spend a continuation resume
                        // on each one. Buffering to a fixed size instead would
                        // *delay* text the user is waiting to read, which
                        // defeats the point of streaming (§7.4 point 3) — an
                        // SSE frame is only actionable once its line is
                        // complete. Flushing at `\n` gives both: one resume
                        // per line, and no artificial latency.
                        let newline = UInt8(ascii: "\n")
                        var buffer = Data()
                        buffer.reserveCapacity(4096)
                        for try await byte in bytes {
                            buffer.append(byte)
                            if byte == newline || buffer.count >= 16_384 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                        continuation.finish()
                    } catch {
                        continuation.finish(
                            throwing: ProxyTransportError.transport(
                                message: error.localizedDescription
                            )
                        )
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        )
    }
}
