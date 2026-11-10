import Foundation
import SwiftData

import PAgentCore

/// A derived interest tag (IMPLEMENTATION.md §5.2).
///
/// Derived, not raw: every tag here can be rebuilt by replaying the
/// ``SignalEvent`` log. That is why losing this table is recoverable and
/// losing the signal log is not.
@Model
public final class InterestTag {
    /// Dot-separated, e.g. `cuisine.sichuan`, `activity.hiking`.
    ///
    /// Unique because the digest merges by slug: two rows for the same tag
    /// would split its score and each half would decay independently.
    @Attribute(.unique) public var slug: String

    /// Human-facing label. Separate from `slug` so the display name can be
    /// localised or reworded without renaming the key everything points at.
    public var displayName: String

    /// Decay-weighted score, normalised to `0...1`.
    ///
    /// Computed by ``PAgentCore/InterestGraphUpdater``, never by hand — the
    /// §6.2 formula has to stay in one place or the half-life and λ drift
    /// apart.
    public var score: Double

    /// When `score` last moved. Decay is measured from here, so an
    /// empty-reinforcement pass must still advance it or the same interval
    /// gets charged twice.
    public var lastReinforcedAt: Date

    /// The user's standing judgement.
    ///
    /// `.rejected` is load-bearing beyond display: §5.2 requires the tag to
    /// stop participating in *any* recalculation, and
    /// ``PAgentCore/rankedForProfileCard(_:limit:)`` drops it rather than
    /// ranking it last — so a vetoed tag is structurally unable to reach the
    /// profile card, the only payload that leaves the device.
    public var userVerdict: UserVerdict

    /// Why this tag exists, for the §5.2 traceability UI.
    ///
    /// `.cascade` because evidence has no meaning without its tag: orphaned
    /// rows would accumulate every time the user vetoed something.
    @Relationship(deleteRule: .cascade, inverse: \TagEvidence.tag)
    public var evidence: [TagEvidence]

    public init(
        slug: String,
        displayName: String,
        score: Double = 0,
        lastReinforcedAt: Date,
        userVerdict: UserVerdict = .unreviewed,
        evidence: [TagEvidence] = []
    ) {
        self.slug = slug
        self.displayName = displayName
        self.score = score
        self.lastReinforcedAt = lastReinforcedAt
        self.userVerdict = userVerdict
        self.evidence = evidence
    }
}

/// One piece of evidence behind a tag (§5.2).
///
/// This table is what makes "可解释画像" real: the UI expands a tag into
/// "因为你在 9/14 去过 XX，10/2 分享了 YY", and the user can veto the tag on
/// the strength of seeing it.
@Model
public final class TagEvidence {
    /// Points at ``SignalEvent/id``.
    ///
    /// A plain UUID rather than a SwiftData relationship on purpose: signals
    /// expire on the §5.1 retention schedule while a tag can outlive them.
    /// A relationship would either resurrect expired signals or cascade-delete
    /// the tag's history; an id goes stale harmlessly, and the UI falls back
    /// to `rationale` when the signal is gone.
    public var signalEventID: UUID

    /// `confidence × sourceWeight` at extraction time.
    ///
    /// Stored as the already-weighted figure so a later change to
    /// ``PAgentCore/SignalSource/weight`` cannot silently rewrite history.
    public var weight: Double

    public var extractedAt: Date

    /// The on-device model's one-line reason, shown verbatim in the UI.
    public var rationale: String

    public var tag: InterestTag?

    public init(
        signalEventID: UUID,
        weight: Double,
        extractedAt: Date,
        rationale: String,
        tag: InterestTag? = nil
    ) {
        self.signalEventID = signalEventID
        self.weight = weight
        self.extractedAt = extractedAt
        self.rationale = rationale
        self.tag = tag
    }
}

/// The materialised profile, recomputed after each nightly digest (§5.3).
///
/// ## Why this table exists at all
///
/// R10: SwiftData's aggregate queries are weak. Computing top-tag scores on
/// the planning path would put a slow query in front of every request, so
/// §5.3 materialises the result here and the request path does one read.
///
/// If this ever needs to move to GRDB, the blast radius is this file plus the
/// digest job — nothing in `PAgentCore` knows SwiftData exists.
@Model
public final class ProfileSnapshot {
    #Index<ProfileSnapshot>([\.generatedAt])

