import Foundation
import Testing

@testable import PAgentCore

/// R8, client side.
///
/// The proxy's `cache-stability.test.ts` proves the *transport* does not
/// disturb the bytes. These tests prove the *construction* produces stable
/// bytes in the first place — the other place a timestamp can leak into the
/// cache key.
///
/// Both halves are needed: a perfectly byte-preserving proxy still gets a 0%
/// hit rate if the client interpolates `Date()` into the system prompt, and a
/// perfectly frozen system prompt does not help if the proxy re-serialises it.
@Suite("R8 cache stability")
struct CacheStabilityTests {
    private let counter = WordTokenCounter()

    private func card(_ markdown: String = "## 画像\n口味：川菜偏好强。") -> ProfileCard {
        ProfileCard(
            markdown: markdown,
            tokenCount: 42,
            includedSlugs: ["cuisine.sichuan"],
            omittedSlugs: []
        )
    }

    private func prefix(card profileCard: ProfileCard? = nil) -> CacheablePrefix {
        CacheablePrefix(
            instructions: AgentInstructions(
                "You are PAgent. Propose itineraries; never modify the calendar."
            ),
            profileCard: profileCard ?? card(),
            tools: PAgentTools.standard
        )
    }

    private func request(
        userText: String,
        prefix overridePrefix: CacheablePrefix? = nil
    ) throws -> MessagesRequest {
        try MessagesRequest(
            model: .v4Pro,
            maxTokens: 64_000,
            prefix: overridePrefix ?? prefix(),
            messages: [.user([.text(userText)])]
        )
    }

    // MARK: - The compile-time guard

    @Test("AgentInstructions cannot carry a clock, by construction")
    func instructionsAreFrozen() {
        // The initialiser takes a `StaticString`, and Swift does not allow
        // interpolation into one. So the following does not compile:
        //
        //     AgentInstructions("Current time: \(Date())")
        //     AgentInstructions("Session \(UUID())")
        //     let dynamic = "built at runtime"; AgentInstructions(dynamic)
        //
        // That is R8's "系统提示构造函数禁止传入时变参数（类型层面约束）" — enforced
        // by the compiler rather than by a reviewer noticing.
        let instructions = AgentInstructions("Frozen instructions.")
        #expect(instructions.text == "Frozen instructions.")
    }

    @Test("identical inputs produce identical instruction bytes across instances")
    func instructionsAreValueStable() {
        #expect(AgentInstructions("Same text.") == AgentInstructions("Same text."))
    }

    // MARK: - Prefix stability

    @Test("the cacheable prefix is byte-identical when only the user turn differs")
    func prefixIsStableAcrossUserTurns() throws {
        // The scenario R8 is actually about: the same user asks two questions
        // ten minutes apart. Everything up to the cache breakpoint must be
        // the same bytes, or the second request pays full input price.
        let morning = try request(userText: "当前时间：2026-11-10T09:00:00+08:00。周六下午安排点事")
        let evening = try request(userText: "当前时间：2026-11-10T17:45:12+08:00。晚上找个地方吃饭")

        #expect(try morning.encodedCacheablePrefix() == evening.encodedCacheablePrefix())
    }

    @Test("the current time reaches the model in the user turn, after the breakpoint")
    func timeLivesInUserTurn() throws {
        // The clock has to get through somehow — "周六下午" is meaningless
        // without it. §7.3 sanctions the user turn, which is after the
        // breakpoint and therefore costs nothing.
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let block = currentTimeBlock(at: Date(timeIntervalSince1970: 1_793_000_000), timeZone: timeZone)

        guard case .text(let text) = block else {
            Issue.record("expected a text block")
            return
        }
        #expect(text.contains("当前时间"))
        #expect(text.contains("Asia/Shanghai"))

        // And it is genuinely outside the prefix.
        let withTime = try MessagesRequest(
            model: .v4Pro,
            maxTokens: 64_000,
            prefix: prefix(),
            messages: [.user([block, .text("周六下午安排点事")])]
        )
        let withoutTime = try request(userText: "周六下午安排点事")
        #expect(try withTime.encodedCacheablePrefix() == withoutTime.encodedCacheablePrefix())
    }

    @Test("prefix bytes are reproducible across repeated encodes")
    func encodingIsDeterministic() throws {
        // Dictionary iteration order varies per process in Swift. Without
        // `.sortedKeys` the tool schemas would serialise differently between
        // launches and the cache would miss on every cold start.
        let built = try request(userText: "hello")
        let first = try built.encodedCacheablePrefix()
        for _ in 0..<20 {
            #expect(try built.encodedCacheablePrefix() == first)
        }
    }

