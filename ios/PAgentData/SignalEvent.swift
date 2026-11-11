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
    ///
    /// The source index is over `sourceRaw`, not `source` — see below.
    #Index<SignalEvent>([\.occurredAt], [\.sourceRaw])

    /// Stable across a replay. Unique because §5.2's `TagEvidence` points
    /// back here by id, and a duplicate would double-count one signal.
    @Attribute(.unique) public var id: UUID

    /// `SignalSource.rawValue`. **This is the stored column**; `source` below
    /// is a plain computed accessor over it.
    ///
    /// SwiftData persists a `Codable` enum as a *composite* attribute, and
    /// CoreData can neither index one nor lower it into a predicate:
    ///
    ///     NSInvalidArgumentException: Can't create an index element with
    ///     composite property                      — at container creation
    ///     Unsupported Predicate: Captured/constant values of type
    ///     'SignalSource' are not supported        — at fetch
    ///
    /// Xcode 27.2 tolerates both; 26.6 raises both. Since the first is a
    /// launch-time abort, the version a *user's* device runs decides whether
    /// the app starts — so storing the raw string is the correct fix rather
    /// than a workaround for an old toolchain. A `String` is also indexable,
    /// which a composite is not.
    ///
    /// Storing the raw value (not an `Int`) also means adding a case cannot
    /// renumber existing rows.
    public var sourceRaw: String

    /// Typed accessor over ``sourceRaw``. Computed, so SwiftData does not
    /// persist it and no predicate can reach it — query `sourceRaw` instead,
    /// as `fromSource(_:)` does.
    ///
    /// An unrecognised stored value decodes to `.manual` rather than trapping:
    /// a row written by a newer build must not crash an older one, and §5.1's
    /// replay guarantee means the original bytes are still in `payload`.
    public var source: SignalSource {
        get { SignalSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

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
        self.sourceRaw = source.rawValue
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
    /// Matches on ``sourceRaw``: a predicate cannot compare against a
    /// `Codable` enum (see that property's note), and a `String` can.
    public static func fromSource(_ source: SignalSource) -> FetchDescriptor<SignalEvent> {
        let raw = source.rawValue
        return FetchDescriptor<SignalEvent>(
            predicate: #Predicate { $0.sourceRaw == raw },
            sortBy: [SortDescriptor(\.occurredAt, order: .forward)]
        )
    }
}