    public var generatedAt: Date

    /// The ≤500-token card — the only personal payload that leaves the device
    /// (§6.3). Stored as the exact markdown that was sent, so the settings
    /// screen can show the user what left (§9.3 clause 5.1.2).
    public var cardMarkdown: String

    /// Measured with `tokenCount(for:)`, never estimated (§6.3). Kept so an
    /// over-budget card is detectable after the fact, not just at generation.
    public var cardTokenCount: Int

    public var topTagSlugs: [String]

    public var routineSummary: String

    public init(
        generatedAt: Date,
        cardMarkdown: String,
        cardTokenCount: Int,
        topTagSlugs: [String],
        routineSummary: String
    ) {
        self.generatedAt = generatedAt
        self.cardMarkdown = cardMarkdown
        self.cardTokenCount = cardTokenCount
        self.topTagSlugs = topTagSlugs
        self.routineSummary = routineSummary
    }
}

// MARK: - Queries

extension InterestTag {
    /// Tags eligible for the profile card, strongest first.
    ///
    /// The `userVerdict != .rejected` filter is in the predicate rather than
    /// applied afterwards so a caller cannot forget it. §6.3 makes the card
    /// the device's only outbound payload, so this is the last place a vetoed
    /// tag can be stopped cheaply.
    public static func forProfileCard(limit: Int? = nil) -> FetchDescriptor<InterestTag> {
        // Bound to a local first because `#Predicate` compiles its closure into
        // a query expression rather than merely typechecking it, and neither
        // way of naming the case inline survives that: `.rejected` fails as
        // "member access without an explicit base", and `UserVerdict.rejected`
        // becomes a key path on the metatype ("key path cannot refer to enum
        // case"). A captured constant arrives as a plain value, which is the
        // same shape `fromSource(_:)` gets from its parameter.
        let rejected = UserVerdict.rejected
        var descriptor = FetchDescriptor<InterestTag>(
            predicate: #Predicate { $0.userVerdict != rejected && $0.score > 0 },
            sortBy: [
                SortDescriptor(\.score, order: .reverse),
                // Ties broken by slug so the card — and the cached prefix it
                // sits in — is byte-identical for identical scores (R8).
                SortDescriptor(\.slug, order: .forward),
            ]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Everything the nightly decay pass must touch.
    ///
    /// Confirmed tags are included: ``PAgentCore/InterestGraphUpdater`` gives
    /// them λ = 0 but still advances their timestamp, and excluding them here
    /// would leave that to a second code path.
    public static func allForDecay() -> FetchDescriptor<InterestTag> {
        FetchDescriptor<InterestTag>(
            sortBy: [SortDescriptor(\.slug, order: .forward)]
        )
    }

    /// Tags the user has not yet ruled on, for the review UI.
    public static func awaitingReview() -> FetchDescriptor<InterestTag> {
        let unreviewed = UserVerdict.unreviewed
        return FetchDescriptor<InterestTag>(
            predicate: #Predicate { $0.userVerdict == unreviewed },
            sortBy: [SortDescriptor(\.score, order: .reverse)]
        )
    }

    public static func withSlug(_ slug: String) -> FetchDescriptor<InterestTag> {
        var descriptor = FetchDescriptor<InterestTag>(
            predicate: #Predicate { $0.slug == slug }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }
}

extension ProfileSnapshot {
    /// The current snapshot. One read on the planning path (§5.3).
    public static func latest() -> FetchDescriptor<ProfileSnapshot> {
        var descriptor = FetchDescriptor<ProfileSnapshot>(
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Snapshots older than the newest few, for pruning.
    ///
    /// A handful of history is useful — it is how a user can see their card
    /// changing — but the table is append-only per digest and would otherwise
    /// grow forever.
    public static func supersededBefore(_ cutoff: Date) -> FetchDescriptor<ProfileSnapshot> {
        FetchDescriptor<ProfileSnapshot>(
            predicate: #Predicate { $0.generatedAt < cutoff },
            sortBy: [SortDescriptor(\.generatedAt, order: .forward)]
        )
    }
}
