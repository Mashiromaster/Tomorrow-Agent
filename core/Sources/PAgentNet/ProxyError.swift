import Foundation

/// Which side of the proxy a failure came from.
///
/// The proxy sets `x-pagent-error-source` precisely so the client can tell
/// these apart, and the distinction changes what the app should *do*: a proxy
/// 401 means re-attest the device, while an upstream 401 would mean the
/// proxy's own API key is broken and no amount of client retrying will help.
public enum ErrorSource: String, Sendable, Hashable {
    case proxy
    case upstream
    /// Neither header was present — an intermediary, or a response that never
    /// reached the proxy.
    case unknown
}

/// A failure talking to the proxy.
///
/// Both the proxy and the Claude API return the same envelope, so one type
/// covers both:
///
/// ```json
/// { "type": "error", "error": { "type": ..., "message": ... }, "request_id": ... }
/// ```
public enum ProxyTransportError: Error, Sendable, Hashable {
    /// The device is not enrolled, or its token is no longer accepted.
    ///
    /// `ProxyTransport` already retried once with a fresh token before
    /// surfacing this, so seeing it means re-attestation is needed — not that
    /// the token merely expired.
    case unauthenticated(message: String)

    /// Monthly quota exhausted (§4.2). `retryAfter` comes from the header.
    case quotaExhausted(message: String, retryAfter: TimeInterval?)

    /// Upstream rate limit or overload. Distinct from `quotaExhausted`:
    /// this one clears on its own, so it is worth retrying.
    case rateLimited(message: String, retryAfter: TimeInterval?)

    /// The request was rejected before reaching Claude — an unlisted model, a
    /// body over the size cap, a non-streaming request with too large a
    /// `max_tokens`. A bug on this side; retrying will not help.
    case invalidRequest(message: String)

    /// Anything else with a status code, carrying what the envelope said.
    case http(status: Int, type: String, message: String, source: ErrorSource)

    /// The transport itself failed — no response, or one that could not be
    /// read. Offline, DNS, TLS, a dropped connection mid-stream.
    case transport(message: String)

    /// The response arrived but was not something we can parse.
    case malformedResponse(message: String)

    /// Whether retrying the same request could plausibly succeed.
    ///
    /// Used to decide whether to offer the user a retry button; the transport
    /// does not retry these automatically, because a planning request can
    /// cost real money and silently re-spending it is worse than surfacing
    /// the failure.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .transport: true
        case .http(let status, _, _, _): status >= 500
        case .unauthenticated, .quotaExhausted, .invalidRequest, .malformedResponse: false
        }
    }

    /// Seconds the caller should wait, when the server said.
    public var retryAfter: TimeInterval? {
        switch self {
        case .quotaExhausted(_, let after), .rateLimited(_, let after): after
        default: nil
        }
    }
}

/// The error envelope, as both the proxy and the Claude API emit it.
struct ErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let type: String
        let message: String
    }

    let error: Payload
    let requestID: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case requestID = "request_id"
    }

    /// Reads an envelope, or synthesises one from the status code.
    ///
    /// A gateway or captive portal can return a non-2xx with HTML, so a
    /// failure to decode must not become a *different* error than the one the
    /// status code already told us about.
    static func parse(_ data: Data, status: Int) -> ErrorEnvelope {
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return decoded
        }
        return ErrorEnvelope(
            error: Payload(
                type: "api_error",
                message: "HTTP \(status) with an unreadable error body"
            ),
            requestID: nil
        )
    }
}

extension ProxyTransportError {
    /// Maps a non-2xx response to a typed error.
    ///
    /// The status code decides the case; the envelope supplies the message.
    /// `quotaExhausted` and `rateLimited` both arrive as 429, and the source
    /// header is what separates them — the proxy's own quota refuses locally
    /// (§4.2) and does not clear until the month rolls over, while an
    /// upstream 429 is temporary.
    static func from(
        status: Int,
        body: Data,
        source: ErrorSource,
        retryAfter: TimeInterval?
    ) -> ProxyTransportError {
        let envelope = ErrorEnvelope.parse(body, status: status)
        let message = envelope.error.message

        switch status {
        case 401, 403:
            return .unauthenticated(message: message)
        case 400, 413:
            return .invalidRequest(message: message)
        case 429:
            return source == .proxy
                ? .quotaExhausted(message: message, retryAfter: retryAfter)
                : .rateLimited(message: message, retryAfter: retryAfter)
        default:
            return .http(
                status: status,
                type: envelope.error.type,
                message: message,
                source: source
            )
        }
    }
}
