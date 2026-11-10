import Foundation
import Testing

@testable import PAgentCore

private let epoch = Date(timeIntervalSince1970: 1_793_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func reinforcement(
    _ confidence: Double,
    _ source: SignalSource = .calendar
) -> TagReinforcement {
    TagReinforcement(confidence: confidence, source: source, signalEventID: UUID())
}

@Suite("SignalSource weights")
struct SignalSourceTests {
    @Test("deliberate action outweighs passive inference")
    func weightOrdering() {
        // §6.2's ordering is a privacy posture as much as an accuracy one:
        // what the user chose to tell us counts most, what we inferred from
        // their movements counts least.
        #expect(SignalSource.shared.weight == 1.0)
        #expect(SignalSource.manual.weight == 1.0)
        #expect(SignalSource.shared.weight > SignalSource.calendar.weight)
        #expect(SignalSource.calendar.weight > SignalSource.visit.weight)
        #expect(SignalSource.visit.weight > SignalSource.photo.weight)
        #expect(SignalSource.photo.weight > SignalSource.health.weight)
    }

    @Test("every weight is a usable multiplier")
    func weightsAreInRange() {
        for source in SignalSource.allCases {
            #expect(source.weight > 0)
            #expect(source.weight <= 1)
        }
    }
}

@Suite("TagReinforcement")
struct TagReinforcementTests {
    @Test("clamps a confidence the on-device model got wrong")
    func clampsConfidence() {
        // A 3B model asked for a 0...1 probability will occasionally answer
        // 1.4. Letting that through would let one signal saturate a tag.
        #expect(reinforcement(1.4).confidence == 1.0)
        #expect(reinforcement(-0.2).confidence == 0.0)
        #expect(reinforcement(0.65).confidence == 0.65)
    }

    @Test("weights the contribution by source")
    func weightsContribution() {
        #expect(reinforcement(0.5, .shared).weightedContribution == 0.5)
        #expect(abs(reinforcement(0.5, .photo).weightedContribution - 0.2) < 1e-12)
    }
}

@Suite("DecayModel")
struct DecayModelTests {
    @Test("halves the score over one half-life")
    func halfLife() {
        let model = DecayModel.ninetyDays
        #expect(abs(model.factor(elapsed: 90 * day) - 0.5) < 1e-9)
        #expect(abs(model.factor(elapsed: 180 * day) - 0.25) < 1e-9)
    }

    @Test("a week barely moves a 90-day half-life")
    func weekIsGentle() {
        // §6.2's stated intent: interests change, but not within a week.
        #expect(DecayModel.ninetyDays.factor(elapsed: 7 * day) > 0.94)
    }

    @Test("derives lambda from the half-life so the two cannot drift")
    func lambdaIsDerived() {
        let model = DecayModel(halfLife: 30 * day)
        #expect(abs(model.lambda * 30 * day - log(2)) < 1e-12)
    }

    @Test("no elapsed time means no decay")
    func zeroElapsed() {
        #expect(DecayModel.ninetyDays.factor(elapsed: 0) == 1)
    }

    @Test("a backwards clock does not amplify the score")
    func negativeElapsedIsFloored() {
        // A timezone change, an NTP correction, or a user setting the date
        // back would otherwise make exp(-λ·Δt) > 1 and inflate every tag.
        #expect(DecayModel.ninetyDays.factor(elapsed: -30 * day) == 1)
    }
}

@Suite("InterestGraphUpdater")
struct InterestGraphUpdaterTests {
    private let updater = InterestGraphUpdater()

    @Test("applies §6.2's decay-then-reinforce formula")
    func decaysThenReinforces() {
        let state = InterestTagState(slug: "cuisine.sichuan", score: 0.8, lastReinforcedAt: epoch)
        let updated = updater.update(state, with: [reinforcement(0.5, .shared)], at: epoch + 90 * day)

        // 0.8 × 0.5 (one half-life) + 0.5 × 1.0 = 0.9
        #expect(abs(updated.score - 0.9) < 1e-9)
    }

    @Test("sums multiple reinforcements")
    func sumsReinforcements() {
        let state = InterestTagState(slug: "activity.hiking", score: 0, lastReinforcedAt: epoch)
        let updated = updater.update(
            state,
            with: [reinforcement(0.5, .calendar), reinforcement(0.5, .visit)],
            at: epoch
        )

        // 0.5 × 0.8 + 0.5 × 0.6 = 0.7
        #expect(abs(updated.score - 0.7) < 1e-9)
    }

    @Test("normalises to 0...1")
    func clampsScore() {
        let state = InterestTagState(slug: "activity.hiking", score: 0.9, lastReinforcedAt: epoch)
        let updated = updater.update(
            state,
            with: [reinforcement(1.0, .shared), reinforcement(1.0, .shared)],
            at: epoch
        )
        #expect(updated.score == 1.0)
    }

    @Test("a confirmed tag does not decay")
    func confirmedDoesNotDecay() {
        // §6.2 sets λ = 0 for confirmed tags: the user has told us this is
        // true of them, so it should not fade just because they generated no
        // signals about it this quarter.
        let state = InterestTagState(
            slug: "cuisine.yunnan",
            score: 0.7,
            lastReinforcedAt: epoch,
            verdict: .confirmed
        )
        let updated = updater.decayed(state, at: epoch + 365 * day)
        #expect(updated.score == 0.7)
    }

    @Test("a confirmed tag still accrues new evidence")
    func confirmedStillReinforces() {
        let state = InterestTagState(
            slug: "cuisine.yunnan",
            score: 0.5,
            lastReinforcedAt: epoch,
            verdict: .confirmed
        )
        let updated = updater.update(state, with: [reinforcement(0.25, .shared)], at: epoch + 10 * day)
        #expect(abs(updated.score - 0.75) < 1e-9)
    }

    @Test("a rejected tag is inert — its evidence stops counting entirely")
    func rejectedIsInert() {
        // §5.2 requires rejected evidence to drop out of *any* recalculation.
        // A rejected tag that quietly kept accruing score would reappear the
        // moment the display filter was relaxed.
        let state = InterestTagState(
            slug: "activity.mall",
            score: 0.4,
            lastReinforcedAt: epoch,
            verdict: .rejected
        )
        let updated = updater.update(
            state,
            with: [reinforcement(1.0, .shared), reinforcement(1.0, .shared)],
            at: epoch + 30 * day
        )

        #expect(updated == state)
        #expect(updated.score == 0.4)
        // Not even the timestamp moves — nothing about it was recalculated.
        #expect(updated.lastReinforcedAt == epoch)
    }

    @Test("advances the clock even with no new evidence")
    func advancesTimestamp() {
        // Decay is measured from the last time the score moved. If a no-op
        // pass left the timestamp alone, the same interval would be charged
        // again on the next nightly run.
        let state = InterestTagState(slug: "activity.hiking", score: 0.8, lastReinforcedAt: epoch)
        let once = updater.decayed(state, at: epoch + 45 * day)
        let twice = updater.decayed(once, at: epoch + 90 * day)

        let direct = updater.decayed(state, at: epoch + 90 * day)
        #expect(abs(twice.score - direct.score) < 1e-9)
    }

    @Test("repeated decay converges toward zero without going negative")
    func convergesToZero() {
        var state = InterestTagState(slug: "activity.stale", score: 1.0, lastReinforcedAt: epoch)
        for quarter in 1...20 {
            state = updater.decayed(state, at: epoch + Double(quarter) * 90 * day)
        }
        #expect(state.score >= 0)
        #expect(state.score < 1e-5)
    }
}

@Suite("Profile card ranking")
struct ProfileCardRankingTests {
    @Test("orders by descending score")
    func ordersByScore() {
        let ranked = rankedForProfileCard([
            InterestTagState(slug: "b", score: 0.3, lastReinforcedAt: epoch),
            InterestTagState(slug: "a", score: 0.9, lastReinforcedAt: epoch),
            InterestTagState(slug: "c", score: 0.6, lastReinforcedAt: epoch),
        ])
        #expect(ranked.map(\.slug) == ["a", "c", "b"])
    }

    @Test("breaks ties by slug so the cached prefix stays byte-identical")
    func deterministicTies() {
        // Two tags on the same score must not swap places between runs: the
        // card sits inside the cached prefix, and a reordering reads
        // identically to a human while invalidating the cache (R8).
        let tags = [
            InterestTagState(slug: "zeta", score: 0.5, lastReinforcedAt: epoch),
            InterestTagState(slug: "alpha", score: 0.5, lastReinforcedAt: epoch),
            InterestTagState(slug: "mu", score: 0.5, lastReinforcedAt: epoch),
        ]
        #expect(rankedForProfileCard(tags).map(\.slug) == ["alpha", "mu", "zeta"])
        // Same answer regardless of input order.
        #expect(rankedForProfileCard(tags.reversed()).map(\.slug) == ["alpha", "mu", "zeta"])
    }

    @Test("rejected tags are removed, not merely ranked last")
    func excludesRejected() {
        // §6.3 makes the card the only payload that leaves the device, so a
        // rejected tag must be structurally unable to appear in it.
        let ranked = rankedForProfileCard([
            InterestTagState(slug: "kept", score: 0.2, lastReinforcedAt: epoch),
            InterestTagState(slug: "rejected", score: 0.99, lastReinforcedAt: epoch, verdict: .rejected),
        ])
        #expect(ranked.map(\.slug) == ["kept"])
    }

    @Test("drops zero-scored tags")
    func excludesZeroScore() {
        let ranked = rankedForProfileCard([
            InterestTagState(slug: "faded", score: 0, lastReinforcedAt: epoch),
            InterestTagState(slug: "live", score: 0.1, lastReinforcedAt: epoch),
        ])
        #expect(ranked.map(\.slug) == ["live"])
    }

    @Test("honours a limit")
    func appliesLimit() {
        let tags = (1...10).map {
            InterestTagState(slug: "tag\($0)", score: Double($0) / 10, lastReinforcedAt: epoch)
        }
        #expect(rankedForProfileCard(tags, limit: 3).map(\.slug) == ["tag10", "tag9", "tag8"])
        #expect(rankedForProfileCard(tags, limit: 0).isEmpty)
    }
}
