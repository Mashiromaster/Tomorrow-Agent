import Foundation

/// Where a proposal is in its life (§5.4).
///
/// The sequence encodes the design's central promise: nothing reaches the
/// user's calendar without passing through `.presented` and an explicit
/// confirmation. See ``ItineraryProposalRecord/confirm(eventIdentifiers:at:)``.
public enum ProposalStatus: String, Sendable, Codable, CaseIterable, Hashable {
    /// Being assembled; the user has not seen it.
    case draft
    /// Shown to the user, awaiting their decision.
    case presented
    /// Written to EventKit. Reversible — see `undo`.
    case committed
    /// Rejected, or undone after a commit.
    case discarded
}

public enum ProposalError: Error, Sendable, Equatable {
    /// §5.4: every item must justify itself. A recommendation with no reason
    /// is a black box, and the user cannot sanity-check it.
    case missingRationale(itemTitle: String)
    case endsBeforeItStarts(itemTitle: String)
    /// A transition the lifecycle does not allow, e.g. committing a draft the
    /// user has not been shown.
    case illegalTransition(from: ProposalStatus, to: ProposalStatus)
    /// A commit with no EventKit identifiers would be unundoable (§5.4).
    case commitWithoutEventIdentifiers
    case nothingToUndo(status: ProposalStatus)
}

/// One stop in a proposal.
///
/// The initialiser rejects an empty `rationale`, so §5.4's "必填，不允许黑箱推荐"
/// is a property of the type rather than a convention the UI has to remember.
public struct ItineraryItemRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let startsAt: Date
    public let endsAt: Date
    public let placeName: String?
    public let coordinate: Coordinate?
    /// Travel time from the previous item. `nil` on the first item, or when
    /// no route was looked up.
    public let travelFromPrevious: TimeInterval?
    /// Why this item, in one line. Shown next to it in the UI.
    public let rationale: String
    /// Swappable alternatives, so a user who dislikes one stop does not have
    /// to reject the whole plan.
    public let alternatives: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        startsAt: Date,
        endsAt: Date,
        placeName: String? = nil,
        coordinate: Coordinate? = nil,
        travelFromPrevious: TimeInterval? = nil,
        rationale: String,
        alternatives: [String] = []
    ) throws {
        let trimmedRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRationale.isEmpty else {
            throw ProposalError.missingRationale(itemTitle: title)
        }
        guard endsAt > startsAt else {
            throw ProposalError.endsBeforeItStarts(itemTitle: title)
        }

        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.placeName = placeName
        self.coordinate = coordinate
        self.travelFromPrevious = travelFromPrevious
        self.rationale = trimmedRationale
        self.alternatives = alternatives
    }

    public var duration: TimeInterval { endsAt.timeIntervalSince(startsAt) }
}

/// A problem with a plan that the model produced but a human would notice.
public enum ItineraryWarning: Sendable, Hashable {
    /// Two stops overlap in time.
    case overlap(earlier: String, later: String)
    /// The gap between two stops does not cover the travel time between them
    /// — the plan reads fine and cannot actually be executed.
    case unreachable(from: String, to: String, shortfallSeconds: TimeInterval)
}

