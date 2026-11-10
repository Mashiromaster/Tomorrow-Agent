import Foundation
import Testing

@testable import PAgentCore

private func entry(
    _ section: ProfileCardSection,
    _ text: String,
    slug: String?,
    score: Double
) -> ProfileCardEntry {
    ProfileCardEntry(section: section, text: text, slug: slug, score: score)
}

/// A small, realistic card: a few tags plus the two pinned lines.
private let sampleEntries: [ProfileCardEntry] = [
    entry(.taste, "川菜/云南菜偏好强", slug: "cuisine.sichuan", score: 0.9),
    entry(.taste, "不吃生食", slug: "cuisine.no-raw", score: 0.7),
    entry(.activity, "徒步（月均 2 次）", slug: "activity.hiking", score: 0.8),
    entry(.activity, "独立书店", slug: "activity.bookstore", score: 0.5),
    entry(.activity, "小型 livehouse", slug: "activity.livehouse", score: 0.3),
    // `slug: nil` marks a line as non-trimmable: §6.3's rhythm and geography
    // lines are what make a plan *schedulable*, so they outrank any tag.
    entry(.routine, "工作日 7:10 起 / 23:30 睡", slug: nil, score: 1),
    entry(.geography, "常驻城西，可接受单程 ≤40 分钟", slug: nil, score: 1),
    entry(.avoid, "人多的商场", slug: "avoid.mall", score: 0.4),
]

@Suite("ProfileCard rendering")
struct ProfileCardRenderingTests {
    @Test("renders sections in a fixed order regardless of entry order")
    func fixedSectionOrder() {
        // The card sits inside the cached prefix (R8). A section reordering
        // between two days reads identically to a human and invalidates the
        // cache for every request until the next digest.
        let forward = ProfileCardBuilder.render(sampleEntries)
        let reversed = ProfileCardBuilder.render(sampleEntries.reversed())

        #expect(forward == reversed)

        let headings = ["口味", "活动", "节奏", "地理", "规避"]
        var searchStart = forward.startIndex
        for heading in headings {
            guard let found = forward.range(of: heading, range: searchStart..<forward.endIndex) else {
                Issue.record("missing or out-of-order heading: \(heading)")
                return
            }
            searchStart = found.upperBound
        }
    }

    @Test("orders lines within a section by descending score")
    func orderedWithinSection() {
        let markdown = ProfileCardBuilder.render(sampleEntries)
        guard let activity = markdown.split(separator: "\n").first(where: { $0.hasPrefix("活动") }) else {
            Issue.record("no activity line")
            return
        }

        let hiking = activity.range(of: "徒步")
        let bookstore = activity.range(of: "独立书店")
        let livehouse = activity.range(of: "livehouse")
        #expect(hiking != nil && bookstore != nil && livehouse != nil)
        #expect(hiking!.lowerBound < bookstore!.lowerBound)
        #expect(bookstore!.lowerBound < livehouse!.lowerBound)
    }

    @Test("ties are broken deterministically, so bytes do not drift")
    func deterministicTies() {
        let tied = [
            entry(.activity, "zeta activity", slug: "activity.zeta", score: 0.5),
            entry(.activity, "alpha activity", slug: "activity.alpha", score: 0.5),
        ]
        #expect(ProfileCardBuilder.render(tied) == ProfileCardBuilder.render(tied.reversed()))
    }

    @Test("omits a section with no entries")
    func omitsEmptySections() {
        // A cold-start user (R7) has interests but no rhythm data yet.
        let sparse = [entry(.taste, "川菜", slug: "cuisine.sichuan", score: 0.9)]
        let markdown = ProfileCardBuilder.render(sparse)

        #expect(markdown.contains("口味"))
        #expect(markdown.contains("节奏") == false)
        #expect(markdown.contains("地理") == false)
    }

    @Test("renders human-readable markdown the settings screen can show verbatim")
    func readableOutput() {
        // §9.3 clause 5.1.2: the user must be able to see exactly what was
        // sent. Plain markdown is what makes that page trivial to build.
        let markdown = ProfileCardBuilder.render(sampleEntries)

        #expect(markdown.hasPrefix("## 画像"))
        #expect(markdown.contains("口味：川菜/云南菜偏好强；不吃生食。"))
        #expect(markdown.contains("节奏：工作日 7:10 起 / 23:30 睡。"))
    }

    @Test("an empty card is still well-formed")
    func emptyCard() {
        #expect(ProfileCardBuilder.render([]) == "## 画像")
    }
}

@Suite("ProfileCardBuilder budget")
struct ProfileCardBudgetTests {
    private let counter = WordTokenCounter()

    @Test("returns the card and its measured cost when it fits")
    func fitsWithinBudget() throws {
        let builder = ProfileCardBuilder(counter: counter, limit: 500)
        let card = try builder.build(from: sampleEntries)

        #expect(card.tokenCount <= 500)
        #expect(card.omittedSlugs.isEmpty)
        #expect(card.includedSlugs.count == 6)
        #expect(card.markdown.contains("川菜"))
    }

    @Test("measures rather than assuming, per §6.3")
    func measuresTheCard() throws {
        // A card that overflows does not error — it just crowds out the task
        // context inside the 4096-token on-device window.
        let builder = ProfileCardBuilder(counter: counter)
        let card = try builder.build(from: sampleEntries)
        #expect(card.tokenCount == counter.tokenCount(for: card.markdown))
    }

