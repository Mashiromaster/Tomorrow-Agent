import Foundation

/// The card's sections, in the order they are always rendered.
///
/// The order is fixed by `allCases` rather than by caller input because the
/// card sits inside the cached prefix (R8): a section reordering between two
/// days would read identically to a human and invalidate the cache for every
/// request until the next digest.
public enum ProfileCardSection: String, Sendable, Codable, CaseIterable, Hashable {
    case taste
    case activity
    case routine
    case geography
    case avoid

    public var heading: String {
        switch self {
        case .taste: "口味"
        case .activity: "活动"
        case .routine: "节奏"
        case .geography: "地理"
        case .avoid: "规避"
        }
    }

    var displayOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// One line of the card.
public struct ProfileCardEntry: Sendable, Hashable {
    public let section: ProfileCardSection
    public let text: String

    /// The tag this line came from, if any. `nil` marks a line that is not
    /// trimmable — the rhythm and geography lines are what make a plan
    /// *schedulable*, so they are kept even when tags have to go.
    public let slug: String?

    /// Drives trim order: the lowest-scoring line goes first.
    public let score: Double

    public init(section: ProfileCardSection, text: String, slug: String?, score: Double) {
        self.section = section
        self.text = text
        self.slug = slug
        self.score = score
    }

    var isTrimmable: Bool { slug != nil }
}

/// The ≤500-token card described in §6.3.
///
/// This is the **only** personal data that leaves the device by default, and
/// it is deliberately plain Markdown so the settings screen can show the user
/// the exact text that was sent (§9.3, clause 5.1.2).
public struct ProfileCard: Sendable, Hashable {
    public let markdown: String
    public let tokenCount: Int

    /// Slugs that made it into the card.
    public let includedSlugs: [String]

    /// Slugs dropped to fit the budget.
    ///
    /// Surfaced rather than discarded: a card that silently shed half the
    /// user's interests would look complete while quietly degrading every
    /// plan built from it.
    public let omittedSlugs: [String]

    public init(markdown: String, tokenCount: Int, includedSlugs: [String], omittedSlugs: [String]) {
        self.markdown = markdown
        self.tokenCount = tokenCount
        self.includedSlugs = includedSlugs
        self.omittedSlugs = omittedSlugs
    }
}

public enum ProfileCardError: Error, Sendable, Equatable {
    /// Even with every trimmable line removed, the card is over budget.
    /// The caller should shorten the pinned rhythm/geography text.
    case cannotFitBudget(tokenCount: Int, limit: Int)
}

/// Renders, measures, and trims the profile card.
///
/// §6.3's generation loop is "summarise, then verify with `tokenCount(for:)`,
/// then cut low-scoring tags and retry". The measurement is not optional: a
/// card that overflows does not fail loudly, it just crowds out the task
/// context inside the 4096-token on-device window.
public struct ProfileCardBuilder: Sendable {
    public static let defaultTokenLimit = 500

    private let counter: any TokenCounting
    private let limit: Int

    public init(counter: any TokenCounting, limit: Int = ProfileCardBuilder.defaultTokenLimit) {
        precondition(limit > 0, "limit must be positive")
        self.counter = counter
        self.limit = limit
    }

    public func build(from entries: [ProfileCardEntry]) throws -> ProfileCard {
        var kept = entries
        var omitted: [String] = []

        while true {
            let markdown = Self.render(kept)
            let tokenCount = try counter.tokenCount(for: markdown)

            if tokenCount <= limit {
                return ProfileCard(
                    markdown: markdown,
                    tokenCount: tokenCount,
                    includedSlugs: kept.compactMap(\.slug),
                    omittedSlugs: omitted
                )
            }

            // Drop the weakest piece of evidence and measure again. Trimming
            // one line at a time costs a few extra counts and avoids throwing
            // away more of the card than the budget actually requires.
            guard let victim = Self.weakestTrimmable(in: kept) else {
                throw ProfileCardError.cannotFitBudget(tokenCount: tokenCount, limit: limit)
            }
            kept.removeAll { $0 == victim }
            if let slug = victim.slug { omitted.append(slug) }
        }
    }

    private static func weakestTrimmable(in entries: [ProfileCardEntry]) -> ProfileCardEntry? {
        entries
            .filter(\.isTrimmable)
            // Ties broken by slug, so trimming is deterministic and the card
            // does not oscillate between two equally-weak tags night to night.
            .min { $0.score == $1.score ? ($0.slug ?? "") > ($1.slug ?? "") : $0.score < $1.score }
    }

    /// Deterministic given the same entries: sections in `allCases` order,
    /// lines within a section by descending score then slug.
    static func render(_ entries: [ProfileCardEntry]) -> String {
        var lines = ["## 画像"]

        for section in ProfileCardSection.allCases {
            let inSection = entries
                .filter { $0.section == section }
                .sorted {
                    $0.score == $1.score
                        ? ($0.slug ?? $0.text) < ($1.slug ?? $1.text)
                        : $0.score > $1.score
                }
            guard !inSection.isEmpty else { continue }
            lines.append("\(section.heading)：\(inSection.map(\.text).joined(separator: "；"))。")
        }

        return lines.joined(separator: "\n")
    }
}