/// A proposal awaiting confirmation (§5.4).
///
/// ## Why the write path is a method here and not a tool
///
/// §7.2 keeps `create_calendar_events` out of the model's tool set, so the
/// only way anything reaches EventKit is ``confirm(eventIdentifiers:at:)`` —
/// called by the UI after a tap. That makes prompt injection from shared web
/// content (§9.4) unable to touch the calendar no matter how thoroughly it
/// compromises the model: the worst it can produce is a proposal the user
/// then sees and rejects.
public struct ItineraryProposalRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let requestSummary: String
    public private(set) var status: ProposalStatus
    /// Which model produced this, for §4.3 cost attribution and R5's
    /// router-accuracy review. Taken from `Router.Decision.modelIdentifier`.
    public let modelUsed: String
    public let items: [ItineraryItemRecord]
    /// EventKit identifiers written at commit time.
    ///
    /// §5.4's reason for storing them: undoing a trip becomes one
    /// deterministic delete rather than the user hunting down eight events.
    public private(set) var committedEventIdentifiers: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        requestSummary: String,
        status: ProposalStatus = .draft,
        modelUsed: String,
        items: [ItineraryItemRecord],
        committedEventIdentifiers: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestSummary = requestSummary
        self.status = status
        self.modelUsed = modelUsed
        // Sorted on construction: the model usually emits items in order, but
        // the UI and the feasibility check below both depend on it.
        self.items = items.sorted { $0.startsAt < $1.startsAt }
        self.committedEventIdentifiers = committedEventIdentifiers
    }

    // MARK: - Lifecycle

    /// Marks the proposal as shown to the user.
    public mutating func present() throws {
        guard status == .draft else {
            throw ProposalError.illegalTransition(from: status, to: .presented)
        }
        status = .presented
    }

    /// Records the user's confirmation and the events it produced.
    ///
    /// Only reachable from `.presented`: a draft the user has never seen
    /// cannot be committed, which is the lifecycle half of "写操作必须用户确认".
    /// Identifiers are required, because a commit without them could not be
    /// undone.
    public mutating func confirm(eventIdentifiers: [String], at _: Date) throws {
        guard status == .presented else {
            throw ProposalError.illegalTransition(from: status, to: .committed)
        }
        guard !eventIdentifiers.isEmpty else {
            throw ProposalError.commitWithoutEventIdentifiers
        }
        status = .committed
        committedEventIdentifiers = eventIdentifiers
    }

    /// Rejects a proposal the user does not want.
    public mutating func discard() throws {
        guard status == .draft || status == .presented else {
            throw ProposalError.illegalTransition(from: status, to: .discarded)
        }
        status = .discarded
    }

    /// Reverses a commit, returning the identifiers the caller must delete.
    ///
    /// The identifiers are handed back *and* cleared, so a second `undo` has
    /// nothing to return — a double-tap cannot ask EventKit to delete the same
    /// events twice.
    public mutating func undo() throws -> [String] {
        guard status == .committed else {
            throw ProposalError.nothingToUndo(status: status)
        }
        let identifiers = committedEventIdentifiers
        committedEventIdentifiers = []
        status = .discarded
        return identifiers
    }

    // MARK: - Feasibility

    /// Problems a human reviewer would catch.
    ///
    /// Worth checking before showing a plan: an overlap or an impossible
    /// connection reads perfectly well in prose. §7.4's parallel
    /// `get_travel_time` calls give the model the data to get this right, and
    /// this is where we verify it did.
    public func warnings() -> [ItineraryWarning] {
        var found: [ItineraryWarning] = []

        for (previous, next) in zip(items, items.dropFirst()) {
            if next.startsAt < previous.endsAt {
                found.append(.overlap(earlier: previous.title, later: next.title))
                continue
            }
            guard let travel = next.travelFromPrevious, travel > 0 else { continue }
            let gap = next.startsAt.timeIntervalSince(previous.endsAt)
            if gap < travel {
                found.append(
                    .unreachable(
                        from: previous.title,
                        to: next.title,
                        shortfallSeconds: travel - gap
                    )
                )
            }
        }

        return found
    }

    public var isExecutable: Bool { warnings().isEmpty }

    /// Wall-clock span from the first start to the last end.
    public var span: TimeInterval? {
        guard let first = items.first, let last = items.last else { return nil }
        return last.endsAt.timeIntervalSince(first.startsAt)
    }
}

// MARK: - Snapshot

/// The materialised profile, recomputed after each nightly digest (§5.3).
///
/// Exists because SwiftData's aggregate queries are weak (R10): computing
/// top-tag scores on the planning path would put a slow query in front of
/// every request. This is read instead.
public struct ProfileSnapshotRecord: Sendable, Hashable {
    public let generatedAt: Date
    /// The ≤500-token card — the only personal payload that leaves the device.
    public let cardMarkdown: String
    /// Measured with `tokenCount(for:)`, never estimated (§6.3).
    public let cardTokenCount: Int
    public let topTagSlugs: [String]
    public let routineSummary: String

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

    /// Builds a snapshot from a rendered card.
    public init(from card: ProfileCard, routineSummary: String, generatedAt: Date) {
        self.init(
            generatedAt: generatedAt,
            cardMarkdown: card.markdown,
            cardTokenCount: card.tokenCount,
            topTagSlugs: card.includedSlugs,
            routineSummary: routineSummary
        )
    }

    /// Whether the card is still within the §6.3 budget.
    public func fitsBudget(limit: Int = ProfileCardBuilder.defaultTokenLimit) -> Bool {
        cardTokenCount <= limit
    }
}
