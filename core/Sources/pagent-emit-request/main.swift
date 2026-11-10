import Foundation

import PAgentCore

// Emits the exact bytes `MessagesRequest` would send.
//
//     swift run pagent-emit-request deepseek-v4-pro > body.json
//
// ## Why this exists rather than a JSON fixture
//
// `proxy/scripts/verify-cache.mjs` checks a *live* cache hit, which is the one
// half of R8 no offline test can reach. For that check to mean anything it has
// to send the bytes the app actually sends — a hand-written fixture would keep
// passing while the real request path broke the cache, which is precisely the
// silent failure R8 is about.
//
// The emitted body carries the current time in the **user turn**, which keeps
// it out of the stable `tools → system` region. Two invocations therefore
// differ in the tail and are byte-identical in the prefix — exactly the
// scenario the live check needs: a real cache hit despite a changed request.

let arguments = Array(CommandLine.arguments.dropFirst())

guard let modelName = arguments.first,
    let model = DeepSeekModel(rawValue: modelName)
else {
    FileHandle.standardError.write(
        Data(
            """
            usage: pagent-emit-request <model> [prompt]

            models: \(DeepSeekModel.allCases.map(\.rawValue).joined(separator: ", "))

            """.utf8
        )
    )
    exit(2)
}

let userPrompt = arguments.dropFirst().first ?? "用三句话介绍你能帮我做什么。"

/// The §6.3 example card, verbatim from the design document.
///
/// A realistic card rather than the Phase 0 placeholder: the question this
/// answers is about steady-state cost and cache behaviour, not first launch.
let cardMarkdown = """
    ## 画像
    口味：川菜/云南菜偏好强；不吃生食。
    活动：徒步（月均 2 次）、独立书店、小型 livehouse。
    节奏：工作日 7:10 起 / 23:30 睡；周六上午通常空闲。
    地理：常驻城西，可接受单程 ≤40 分钟。
    规避：人多的商场；连续两天高强度行程。
    """

/// Rough shape only. DeepSeek's docs give ~0.6 token per Chinese character and
/// ~0.3 per English character, and ship an offline tokenizer — use that before
/// trusting any estimate for billing.
///
/// Used for the stderr diagnostic and for `ProfileCard.tokenCount`, neither of
/// which affects the emitted bytes. The authoritative figure comes back from
/// the API as `input_tokens + cache_read_input_tokens`.
func estimateTokens(_ text: String) -> Int {
    let cjk = text.unicodeScalars.count { $0.value >= 0x2E80 }
    let ascii = text.unicodeScalars.count { $0.value < 0x80 }
    return Int(Double(cjk) * 1.2 + Double(ascii) * 0.25)
}

let card = ProfileCard(
    markdown: cardMarkdown,
    tokenCount: estimateTokens(cardMarkdown),
    includedSlugs: ["cuisine.sichuan", "activity.hiking", "activity.bookstore"],
    omittedSlugs: []
)

do {
    let request = try MessagesRequest(
        model: model,
        maxTokens: 8_000,
        stream: true,
        thinking: .enabled(display: .summarized),
        outputConfig: OutputConfig(effort: .low),
        prefix: PAgentPrompt.prefix(card: card),
        messages: [
            .user([
                currentTimeBlock(at: .now, timeZone: .current),
                .text(userPrompt),
            ])
        ]
    )

    // Diagnostics to stderr so stdout stays a clean request body.
    //
    // No "clears minimum" verdict any more: DeepSeek caches automatically and
    // publishes no minimum cacheable prefix length (`docs/DEEPSEEK.md`). The
    // size is still worth printing — it feeds the cost model — but it is no
    // longer a pass/fail gate the way Opus's 4,096-token floor was.
    let prefixBytes = try request.encodedCacheablePrefix()
    let prefixText = String(decoding: prefixBytes, as: UTF8.self)
    FileHandle.standardError.write(
        Data(
            """
            model:             \(model.rawValue)
            prefix bytes:      \(prefixBytes.count)
            prefix est tokens: ~\(estimateTokens(prefixText))
            caching:           automatic, no marker — hit requires a full
                               byte match against a persisted prefix unit

            """.utf8
        )
    )

    FileHandle.standardOutput.write(try request.encoded())
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
