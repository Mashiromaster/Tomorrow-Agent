import Foundation

import PAgentCore

/// Talks to the PAgent proxy, and hands the agent loop a stream of events.
///
/// ## What this type is responsible for
///
/// The proxy is deliberately narrow (§8), so the client carries the parts of
/// the conversation it cannot: attaching a device token, re-authenticating
/// when one is rejected, mapping status codes to something the UI can act on,
/// and turning SSE bytes into ``PAgentCore/StreamEvent`` values.
///
/// ## The byte-stability obligation (R8)
///
/// The request body is encoded **once**, with
/// ``PAgentCore/MessagesRequest/encoded()``, and the resulting `Data` is what
/// gets sent — including on the 401 retry. Re-encoding before the retry would
/// be the subtler half of the R8 trap: the retry would carry semantically
/// identical JSON whose bytes might differ, so the cache entry the first
/// attempt wrote would not be read by the second. Encoding is already
/// deterministic (`.sortedKeys`), but sending the same buffer makes the
/// property hold by construction rather than by assumption.
public struct ProxyTransport: MessagesTransport {
    public static let defaultAnthropicVersion = "2023-06-01"

    private let messagesURL: URL
    private let tokenProvider: any DeviceTokenProviding
    private let http: any HTTPByteStreaming
    private let anthropicVersion: String
    private let betaHeaders: [String]

    /// - Parameters:
    ///   - baseURL: The proxy's origin, e.g. `https://pagent-proxy.example.workers.dev`.
    ///   - betaHeaders: Relayed verbatim by the proxy, so the device controls
    ///     its own beta opt-ins without a proxy deploy. Empty by default:
    ///     adaptive thinking and `output_config.effort` are GA on the models
    ///     in §4.3 and need no beta flag.
    public init(
        baseURL: URL,
        tokenProvider: any DeviceTokenProviding,
        http: any HTTPByteStreaming = URLSessionByteStreaming(),
        anthropicVersion: String = ProxyTransport.defaultAnthropicVersion,
        betaHeaders: [String] = []
    ) {
        self.messagesURL = baseURL.appendingPathComponent("v1/messages")
        self.tokenProvider = tokenProvider
        self.http = http
        self.anthropicVersion = anthropicVersion
        self.betaHeaders = betaHeaders
    }

    // MARK: - MessagesTransport

    public func send(
        _ request: MessagesRequest
    ) async throws -> AsyncThrowingStream<StreamEvent, any Error> {
        let body: Data
        do {
            body = try request.encoded()
        } catch {
            // Encoding failing is a bug on this side, not a server problem.
            throw ProxyTransportError.invalidRequest(
                message: "could not encode the request: \(error)"
            )
        }

        let response = try await perform(body: body, streaming: request.stream)

        // §7.3 requires streaming for anything substantial, but the Haiku
        // batch-classification fallback (§6.1) is a short, non-streaming call.
        // Both have to arrive at the loop as the same event sequence.
        return request.stream ? Self.events(streaming: response) : Self.events(whole: response)
    }

    // MARK: - Request

    private func headers(token: DeviceToken, streaming: Bool) -> [String: String] {
        var headers = [
            "content-type": "application/json",
            "authorization": "Bearer \(token.value)",
            "anthropic-version": anthropicVersion,
        ]
        if streaming { headers["accept"] = "text/event-stream" }
        if !betaHeaders.isEmpty {
            headers["anthropic-beta"] = betaHeaders.joined(separator: ",")
        }
        return headers
    }

    /// Sends the body, retrying **once** after a 401 with a fresh token.
    ///
    /// Exactly one retry, and only for 401/403. A device token is short-lived
    /// (§2.3), so a request arriving just after expiry is the expected case
    /// and should recover without the user seeing anything. A second 401 means
    /// the device itself is no longer trusted — a revoked key, a rotated proxy
    /// signing secret — and retrying further would be a loop that never ends.
    ///
    /// Nothing else is retried automatically. A planning request costs real
    /// money (§4.3), so silently re-spending it on a 500 is worse than
    /// surfacing the failure and letting the user decide;
    /// ``ProxyTransportError/isTransient`` is what the UI uses to offer that.
    private func perform(body: Data, streaming: Bool) async throws -> StreamingResponse {
        var token = try await mintToken()
        var response = try await http.stream(
            url: messagesURL,
            method: "POST",
            headers: headers(token: token, streaming: streaming),
            body: body
        )

        if response.status == 401 || response.status == 403 {
            // Drain the rejected response before reusing the connection, and
            // so the error body is available if the retry also fails.
            _ = try? await response.collect()

            token = try await mintToken(refreshing: true)
            response = try await http.stream(
                url: messagesURL,
                method: "POST",
                headers: headers(token: token, streaming: streaming),
                body: body  // the same bytes — see the R8 note above
            )
        }

        guard response.isSuccess else {
            let errorBody = (try? await response.collect()) ?? Data()
            throw ProxyTransportError.from(
                status: response.status,
                body: errorBody,
                source: response.errorSource,
                retryAfter: response.retryAfter
            )
        }

        return response
    }

    private func mintToken(refreshing: Bool = false) async throws -> DeviceToken {
        do {
            return refreshing
                ? try await tokenProvider.refreshedToken()
                : try await tokenProvider.token()
        } catch let error as ProxyTransportError {
            throw error
        } catch {
            // Attestation failed: no Secure Enclave key, App Attest
            // unavailable, or the proxy refused the assertion. All of them
            // mean "re-enroll", which is what `unauthenticated` tells the UI.
            throw ProxyTransportError.unauthenticated(
                message: "could not obtain a device token: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Response

    /// Parses an SSE body incrementally.
    private static func events(
        streaming response: StreamingResponse
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Created inside the task: `SSEParser` is noncopyable, and it
                // is driven serially from here only.
                var parser = SSEParser()
                do {
                    for try await chunk in response.body {
                        for event in try parser.consume(chunk) {
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch let error as ProxyTransportError {
                    continuation.finish(throwing: error)
                } catch let error as StreamParseError {
                    continuation.finish(throwing: error)
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
    }

    /// Replays a non-streaming response as the same event sequence.
    ///
    /// The loop should not need to know which transport mode produced a turn,
    /// so a whole-body response is decomposed into the events a stream would
    /// have emitted: `started`, then one event per content block, then
    /// `finished`.
    private static func events(
        whole response: StreamingResponse
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let message = try JSONDecoder().decode(
                        WholeMessage.self,
                        from: try await response.collect()
                    )
                    let usage = message.usage ?? Usage()
                    continuation.yield(.started(usage))

                    // A refusal has an empty `content` array (§7.3), so this
                    // simply yields nothing and the loop sees the stop reason.
                    for block in message.content {
                        switch block {
                        case .text(let text):
                            continuation.yield(.textDelta(text))
                        case .toolUse(let id, let name, let input):
                            continuation.yield(.toolUse(id: id, name: name, input: input))
                        case .thinking(let text, let signature):
                            continuation.yield(.thinking(text: text, signature: signature))
                        case .toolResult:
                            // Only ever sent by us, never returned.
                            continue
                        }
                    }

                    continuation.yield(
                        .finished(
                            stopReason: message.stopReason.flatMap(StopReason.init(rawValue:)),
                            usage: usage
                        )
                    )
                    continuation.finish()
                } catch let error as ProxyTransportError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: ProxyTransportError.malformedResponse(
                            message: "could not decode the response body: \(error)"
                        )
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A non-streaming Messages response.
private struct WholeMessage: Decodable {
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }
}
