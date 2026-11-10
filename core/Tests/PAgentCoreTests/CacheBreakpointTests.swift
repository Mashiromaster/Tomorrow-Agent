import Foundation
import Testing

@testable import PAgentCore

/// What caching looks like once the markers are gone.
///
/// ## Why this suite was rewritten rather than deleted
///
/// Against Anthropic this file tested `cache_control` breakpoint placement: one
/// on the last system block (§7.3), and a second on the end of the conversation
/// that was added on 2026-11-10 because the ~2,140-token static prefix sat below
/// Opus's 4,096-token minimum.
///
/// DeepSeek **ignores `cache_control`** and caches on disk automatically, with
/// no published minimum (`docs/DEEPSEEK.md`). So the mechanism is gone and the
/// tests for it would be asserting nothing.
///
/// What remains is sharper, not weaker. DeepSeek matches a request against a
/// persisted *cache prefix unit* and requires a **full match** — so the cost of
/// one differing byte in the stable region is the same as it ever was, and
/// these tests now pin the two things that actually determine a hit:
///
///  1. No inert markers are emitted.
///  2. The stable region is byte-identical across requests that should share it.
@Suite("Cache behaviour without markers")
struct CacheBreakpointTests {
    private let card = ProfileCard(
        markdown: "## 画像\n口味：川菜。",
        tokenCount: 20,
        includedSlugs: ["cuisine.sichuan"],
        omittedSlugs: []
    )

    private func request(messages: [ClaudeMessage]) throws -> MessagesRequest {
        try MessagesRequest(
            model: .v4Pro,
            maxTokens: 64_000,
            prefix: PAgentPrompt.prefix(card: card),
            messages: messages
        )
    }

    @Test("emits no cache_control anywhere")
    func noCacheControlMarkers() throws {
        // Not cosmetic. An ignored key still has to be byte-identical across
        // requests to avoid breaking the very prefix match it cannot help —
        // cost with no benefit, and a thing to get wrong for nothing.
        let json = String(
            decoding: try request(messages: [
                .user([.text("周六几点有空")]),
                .assistant([.toolUse(id: "t1", name: "search_calendar", input: [:])]),
                .user([.toolResult(toolUseID: "t1", content: "free 14:00-18:00", isError: false)]),
            ]).encoded(),
            as: UTF8.self
        )

        #expect(json.contains("cache_control") == false)
        #expect(json.contains("ephemeral") == false)
    }

    @Test("system blocks carry only type and text")
    func systemBlockShape() throws {
        struct Decoded: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String
            }
            let system: [Block]
        }

        let decoded = try JSONDecoder().decode(
            Decoded.self,
            from: try request(messages: [.user([.text("q")])]).encoded()
        )

        #expect(decoded.system.count == 2)
        #expect(decoded.system[0].type == "text")
        // Instructions first, card last — the card is the only part that
        // changes, and only after a nightly digest.
        #expect(decoded.system[0].text.contains("PAgent"))
        #expect(decoded.system[1].text.contains("画像"))
    }

    @Test("the stable region survives a changing user turn")
    func stablePrefixAcrossTurns() throws {
        // The guarantee that still earns its keep. A hit needs a full byte
        // match against a persisted unit, so a timestamp leaking into
        // `tools → system` would cost every request its cache.
        let morning = try request(messages: [.user([.text("当前时间：09:00")])])
        let evening = try request(messages: [.user([.text("当前时间：17:45")])])

        #expect(try morning.encodedCacheablePrefix() == evening.encodedCacheablePrefix())
    }

    @Test("a growing conversation reuses the earlier turns byte-for-byte")
    func historyIsReusedVerbatim() throws {
        // DeepSeek persists a cache prefix unit at the end of each user input
        // and each model output, so round 2 hits on round 1's unit — but only
        // if round 1's bytes appear unchanged. This is the Example 1 shape
        // from `docs/DEEPSEEK.md`: A + B then A + B + C.
        let roundOne: [ClaudeMessage] = [.user([.text("周六几点有空")])]
        let roundTwo: [ClaudeMessage] =
            roundOne + [
                .assistant([.toolUse(id: "t1", name: "search_calendar", input: [:])]),
                .user([.toolResult(toolUseID: "t1", content: "free 14:00-18:00", isError: false)]),
            ]

        let first = String(decoding: try request(messages: roundOne).encoded(), as: UTF8.self)
        let second = String(decoding: try request(messages: roundTwo).encoded(), as: UTF8.self)

        // Round 1's serialised message object appears verbatim inside round 2.
        //
        // Sliced to the end of the first message rather than to the end of the
        // string: `.sortedKeys` places `model`, `output_config`, `stream`,
        // `system`, and `tools` *after* `messages`, so a slice to the end
        // would carry those along and never match.
        guard let start = first.range(of: #""messages":[{"#),
            let end = first.range(of: "}]", range: start.upperBound..<first.endIndex)
        else {
            Issue.record("could not locate round 1's message object")
            return
        }
        let roundOneMessage = String(first[start.upperBound..<end.lowerBound])
        #expect(roundOneMessage.contains("周六几点有空"))
        #expect(second.contains(roundOneMessage))

        // And the stable region is identical in both.
        #expect(
            try request(messages: roundOne).encodedCacheablePrefix()
                == request(messages: roundTwo).encodedCacheablePrefix()
        )
    }

    @Test("encoding is deterministic")
    func stillDeterministic() throws {
        let built = try request(messages: [
            .user([.text("q")]),
            .assistant([.toolUse(id: "t1", name: "search_places", input: ["query": "书店"])]),
            .user([.toolResult(toolUseID: "t1", content: "3 results", isError: false)]),
        ])

        let first = try built.encoded()
        for _ in 0..<20 {
            #expect(try built.encoded() == first)
        }
    }
}

