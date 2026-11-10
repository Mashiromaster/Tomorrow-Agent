import Foundation
import SwiftData

import PAgentCore

/// The append-only raw signal log (IMPLEMENTATION.md §5.1).
///
/// ## Relationship to `PAgentCore.SignalRecord`
///
/// This class is the *storage* form; ``PAgentCore/SignalRecord`` is the
/// *value* form. The split is not ceremony:
///
/// - A `@Model` class is managed by its `ModelContext` and is **not
///   `Sendable`**. The agent loop is `async` and crosses isolation
///   boundaries, so it can only be handed value types.
/// - Keeping the planning logic off this type is what let all of it be built
///   and tested before Xcode was installed (§10 前置).
///
/// Convert at the boundary — see `Bridging.swift`.
@Model
public final class SignalEvent {
    /// Both access patterns the digest needs: a window over `occurredAt`
    /// (§6.1 sorts by it) and a per-source sweep for the settings screen's
    /// "turn this source off and forget it" action (§9.3 clause 5.1.1).
    #Index<SignalEvent>([\.occurredAt], [\.source])

    /// Stable across a replay. Unique because §5.2's `TagEvidence` points
    /// back here by id, and a duplicate would double-count one signal.
    @Attribute(.unique) public var id: UUID

    /// Stored as the raw string, so adding a `SignalSource` case does not
    /// renumber the existing rows.
    public var source: SignalSource

    /// When the described thing happened — not when it was captured. A photo
    /// imported today but taken last year sorts, and expires, by its own date.
    public var occurredAt: Date

    /// JSON-encoded ``PAgentCore/SignalPayload``.
    ///
    /// §5.1 keeps this source-specific and un-normalised on the grounds that
    /// the normalisation rules *will* change and replaying the original
    /// signal is the only way to correct a bad extraction. Storing bytes
    /// rather than a flattened set of columns is what makes that true years
    /// later: adding an enum case cannot alter how an existing row decodes.
    public var payload: Data

    /// `nil` while pending. The digest work queue is `digestedAt == nil`.
    public var digestedAt: Date?

    /// The enforcement point for data minimisation (§5.1, §9.3). Set from
    /// ``PAgentCore/RetentionPolicy`` at capture time so the horizon is a
    /// stored fact rather than a computation that could drift between callers.
    public var retentionUntil: Date

    public init(
        id: UUID,
        source: SignalSource,
        occurredAt: Date,
        payload: Data,
        digestedAt: Date? = nil,
        retentionUntil: Date
    ) {
        self.id = id
        self.source = source
        self.occurredAt = occurredAt
        self.payload = payload
        self.digestedAt = digestedAt
        self.retentionUntil = retentionUntil
    }
}

// MARK: - Queries

extension SignalEvent {
    /// Pending signals, oldest first.
    ///
    /// Ordered because §6.1 feeds the result straight into
    /// ``PAgentCore/DigestBatcher``, which preserves input order — a day's
    /// signals read as a narrative and shuffling them costs the model the
    /// sequence.
    public static func pendingForDigest(limit: Int? = nil) -> FetchDescriptor<SignalEvent> {
        var descriptor = FetchDescriptor<SignalEvent>(
            predicate: #Predicate { $0.digestedAt == nil },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Signals past their retention horizon.
    ///
    /// Unconditional: a signal that was never digested is deleted anyway.
    /// Holding one back "just until we get to it" would quietly turn the
    /// 180-day promise into an indefinite one whenever the digest fell behind
    /// — which is the case App Review clause 5.1.1 asks about.
    public static func expired(asOf now: Date) -> FetchDescriptor<SignalEvent> {
        FetchDescriptor<SignalEvent>(
            predicate: #Predicate { $0.retentionUntil <= now },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
    }

    /// Every signal from one source, for the settings-screen purge.
    ///
    /// §9.3 promises each of the four data sources can be switched off
    /// independently and that the feature then degrades rather than breaking.
    /// Revoking a source has to delete what it already contributed, or the
    /// toggle is cosmetic.
    public static func fromSource(_ source: SignalSource) -> FetchDescriptor<SignalEvent> {
        FetchDescriptor<SignalEvent>(
            predicate: #Predicate { $0.source == source },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
    }
}
