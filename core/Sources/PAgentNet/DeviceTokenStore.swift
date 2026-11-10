import Foundation

/// A short-lived device token from `POST /v1/token`.
public struct DeviceToken: Sendable, Hashable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// Whether the token should be replaced before the next request.
    ///
    /// The margin matters: a token that expires between the check and the
    /// server's validation produces a 401 that looks like a device problem.
    /// The proxy issues 15-minute tokens, so 60 seconds of slack costs
    /// almost nothing and removes the race.
    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt.addingTimeInterval(-margin) <= now
    }
}

/// Supplies device tokens, and mints fresh ones on demand.
///
/// The real implementation performs the §2.3 handshake: ask the proxy for a
/// challenge, sign it with the Secure Enclave key via `DCAppAttestService`,
/// exchange the assertion for a token, and cache it in the Keychain. All of
/// that needs App Attest and a real device, so it lives behind this protocol
/// — which is also what lets the retry logic below be tested.
public protocol DeviceTokenProviding: Sendable {
    /// A usable token, minting one if the cache is empty or stale.
    func token() async throws -> DeviceToken

    /// Discards the cached token and mints a new one.
    ///
    /// Called after a 401. Separate from ``token()`` so a server that rejects
    /// a token we still believe is valid — a rotated signing key, a revoked
    /// device — cannot get the same cached value handed back to it forever.
    func refreshedToken() async throws -> DeviceToken
}

/// An in-memory token cache around a mint operation.
///
/// Holds the §2.3 caching policy — reuse until near expiry, mint on demand,
/// never two mints at once — so the device-side App Attest code only has to
/// supply `mint`. That split keeps the policy testable: the cache and the
/// single-flight behaviour are exercised here, and the Secure Enclave call is
/// a closure the app provides.
public actor CachingDeviceTokenProvider: DeviceTokenProviding {
    public typealias Mint = @Sendable () async throws -> DeviceToken

    private let mint: Mint
    private let now: @Sendable () -> Date
    private var cached: DeviceToken?
    /// The in-flight mint, if any, and the generation it belongs to.
    private var minting: Task<DeviceToken, any Error>?
    /// Bumped by every refresh. A mint from an earlier generation may have
    /// produced the token the server just rejected, so its result is not
    /// allowed to become the cache.
    private var generation = 0

    public init(now: @escaping @Sendable () -> Date = { Date() }, mint: @escaping Mint) {
        self.mint = mint
        self.now = now
    }

    public func token() async throws -> DeviceToken {
        if let cached, !cached.isExpired(at: now()) { return cached }
        return try await mintOnce()
    }

    /// Discards the cached token and mints a genuinely new one.
    ///
    /// The generation bump is the point. Reusing an in-flight mint here would
    /// be wrong: that mint may have started before the rejection and could
    /// hand back the same token the server has already refused, turning a
    /// recoverable 401 into an unrecoverable one. Concurrent refreshes within
    /// one generation still coalesce, so N parallel 401s cause one re-mint,
    /// not N.
    public func refreshedToken() async throws -> DeviceToken {
        cached = nil
        if minting != nil {
            minting = nil
            generation += 1
        }
        return try await mintOnce()
    }

    /// Coalesces concurrent mints into one.
    ///
    /// Worth doing because an attestation is expensive on both sides — a
    /// Secure Enclave signature here, chain verification at the proxy — and
    /// because every assertion consumes a counter value. Several parallel
    /// requests hitting an expired token would otherwise fire several
    /// attestations, and the proxy's KV-backed counter has a known race (see
    /// `proxy/src/index.ts`) that could reject the later ones as replays.
    private func mintOnce() async throws -> DeviceToken {
        if let minting { return try await minting.value }

        let startedIn = generation
        let task = Task { try await mint() }
        minting = task

        do {
            let token = try await task.value
            // A refresh that arrived mid-mint has already moved on; publishing
            // this token would reinstate the one that was just rejected.
            if startedIn == generation {
                cached = token
                minting = nil
            }
            return token
        } catch {
            if startedIn == generation { minting = nil }
            throw error
        }
    }
}
