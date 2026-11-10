import Foundation

/// Where a signal came from. The weight attached to each is both an accuracy
/// judgement and a privacy posture (IMPLEMENTATION.md §6.2): what the user
/// *did deliberately* counts most, what was *passively inferred* counts least.
public enum SignalSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// Shared into the app from another app via the Share Extension.
    case shared
    /// Hand-picked by the user, e.g. the onboarding interest picker (R7).
    case manual
    /// A calendar event the user created.
    case calendar
    /// A repeated visit detected by region/visit monitoring.
    case visit
    /// A photo's capture location (metadata only — never pixels, §4.1).
    case photo
    /// Inferred from HealthKit sleep/activity (Phase 3).
    case health

    public var weight: Double {
        switch self {
        case .shared, .manual: 1.0
        case .calendar: 0.8
        case .visit: 0.6
        case .photo: 0.4
        case .health: 0.3
        }
    }
}

/// The user's standing judgement on a tag (§5.2).
public enum UserVerdict: String, Sendable, Codable, Hashable {
    case unreviewed
    case confirmed
    case rejected
}

/// One piece of evidence pushing a tag's score up.
public struct TagReinforcement: Sendable, Hashable {
    /// The on-device model's confidence, clamped to `0...1` on construction —
    /// a 3B model asked for a probability will occasionally return `1.4`.
    public let confidence: Double
    public let source: SignalSource
    /// Traces back to `SignalEvent.id`, so the UI can answer "why this tag?".
    public let signalEventID: UUID

    public init(confidence: Double, source: SignalSource, signalEventID: UUID) {
        self.confidence = min(max(confidence, 0), 1)
        self.source = source
        self.signalEventID = signalEventID
    }

    public var weightedContribution: Double { confidence * source.weight }
}

/// A tag's derived state. The materialised counterpart of `InterestTag` (§5.3)
/// keeps this out of the request path.
public struct InterestTagState: Sendable, Hashable, Identifiable {
    public var slug: String
    /// Normalised to `0...1`.
    public var score: Double
    public var lastReinforcedAt: Date
    public var verdict: UserVerdict

    public var id: String { slug }

    public init(slug: String, score: Double, lastReinforcedAt: Date, verdict: UserVerdict = .unreviewed) {
        self.slug = slug
        self.score = min(max(score, 0), 1)
        self.lastReinforcedAt = lastReinforcedAt
        self.verdict = verdict
    }
}

/// Exponential decay with a half-life.
///
/// §6.2 picks 90 days on the reasoning that interests genuinely change, but
/// not within a week. The half-life is the tunable knob; λ is derived so the
/// two can never drift apart.
public struct DecayModel: Sendable, Hashable {
    public static let ninetyDays = DecayModel(halfLife: 90 * 24 * 60 * 60)

    public let halfLife: TimeInterval

    public init(halfLife: TimeInterval) {
        precondition(halfLife > 0, "halfLife must be positive")
        self.halfLife = halfLife
    }

    public var lambda: Double { log(2) / halfLife }

    /// `exp(-λ · Δt)`, with `Δt` floored at zero.
    ///
    /// A negative interval means the clock moved backwards (timezone change,
    /// NTP correction, a user setting the date). Decaying by a negative
    /// interval would *amplify* the score, so the floor is a correctness
    /// guard rather than defensive padding.
    public func factor(elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 1 }
        return exp(-lambda * elapsed)
    }
}

/// Applies §6.2's decay-and-reinforce rule to a tag.
public struct InterestGraphUpdater: Sendable {
    private let decay: DecayModel

    public init(decay: DecayModel = .ninetyDays) {
        self.decay = decay
    }

    /// `score_new = score_old × exp(-λ·Δt) + Σ(confidence × sourceWeight)`
    ///
    /// Two verdicts change the arithmetic:
    ///
    /// - `.confirmed` → λ = 0. The user has said this is true of them, so it
    ///   does not fade while they are not generating signals about it.
    /// - `.rejected` → the tag is inert. It neither decays nor reinforces, and
    ///   the reinforcements passed in are discarded, because §5.2 requires
    ///   rejected evidence to stop participating in *any* recalculation. A
    ///   rejected tag that quietly kept accruing score would reappear the
    ///   moment the filter was relaxed.
    public func update(
        _ state: InterestTagState,
        with reinforcements: [TagReinforcement],
        at now: Date
    ) -> InterestTagState {
        guard state.verdict != .rejected else { return state }

        let decayed: Double
        switch state.verdict {
        case .confirmed:
            decayed = state.score
        case .unreviewed, .rejected:
            decayed = state.score * decay.factor(elapsed: now.timeIntervalSince(state.lastReinforcedAt))
        }

        let gain = reinforcements.reduce(0) { $0 + $1.weightedContribution }

        var updated = state
        updated.score = min(max(decayed + gain, 0), 1)
        // Decay is measured from the last time the score moved, so an
        // empty-reinforcement pass must still advance the clock or the same
        // interval would be charged twice on the next run.
        updated.lastReinforcedAt = now
        return updated
    }

    /// Decay with no new evidence — the common case for most tags on any
    /// given night.
    public func decayed(_ state: InterestTagState, at now: Date) -> InterestTagState {
        update(state, with: [], at: now)
    }
}

/// Ranks tags for the profile card.
///
/// Rejected tags are removed, not merely sorted last: §6.3 makes the card the
/// only payload that leaves the device, so a rejected tag must be structurally
/// incapable of appearing in it.
public func rankedForProfileCard(
    _ states: [InterestTagState],
    limit: Int? = nil
) -> [InterestTagState] {
    let eligible = states.filter { $0.verdict != .rejected && $0.score > 0 }
    let sorted = eligible.sorted {
        // Ties broken by slug so the card — and therefore the cached prefix
        // it sits in — is byte-identical for identical scores (R8).
        $0.score == $1.score ? $0.slug < $1.slug : $0.score > $1.score
    }
    guard let limit else { return sorted }
    return Array(sorted.prefix(max(0, limit)))
}
