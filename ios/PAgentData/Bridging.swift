import Foundation
import SwiftData

import PAgentCore

/// Conversion between the `@Model` storage types and the `PAgentCore` value
/// types.
///
/// ## Why the boundary exists
///
/// A `@Model` class is managed by its `ModelContext` and is **not
/// `Sendable`**. Touching one from the wrong actor is undefined behaviour,
/// and Swift 6 strict concurrency will not let it cross an isolation boundary
/// at all. The agent loop (`PAgentCore.AgentLoop`) is `async` and runs tool
/// calls in a task group, so everything it sees has to be a value.
///
/// Converting at a single seam also keeps the §5 schema honest: nothing in
/// `PAgentCore` imports SwiftData, which is what let the planning logic be
/// built and tested before Xcode existed on this machine (§10 前置), and what
/// bounds R10's migration-to-GRDB blast radius to this directory.
///
/// Direction of travel:
///
/// ```
///  capture ──▶ SignalRecord ──▶ SignalEvent        (into the store)
///  digest  ──▶ SignalEvent  ──▶ DigestItem         (out, for the model)
///  planning ─▶ ItineraryProposalRecord ──▶ ItineraryProposal
/// ```

// MARK: - Signals

extension SignalEvent {
    /// Builds a storage row from a captured value.
    public convenience init(_ record: SignalRecord) {
        self.init(
            id: record.id,
            source: record.source,
            occurredAt: record.occurredAt,
            payload: record.payload,
            digestedAt: record.digestedAt,
            retentionUntil: record.retentionUntil
        )
    }

    /// Snapshots this row as a `Sendable` value.
    ///
    /// Call on the context's own actor; the result can then go anywhere.
    public var record: SignalRecord {
        SignalRecord(
            id: id,
            source: source,
            occurredAt: occurredAt,
            payload: payload,
            digestedAt: digestedAt,
            retentionUntil: retentionUntil
        )
    }

    public func decodedPayload() throws -> SignalPayload {
        try JSONDecoder().decode(SignalPayload.self, from: payload)
    }
}

// MARK: - Interest graph

extension InterestTag {
    /// The derived state ``PAgentCore/InterestGraphUpdater`` operates on.
    ///
    /// Evidence is deliberately not included: the §6.2 formula consumes
    /// *new* reinforcements and the already-accumulated `score`, never the
    /// historical evidence rows. Those exist for the explanation UI (§5.2).
    public var state: InterestTagState {
        InterestTagState(
            slug: slug,
            score: score,
            lastReinforcedAt: lastReinforcedAt,
            verdict: userVerdict
        )
    }

    /// Writes an updated state back.
    ///
    /// `slug` is not copied across — it is the identity of the row, and
    /// ``PAgentCore/InterestGraphUpdater`` never changes it. Asserting that
    /// rather than silently accepting a mismatched write catches a caller
    /// that paired the wrong state with the wrong tag.
    public func apply(_ updated: InterestTagState) {
        precondition(
            updated.slug == slug,
            "tried to apply state for `\(updated.slug)` to tag `\(slug)`"
        )
        score = updated.score
        lastReinforcedAt = updated.lastReinforcedAt
        userVerdict = updated.verdict
    }

    /// Records a reinforcement and its one-line reason.
    ///
    /// Stores the *already-weighted* contribution so a later change to
    /// ``PAgentCore/SignalSource/weight`` cannot silently rewrite history.
    public func addEvidence(_ reinforcement: TagReinforcement, rationale: String, at now: Date) {
        evidence.append(
            TagEvidence(
                signalEventID: reinforcement.signalEventID,
                weight: reinforcement.weightedContribution,
                extractedAt: now,
                rationale: rationale,
                tag: self
            )
        )
    }
}

extension ProfileSnapshot {
    public convenience init(_ record: ProfileSnapshotRecord) {
        self.init(
            generatedAt: record.generatedAt,
            cardMarkdown: record.cardMarkdown,
            cardTokenCount: record.cardTokenCount,
            topTagSlugs: record.topTagSlugs,
            routineSummary: record.routineSummary
        )
    }

    public var record: ProfileSnapshotRecord {
        ProfileSnapshotRecord(
            generatedAt: generatedAt,
            cardMarkdown: cardMarkdown,
            cardTokenCount: cardTokenCount,
            topTagSlugs: topTagSlugs,
            routineSummary: routineSummary
        )
    }

    /// The card as the request builder wants it.
    ///
    /// Reconstructed rather than re-rendered: the stored markdown is the exact
    /// text that was sent, and re-rendering it from tags could produce
    /// different bytes and break the cached prefix mid-day (R8).
    public var profileCard: ProfileCard {
        ProfileCard(
            markdown: cardMarkdown,
            tokenCount: cardTokenCount,
            includedSlugs: topTagSlugs,
            omittedSlugs: []
        )
    }
}

// MARK: - Proposals

extension ItineraryItem {
    public convenience init(_ record: ItineraryItemRecord, proposal: ItineraryProposal? = nil) {
        self.init(
            id: record.id,
            title: record.title,
            startsAt: record.startsAt,
            endsAt: record.endsAt,
            placeName: record.placeName,
            coordinate: record.coordinate,
            travelFromPrevious: record.travelFromPrevious,
            rationale: record.rationale,
            alternatives: record.alternatives,
            proposal: proposal
        )
    }

    /// Reconstructs the validated value type.
    ///
    /// `throws` because ``PAgentCore/ItineraryItemRecord`` validates on
    /// construction and a stored row could violate those rules — an older
    /// schema version, or a hand-edited database. Surfacing that beats
    /// presenting a plan with a blank rationale or an inverted interval.
    public func record() throws -> ItineraryItemRecord {
        try ItineraryItemRecord(
            id: id,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            placeName: placeName,
            coordinate: coordinate,
            travelFromPrevious: travelFromPrevious,
            rationale: rationale,
            alternatives: alternatives
        )
    }
}

extension ItineraryProposal {
    /// Builds a storage row, wiring up the item relationship.
    public convenience init(_ record: ItineraryProposalRecord, routingRationale: String = "") {
        self.init(
            id: record.id,
            createdAt: record.createdAt,
            requestSummary: record.requestSummary,
            status: record.status,
            modelUsed: record.modelUsed,
            routingRationale: routingRationale,
            items: [],
            committedEventIdentifiers: record.committedEventIdentifiers
        )
        items = record.items.map { ItineraryItem($0, proposal: self) }
    }

    public func record() throws -> ItineraryProposalRecord {
        ItineraryProposalRecord(
            id: id,
            createdAt: createdAt,
            requestSummary: requestSummary,
            status: status,
            modelUsed: modelUsed,
            items: try items.map { try $0.record() },
            committedEventIdentifiers: committedEventIdentifiers
        )
    }

    /// Applies a status transition that the value type has already validated.
    ///
    /// The lifecycle rules live on ``PAgentCore/ItineraryProposalRecord``
    /// (where they are unit-tested); this only mirrors the outcome. Callers
    /// mutate the record, then write it back here — so there is no second,
    /// unvalidated path into `.committed`.
    public func apply(_ record: ItineraryProposalRecord) {
        precondition(
            record.id == id,
            "tried to apply proposal \(record.id) to row \(id)"
        )
        status = record.status
        committedEventIdentifiers = record.committedEventIdentifiers
    }
}