    @Test("trims the lowest-scoring tag first")
    func trimsWeakestFirst() throws {
        // `sampleEntries` costs 77 tokens whole and 31 with every tag cut, so
        // a limit of 60 forces a partial trim — which is the only setting
        // where \"weakest first\" is observable. Below the 31-token floor the
        // builder has no choice left to get wrong.
        let builder = ProfileCardBuilder(counter: counter, limit: 60)
        let card = try builder.build(from: sampleEntries)

        #expect(card.tokenCount <= 60)
        #expect(card.omittedSlugs.isEmpty == false)
        // livehouse (0.3) goes before hiking (0.8).
        #expect(card.omittedSlugs.contains("activity.livehouse"))
        #expect(card.includedSlugs.contains("activity.hiking"))
    }

    @Test("reports what it dropped instead of shedding tags silently")
    func reportsOmissions() throws {
        // A card that quietly lost half the user's interests would look
        // complete while degrading every plan built from it.
        let builder = ProfileCardBuilder(counter: counter, limit: 45)
        let card = try builder.build(from: sampleEntries)

        // Every slug is either in the card or named in `omittedSlugs` —
        // nothing vanishes without being reported.
        #expect(card.omittedSlugs.isEmpty == false)
        let accounted = Set(card.includedSlugs).union(card.omittedSlugs)
        let original = Set(sampleEntries.compactMap(\.slug))
        #expect(accounted == original)
    }

    @Test("keeps the rhythm and geography lines even when every tag is cut")
    func keepsPinnedLines() throws {
        // Without them a plan is unschedulable: the model has no idea when
        // the user is awake or how far they will travel.
        //
        // 31 is exactly what the two pinned lines cost, so this is the
        // tightest budget that is still satisfiable — every tag goes, and the
        // lines that make the card actionable stay.
        let builder = ProfileCardBuilder(counter: counter, limit: 31)
        let card = try builder.build(from: sampleEntries)

        #expect(card.markdown.contains("节奏"))
        #expect(card.markdown.contains("地理"))
        #expect(card.includedSlugs.isEmpty)
        #expect(card.omittedSlugs.count == 6)
    }

    @Test("throws when even the pinned lines exceed the budget")
    func throwsWhenPinnedLinesDoNotFit() {
        // Surfaced rather than returning an over-budget card: the caller has
        // to shorten the rhythm text, and a silent overflow would just eat
        // the task context.
        //
        // 30 is one token under the pinned lines' cost — the boundary that
        // the previous test sits on the satisfiable side of.
        let builder = ProfileCardBuilder(counter: counter, limit: 30)
        #expect(throws: ProfileCardError.cannotFitBudget(tokenCount: 31, limit: 30)) {
            try builder.build(from: sampleEntries)
        }
    }

    @Test("trimming is deterministic across repeated builds")
    func trimmingIsDeterministic() throws {
        // Two equally-weak tags must not oscillate night to night — each
        // swap is a cache miss for a full day.
        //
        // 60 leaves a partial trim (three tags kept, three cut), so the
        // choice of victim is actually exercised; a budget below the pinned
        // floor would cut everything and prove nothing.
        let builder = ProfileCardBuilder(counter: counter, limit: 60)
        let first = try builder.build(from: sampleEntries)
        #expect(first.omittedSlugs.isEmpty == false)
        #expect(first.includedSlugs.isEmpty == false)

        for _ in 0..<10 {
            let again = try builder.build(from: sampleEntries.shuffled())
            #expect(again.markdown == first.markdown)
            #expect(again.omittedSlugs.sorted() == first.omittedSlugs.sorted())
        }
    }

    @Test("defaults to the §6.3 limit of 500 tokens")
    func defaultLimit() {
        #expect(ProfileCardBuilder.defaultTokenLimit == 500)
    }

    @Test("builds an empty card without trimming anything")
    func emptyInput() throws {
        let builder = ProfileCardBuilder(counter: counter, limit: 500)
        let card = try builder.build(from: [])

        #expect(card.markdown == "## 画像")
        #expect(card.includedSlugs.isEmpty)
        #expect(card.omittedSlugs.isEmpty)
    }

    @Test("a cold-start card from hand-picked interests fits easily")
    func coldStartCard() throws {
        // R7's onboarding: three manually chosen interests, no history.
        let builder = ProfileCardBuilder(counter: counter, limit: 500)
        let card = try builder.build(from: [
            entry(.activity, "徒步", slug: "activity.hiking", score: 1),
            entry(.activity, "展览", slug: "activity.exhibition", score: 1),
            entry(.taste, "川菜", slug: "cuisine.sichuan", score: 1),
        ])

        #expect(card.omittedSlugs.isEmpty)
        #expect(card.includedSlugs.count == 3)
    }
}

@Suite("Interest graph to profile card")
struct InterestGraphToCardTests {
    private let counter = WordTokenCounter()

    @Test("a rejected tag cannot reach the card")
    func rejectedTagsNeverLeaveTheDevice() throws {
        // The end-to-end version of §5.2 + §6.3: the card is the only
        // personal data that leaves the device, so a tag the user vetoed must
        // be structurally unable to appear in it.
        let states = [
            InterestTagState(slug: "cuisine.sichuan", score: 0.9, lastReinforcedAt: .now),
            InterestTagState(
                slug: "activity.mall",
                score: 0.95,
                lastReinforcedAt: .now,
                verdict: .rejected
            ),
        ]

        let ranked = rankedForProfileCard(states)
        let entries = ranked.map {
            entry(.activity, $0.slug, slug: $0.slug, score: $0.score)
        }
        let card = try ProfileCardBuilder(counter: counter, limit: 500).build(from: entries)

        #expect(card.markdown.contains("activity.mall") == false)
        #expect(card.includedSlugs.contains("activity.mall") == false)
        // And it is not reported as merely "omitted for space" either —
        // it never entered the pipeline.
        #expect(card.omittedSlugs.contains("activity.mall") == false)
    }
}
