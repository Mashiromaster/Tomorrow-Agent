import Foundation
import Testing

import PAgentCore

@testable import PAgentNet

private let epoch = Date(timeIntervalSince1970: 1_793_000_000)

@Suite("DeviceToken")
struct DeviceTokenTests {
    @Test("treats a token as expired slightly before it actually is")
    func expiryMargin() {
        // A token that expires between our check and the server's validation
        // produces a 401 that looks like a device problem. The proxy issues
        // 15-minute tokens, so 60 seconds of slack removes the race at
        // negligible cost.
        let token = DeviceToken(value: "t", expiresAt: epoch.addingTimeInterval(300))

        #expect(token.isExpired(at: epoch) == false)
        #expect(token.isExpired(at: epoch.addingTimeInterval(239)) == false)
        #expect(token.isExpired(at: epoch.addingTimeInterval(241)))
        // Already past expiry.
        #expect(token.isExpired(at: epoch.addingTimeInterval(600)))
    }

    @Test("honours a caller-supplied margin")
    func customMargin() {
        let token = DeviceToken(value: "t", expiresAt: epoch.addingTimeInterval(300))
        #expect(token.isExpired(at: epoch, margin: 600))
        #expect(token.isExpired(at: epoch, margin: 0) == false)
    }
}

/// A scripted mint that can be made to block on its first call.
private final class MintScript: @unchecked Sendable {
    let firstStarted = Gate()
    let releaseFirst = Gate()

    private let lock = NSLock()
    private var count = 0
    private let blockFirst: Bool
    private let failUntil: Int

    init(blockFirst: Bool = false, failUntil: Int = 0) {
        self.blockFirst = blockFirst
        self.failUntil = failUntil
    }

    struct Failure: Error {}

    var mintCount: Int { lock.withLock { count } }

    func mint() async throws -> DeviceToken {
        let n: Int = lock.withLock {
            count += 1
            return count
        }

        if blockFirst && n == 1 {
            await firstStarted.open()
            await releaseFirst.wait()
        }
        if n <= failUntil { throw Failure() }

        return DeviceToken(value: "token-\(n)", expiresAt: epoch.addingTimeInterval(900))
    }
}

@Suite("CachingDeviceTokenProvider")
struct CachingDeviceTokenProviderTests {
    @Test("mints once and reuses the cached token")
    func cachesToken() async throws {
        let script = MintScript()
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        #expect(try await provider.token().value == "token-1")
        #expect(try await provider.token().value == "token-1")
        #expect(script.mintCount == 1)
    }

    @Test("mints again once the cached token is near expiry")
    func mintsAfterExpiry() async throws {
        // The mint produces a 15-minute token, matching the proxy's TTL.
        let script = MintScript()
        let clock = MutableClock(epoch)
        let provider = CachingDeviceTokenProvider(now: { clock.now }) { try await script.mint() }

        #expect(try await provider.token().value == "token-1")
        clock.advance(by: 14 * 60)  // inside the 60-second margin
        #expect(try await provider.token().value == "token-2")
        #expect(script.mintCount == 2)
    }

    @Test("coalesces concurrent mints into one attestation")
    func concurrentMintsCoalesce() async throws {
        // An attestation is expensive on both sides — a Secure Enclave
        // signature here, chain verification at the proxy — and each one
        // consumes a counter value. Several parallel requests hitting an
        // expired token must not fire several attestations, or the proxy's
        // KV-backed counter could reject the later ones as replays.
        let script = MintScript(blockFirst: true)
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        let first = Task { try await provider.token() }
        await script.firstStarted.wait()

        let others = (0..<4).map { _ in Task { try await provider.token() } }
        await script.releaseFirst.open()

        let values = try await [first.value] + others.asyncMap { try await $0.value }
        #expect(values.allSatisfy { $0.value == "token-1" })
        #expect(script.mintCount == 1)
    }

    @Test("a refresh always mints, even with a valid token cached")
    func refreshBypassesTheCache() async throws {
        // Called after a 401. The server has rejected a token we still
        // believe is valid — a revoked key, a rotated signing secret — so
        // handing the same value back would never recover.
        let script = MintScript()
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        #expect(try await provider.token().value == "token-1")
        #expect(try await provider.refreshedToken().value == "token-2")
        #expect(try await provider.token().value == "token-2")
        #expect(script.mintCount == 2)
    }

    @Test("a refresh does not adopt a mint that was already in flight")
    func refreshDoesNotReuseAnInFlightMint() async throws {
        // The failure this guards against: a mint that began *before* the
        // rejection could produce the very token the server just refused.
        // Joining it would turn a recoverable 401 into a permanent one.
        let script = MintScript(blockFirst: true)
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        let pending = Task { try await provider.token() }
        await script.firstStarted.wait()

        // Arrives while mint 1 is suspended, so it must start its own.
        let refreshed = try await provider.refreshedToken()
        #expect(refreshed.value == "token-2")

        await script.releaseFirst.open()
        // The stale mint still returns its value to its own caller...
        #expect(try await pending.value.value == "token-1")
        // ...but it must not become the cache.
        #expect(try await provider.token().value == "token-2")
        #expect(script.mintCount == 2)
    }

    @Test("a failed mint is not cached and can be retried")
    func failedMintIsNotCached() async throws {
        let script = MintScript(failUntil: 1)
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        await #expect(throws: MintScript.Failure.self) {
            _ = try await provider.token()
        }
        // A cached failure would strand the app until relaunch.
        #expect(try await provider.token().value == "token-2")
    }

    @Test("a failure propagates to every coalesced caller")
    func failurePropagatesToAllWaiters() async throws {
        let script = MintScript(blockFirst: true, failUntil: 1)
        let provider = CachingDeviceTokenProvider(now: { epoch }) { try await script.mint() }

        let first = Task { try await provider.token() }
        await script.firstStarted.wait()
        let second = Task { try await provider.token() }
        await script.releaseFirst.open()

        await #expect(throws: MintScript.Failure.self) { _ = try await first.value }
        await #expect(throws: MintScript.Failure.self) { _ = try await second.value }
        #expect(script.mintCount == 1)
    }
}

// MARK: - Helpers

/// A clock the test moves by hand, so expiry is exact rather than timed.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

extension Array {
    /// `map` over an async transform, preserving order.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
