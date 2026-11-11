import Foundation

import PAgentCore
import PAgentNet

// Drives a real agent turn from the command line, against a running proxy.
//
//     cd proxy && npx wrangler dev --local     # one terminal
//     cd core  && swift run pagent-chat        # another
//
// ## What this does and does not prove
//
// `AgentLoop` takes a `MessagesTransport` and a `ToolExecuting`, so the only
// iOS-specific pieces in a turn are *which* implementations get passed in.
// This tool passes the real `ProxyTransport` — the same type `PlannerView`
// constructs — so the streaming parse, the SSE event sequence, the tool-call
// round trip, and the live cache behaviour are all exercised for real.
//
// Two substitutions are unavoidable on macOS, and both are narrow:
//
//   App Attest   `DCAppAttestService` needs a provisioned device. The token
//                is signed here with the deployment's own `JWT_SIGNING_KEY`,
//                exactly as `proxy/scripts/verify-cache.mjs` does. This
//                exercises the proxy's *verification* path; it says nothing
//                about attestation, which only a real device can.
//
//   Tools        `PAgentTools.standard` is backed by EventKit and MapKit,
//                which have no data here. The executor below refuses every
//                call, which is the same thing `UnavailableToolExecutor` does
//                in the app today — the device-side integration is Phase 1.
//                So a turn that *needs* a tool reports the refusal rather
//                than inventing an answer, and that is itself worth seeing.
//
// Everything else is the shipping path.

// MARK: - Arguments

struct Options {
    var model: DeepSeekModel = .flash
    var baseURL = URL(string: "http://127.0.0.1:8787")!
    var prompt = "用三句话介绍你能帮我做什么。"
    var showPrefix = false
}

func parseArguments() -> Options {
    var options = Options()
    var rest: [String] = []
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--model":
            guard let raw = arguments.first, let model = DeepSeekModel(rawValue: raw) else {
                fail(
                    "--model needs one of: "
                        + DeepSeekModel.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            arguments.removeFirst()
            options.model = model
        case "--target":
            guard let raw = arguments.first, let url = URL(string: raw), url.scheme != nil else {
                fail("--target needs an absolute URL, e.g. http://127.0.0.1:8787")
            }
            arguments.removeFirst()
            options.baseURL = url
        case "--show-prefix":
            options.showPrefix = true
        case "--help", "-h":
            FileHandle.standardError.write(Data(usage.utf8))
            exit(0)
        default:
            rest.append(argument)
        }
    }

    if !rest.isEmpty { options.prompt = rest.joined(separator: " ") }
    return options
}