    @Test("two independently built identical requests encode identically")
    func independentBuildsMatch() throws {
        #expect(
            try request(userText: "same").encoded() == request(userText: "same").encoded()
        )
    }

    @Test("the full request body has sorted keys")
    func bodyKeysAreSorted() throws {
        let json = String(decoding: try request(userText: "hi").encoded(), as: UTF8.self)

        // `max_tokens` sorts before `messages` before `model` before `system`.
        let maxTokens = json.range(of: "\"max_tokens\"")
        let messages = json.range(of: "\"messages\"")
        let model = json.range(of: "\"model\"")
        #expect(maxTokens != nil && messages != nil && model != nil)
        #expect(maxTokens!.lowerBound < messages!.lowerBound)
        #expect(messages!.lowerBound < model!.lowerBound)
    }

    // MARK: - What *should* invalidate

    @Test("a new profile card changes the prefix — the one legitimate daily change")
    func newCardChangesPrefix() throws {
        // §7.3: the card changes only after a nightly digest. One cache miss
        // per day is the designed cost; a miss per request is the bug.
        let today = try request(userText: "same question", prefix: prefix(card: card()))
        let tomorrow = try request(
            userText: "same question",
            prefix: prefix(card: card("## 画像\n口味：川菜偏好强；新增云南菜。"))
        )

        #expect(try today.encodedCacheablePrefix() != tomorrow.encodedCacheablePrefix())
    }

    @Test("a changed tool set changes the prefix")
    func toolChangeChangesPrefix() throws {
        let reduced = CacheablePrefix(
            instructions: AgentInstructions(
                "You are PAgent. Propose itineraries; never modify the calendar."
            ),
            profileCard: card(),
            tools: ToolSet([PAgentTools.searchCalendar])
        )
        let full = try request(userText: "q")
        let partial = try request(userText: "q", prefix: reduced)

        #expect(try full.encodedCacheablePrefix() != partial.encodedCacheablePrefix())
    }

    // MARK: - Tool ordering

    @Test("tool order is normalised, so an appended tool cannot break the cache")
    func toolOrderIsNormalised() {
        // Tools render first in the prefix (§7.3), so their order is part of
        // the cache key. "Remember to sort the tools" is the kind of rule
        // that survives review and then breaks when someone appends one — so
        // `ToolSet` sorts on construction and there is no unsorted form.
        let declared = ToolSet([
            PAgentTools.routine,
            PAgentTools.searchCalendar,
            PAgentTools.travelTime,
        ])
        let appendedDifferently = ToolSet([
            PAgentTools.travelTime,
            PAgentTools.routine,
            PAgentTools.searchCalendar,
        ])

        #expect(declared.names == appendedDifferently.names)
        #expect(declared.names == declared.names.sorted())
    }

    @Test("the standard tool set is sorted and complete")
    func standardToolSetIsSorted() {
        #expect(
            PAgentTools.standard.names == [
                "get_routine",
                "get_travel_time",
                "get_user_profile",
                "search_calendar",
                "search_places",
            ]
        )
    }

    // MARK: - Prefix composition

    @Test("the prefix is tools then instructions then card, with no markers")
    func prefixComposition() throws {
        // Order matters because DeepSeek matches a persisted prefix unit by a
        // full byte comparison: the card goes last precisely because it is the
        // only part that changes, and only after a nightly digest. Putting it
        // first would push a daily change in front of everything stable.
        //
        // No `cache_control` anywhere — DeepSeek ignores it, and an inert key
        // would still have to stay byte-identical to avoid breaking the match
        // it cannot help (`docs/DEEPSEEK.md`).
        struct DecodedPrefix: Decodable {
            struct Block: Decodable {
                struct CacheControl: Decodable { let type: String }
                let text: String
                let cacheControl: CacheControl?

                private enum CodingKeys: String, CodingKey {
                    case text
                    case cacheControl = "cache_control"
                }
            }
            let system: [Block]
            let tools: [ToolDefinition]
        }

        let decoded = try JSONDecoder().decode(
            DecodedPrefix.self,
            from: try request(userText: "hi").encodedCacheablePrefix()
        )

        #expect(decoded.system.allSatisfy { $0.cacheControl == nil })
        #expect(decoded.system.count == 2)
        #expect(decoded.system.first?.text.contains("PAgent") == true)
        #expect(decoded.system.last?.text.contains("画像") == true)
        // Tools are name-sorted, so an appended tool cannot reorder the prefix.
        #expect(decoded.tools.map(\.name) == decoded.tools.map(\.name).sorted())
    }
}