/// Prefix size, for the cost model rather than for a caching verdict.
///
/// ## What changed about this measurement
///
/// This suite previously asserted the prefix was *below* Opus's minimum — it
/// documented a real limitation that justified adding a second breakpoint.
/// DeepSeek publishes no minimum, so there is no threshold to be under and the
/// assertion would be meaningless.
///
/// The number still matters, for a different reason: it is the input to the
/// §4.3 cost model. Keeping it measured means a later change to the prompt or
/// the tool set shows up here rather than in a bill.
@Suite("Prefix size")
struct PrefixLengthTests {
    /// Rough shape only.
    ///
    /// DeepSeek's own guidance is ~0.6 token per Chinese character and ~0.3 per
    /// English character, and they ship an offline tokenizer. This is
    /// deliberately cruder — enough to notice the prompt doubling, not enough
    /// to bill against.
    private struct ShapeCounter: TokenCounting {
        func tokenCount(for text: String) -> Int {
            let cjk = text.unicodeScalars.count { $0.value >= 0x2E80 }
            let ascii = text.unicodeScalars.count { $0.value < 0x80 }
            return Int(Double(cjk) * 0.6 + Double(ascii) * 0.3)
        }
    }

    @Test("the stable prefix stays in the expected size band")
    func prefixSizeIsBounded() throws {
        // A band, not a target. The point is to notice a change of *kind* — a
        // doubled prompt, a tool set that tripled — not to pin a number that
        // will drift with every wording tweak.
        let counter: any TokenCounting = ShapeCounter()
        let card = ProfileCard(
            // The §6.3 example card, which is realistic rather than minimal.
            markdown: """
                ## 画像
                口味：川菜/云南菜偏好强；不吃生食。
                活动：徒步（月均 2 次）、独立书店、小型 livehouse。
                节奏：工作日 7:10 起 / 23:30 睡；周六上午通常空闲。
                地理：常驻城西，可接受单程 ≤40 分钟。
                规避：人多的商场；连续两天高强度行程。
                """,
            tokenCount: 150,
            includedSlugs: [],
            omittedSlugs: []
        )

        let estimate = try PAgentPrompt.prefix(card: card).estimatedTokens(using: counter)

        #expect(estimate > 500, "prefix shrank unexpectedly — did the prompt get truncated?")
        #expect(estimate < 5_000, "prefix grew past the §4.3 cost assumption")
    }

    @Test("the tool schemas cost more than the prompt")
    func whereTheTokensAre() throws {
        // Measured, and the opposite of what the character counts suggest.
        // The prompt is ~1,219 chars of Chinese prose; the tool schemas are
        // ~2,961 chars of ASCII JSON. Under DeepSeek's ratios (~0.6 tok per
        // Chinese char, ~0.3 per ASCII char) that works out to roughly 670
        // tokens of prompt against 889 of tools.
        //
        // Recorded because it points at the cheaper lever: trimming tool
        // descriptions buys more than trimming the prompt, which is the
        // reverse of the Anthropic-era intuition.
        let counter: any TokenCounting = ShapeCounter()
        let promptTokens = try counter.tokenCount(for: PAgentPrompt.v1.text)
        let toolsJSON = try DeterministicJSON.encoder.encode(PAgentTools.standard.tools)
        let toolTokens = try counter.tokenCount(for: String(decoding: toolsJSON, as: UTF8.self))

        #expect(toolTokens > promptTokens)
        // Neither should dwarf the other; a 3× gap would mean something grew
        // without anyone noticing.
        #expect(Double(toolTokens) < Double(promptTokens) * 3)
    }
}