let usage = """
    usage: swift run pagent-chat [options] [prompt]

      --model <name>    \(DeepSeekModel.allCases.map(\.rawValue).joined(separator: " | ")) (default: deepseek-flash)
      --target <url>    proxy origin (default: http://127.0.0.1:8787)
      --show-prefix     print the cacheable prefix before sending

    Requires a running proxy and JWT_SIGNING_KEY — from the environment, or
    read out of proxy/.dev.vars.

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✘ \(message)\n".utf8))
    exit(1)
}

// MARK: - Device token

/// Signs a token with the deployment's own `JWT_SIGNING_KEY`.
///
/// Mirrors `verify-cache.mjs`, which mirrors `proxy/src/jwt.ts`:
/// `base64url(header).base64url(claims).base64url(hmac)`. Kept as a small
/// hand-rolled HMAC rather than a dependency so this tool adds nothing to the
/// package graph that ships.
struct LocalSigner {
    let secret: String

    func token(deviceID: String, lifetime: TimeInterval = 600) -> DeviceToken {
        let issuedAt = Date()
        let expiresAt = issuedAt.addingTimeInterval(lifetime)

        let header = ["alg": "HS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "sub": deviceID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "tier": "free",
        ]

        let signingInput = "\(base64url(json: header)).\(base64url(json: claims))"
        let signature = Base64URL.encode(HMACSHA256.mac(key: Data(secret.utf8), message: Data(signingInput.utf8)))
        return DeviceToken(value: "\(signingInput).\(signature)", expiresAt: expiresAt)
    }

    private func base64url(json: [String: Any]) -> String {
        // `.sortedKeys` only so a run is reproducible when read by eye; the
        // proxy does not care about key order in the token.
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return Base64URL.encode(data)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// HMAC-SHA256 over Foundation only.
///
/// CryptoKit would be one line, but it is unavailable on Linux and this
/// package builds there for CI's sake. SHA-256 is short enough to carry.
enum HMACSHA256 {
    static func mac(key: Data, message: Data) -> Data {
        let blockSize = 64
        var key = key
        if key.count > blockSize { key = SHA256.hash(key) }
        if key.count < blockSize { key += Data(repeating: 0, count: blockSize - key.count) }

        let outerPad = Data(key.map { $0 ^ 0x5c })
        let innerPad = Data(key.map { $0 ^ 0x36 })
        return SHA256.hash(outerPad + SHA256.hash(innerPad + message))
    }
}

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hash(_ message: Data) -> Data {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]

        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            let chunk = Array(padded[chunkStart..<chunkStart + 64])
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] =
                    UInt32(chunk[i * 4]) << 24 | UInt32(chunk[i * 4 + 1]) << 16
                    | UInt32(chunk[i * 4 + 2]) << 8 | UInt32(chunk[i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        var out = Data(capacity: 32)
        for value in h {
            out.append(UInt8(truncatingIfNeeded: value >> 24))
            out.append(UInt8(truncatingIfNeeded: value >> 16))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
            out.append(UInt8(truncatingIfNeeded: value))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// Reads `JWT_SIGNING_KEY` from the environment, falling back to
/// `proxy/.dev.vars` — the same order `verify-cache.mjs` uses, so the two
/// tools cannot disagree about which deployment they are talking to.
func signingKey() -> String {
    if let fromEnvironment = ProcessInfo.processInfo.environment["JWT_SIGNING_KEY"],
        !fromEnvironment.isEmpty
    {
        return fromEnvironment
    }

    let devVars = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .deletingLastPathComponent()
        .appendingPathComponent("proxy/.dev.vars")

    guard let contents = try? String(contentsOf: devVars, encoding: .utf8) else {
        fail(
            """
            JWT_SIGNING_KEY is not set and \(devVars.path) does not exist.
              cp proxy/.dev.vars.example proxy/.dev.vars   and fill it in.
            """
        )
    }

    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("JWT_SIGNING_KEY") , let equals = trimmed.firstIndex(of: "=") else {
            continue
        }
        let value = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !value.isEmpty { return value }
    }
    fail("proxy/.dev.vars has no JWT_SIGNING_KEY line.")
}

// MARK: - Tools

/// Refuses every call, and says why.
///
/// Identical in behaviour to the app's `UnavailableToolExecutor`: throwing
/// routes this through `AgentLoop`'s failed-tool path, which returns a
/// `tool_result` with `is_error: true`. Dropping the result instead would
/// leave a `tool_use` unanswered and the next request would be rejected
/// (§7.3) — so this also exercises that recovery path.
struct RefusingExecutor: ToolExecuting {
    struct Unavailable: LocalizedError {
        let tool: String
        var errorDescription: String? {
            "`\(tool)` needs EventKit/MapKit data, which this macOS harness "
                + "has none of. Answer without it, and say so."
        }
    }

    func execute(name: String, input: JSONValue) async throws -> String {
        FileHandle.standardError.write(Data("  ↯ refused \(name)\n".utf8))
        throw Unavailable(tool: name)
    }
}

// MARK: - Output state

/// Tracks which section headers have been printed.
///
/// `AgentLoop.run(_:onActivity:)` takes a `@Sendable` closure, so this cannot
/// be a captured `var`. The lock is not ceremony — deltas arrive from the
/// loop's task, not this one.
final class PrintedHeaders: @unchecked Sendable {
    enum Header { case thinking, answer }

    private let lock = NSLock()
    private var printed: Set<String> = []

    /// Returns `true` exactly once per header — the caller prints when it wins.
    func claim(_ header: Header) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return printed.insert("\(header)").inserted
    }
}

// MARK: - Run

let options = parseArguments()
let signer = LocalSigner(secret: signingKey())

// A stable device id, so a second run reuses the first run's quota row and
// the cache sees the same prefix. A random one per run would quietly test a
// cold cache every time.
let deviceID = "macos-harness"

let transport = ProxyTransport(
    baseURL: options.baseURL,
    tokenProvider: CachingDeviceTokenProvider { signer.token(deviceID: deviceID) }
)

/// The §6.3 example card, verbatim — same one `pagent-emit-request` uses, so
/// the prefix bytes match and a run here can hit the cache a run there wrote.
let card = ProfileCard(
    markdown: """
        ## 画像
        口味：川菜/云南菜偏好强；不吃生食。
        活动：徒步（月均 2 次）、独立书店、小型 livehouse。
        节奏：工作日 7:10 起 / 23:30 睡；周六上午通常空闲。
        地理：常驻城西，可接受单程 ≤40 分钟。
        规避：人多的商场；连续两天高强度行程。
        """,
    tokenCount: 180,
    includedSlugs: ["cuisine.sichuan", "activity.hiking", "activity.bookstore"],
    omittedSlugs: []
)

do {
    let request = try MessagesRequest(
        model: options.model,
        maxTokens: 8_000,
        stream: true,
        thinking: .enabled(display: .summarized),
        outputConfig: OutputConfig(effort: .low),
        prefix: PAgentPrompt.prefix(card: card),
        messages: [
            .user([
                currentTimeBlock(at: .now, timeZone: .current),
                .text(options.prompt),
            ])
        ]
    )

    if options.showPrefix {
        let bytes = try request.encodedCacheablePrefix()
        FileHandle.standardError.write(bytes)
        FileHandle.standardError.write(Data("\n\n".utf8))
    }

    FileHandle.standardError.write(
        Data(
            """
            target:  \(options.baseURL.absoluteString)
            model:   \(options.model.rawValue)
            tools:   \(PAgentTools.standard.names.joined(separator: ", "))
            prompt:  \(options.prompt)

            """.utf8
        )
    )

    // Streamed to stderr as it arrives — the point is to watch §7.4's
    // perceived latency, which a buffered print would hide.
    //
    // `onActivity` is `@Sendable`, so the "have I printed this header yet"
    // flags cannot be plain captured vars. A lock-guarded box is the honest
    // spelling: the loop really can call back from a different task.
    let headers = PrintedHeaders()

    let turn = try await AgentLoop(transport: transport, executor: RefusingExecutor())
        .run(request) { activity in
            switch activity {
            case .thinking(let delta):
                if headers.claim(.thinking) {
                    FileHandle.standardError.write(Data("\n── 思考 ──\n".utf8))
                }
                FileHandle.standardError.write(Data(delta.utf8))
            case .text(let delta):
                if headers.claim(.answer) {
                    FileHandle.standardError.write(Data("\n\n── 回答 ──\n".utf8))
                }
                FileHandle.standardOutput.write(Data(delta.utf8))
            case .callingTool(let name):
                FileHandle.standardError.write(Data("\n  → \(name)\n".utf8))
            case .toolFinished(let name, let failed):
                FileHandle.standardError.write(
                    Data("  \(failed ? "✘" : "✔") \(name)\n".utf8))
            case .roundCompleted(let index, let usage):
                // Per-round, because `AgentTurn.usage` is a sum: a turn can
                // hit cache on round one and miss later as the message array
                // grows past the prefix. The total alone would hide that.
                FileHandle.standardError.write(
                    Data(
                        ("\n  · round \(index): in=\(usage.inputTokens) "
                            + "out=\(usage.outputTokens) "
                            + "cache_read=\(usage.cacheReadInputTokens)\n").utf8
                    ))
            }
        }

    let usage = turn.usage
    FileHandle.standardError.write(
        Data(
            """


            ── 用量 ──
            rounds:        \(turn.rounds)
            input:         \(usage.inputTokens)
            output:        \(usage.outputTokens)
            cache write:   \(usage.cacheCreationInputTokens)
            cache read:    \(usage.cacheReadInputTokens)
            cache hit:     \(turn.cacheHit ? "✔ yes" : "— no (expected on a cold prefix; run again)")

            """.utf8
        )
    )
} catch {
    FileHandle.standardError.write(Data("\n✘ \(error)\n".utf8))
    exit(1)
}
