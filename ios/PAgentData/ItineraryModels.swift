import Foundation
import SwiftData

import PAgentCore

/// A proposal awaiting the user's confirmation (IMPLEMENTATION.md §5.4).
///
/// ## The write path does not live here
///
/// This class stores a proposal; it does not commit one. §7.2 keeps
/// `create_calendar_events` out of the model's tool set, so the only route to
/// EventKit is the UI calling the commit service after an explicit tap. That
/// is what makes prompt injection from shared web content (§9.4) unable to
/// touch the calendar however thoroughly it compromises the model: the worst
/// it can produce is a row in this table that the user then rejects.
///
/// The legal status transitions live on ``PAgentCore/ItineraryProposalRecord``
/// where they are testable; this type is the persisted projection.
@Model
public final class ItineraryProposal {
    /// The status index is over `statusRaw` — see `SignalEvent.sourceRaw`
    /// for why a `Codable` enum cannot be the stored column.
    #Index<ItineraryProposal>([\.createdAt], [\.statusRaw])

    @Attribute(.unique) public var id: UUID

    public var createdAt: Date

    /// What the user asked for, in their words. Shown in the history list.
    public var requestSummary: String

    /// `ProposalStatus.rawValue` — the stored column. See
    /// ``SignalEvent/sourceRaw``.
    public var statusRaw: String

    /// Typed accessor over ``statusRaw``. Computed, so predicates must query
    /// `statusRaw` instead.
    ///
    /// An unrecognised value reads as `.draft`: the most conservative case,
    /// since §3.4 makes `.draft` the one state from which nothing has been
    /// written to the calendar.
    public var status: ProposalStatus {
        get { ProposalStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    /// Which model produced this — e.g. `deepseek-v4-pro`, or
    /// `foundation-models-on-device`.
    ///
    /// §4.3's unit economics depend on this and R5 cannot be audited without
    /// it: a Flash-shaped task misrouted to V4-Pro costs ~7× and is
    /// otherwise invisible in the bill. Populated from
    /// ``PAgentCore/Router/Decision/modelIdentifier``.
    public var modelUsed: String

    /// Why the router chose that model.
    ///
    /// Not in §5.4's schema; added because a `modelUsed` column alone tells
    /// you *what* was spent but not *why*, and R5's remedy is a routing
    /// review over real requests.
    public var routingRationale: String

    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.proposal)
    public var items: [ItineraryItem]

    /// EventKit identifiers written at commit time.
    ///
    /// §5.4's reason for keeping them: undoing a trip becomes one
    /// deterministic delete instead of the user hunting down eight events.
    /// Empty until `.committed`, and cleared by an undo so a double-tap
    /// cannot ask EventKit to delete the same events twice.
    public var committedEventIdentifiers: [String]

    public init(
        id: UUID,
        createdAt: Date,
        requestSummary: String,
        status: ProposalStatus = .draft,
        modelUsed: String,
        routingRationale: String = "",
        items: [ItineraryItem] = [],
        committedEventIdentifiers: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.requestSummary = requestSummary
        self.statusRaw = status.rawValue
        self.modelUsed = modelUsed
        self.routingRationale = routingRationale
        self.items = items
        self.committedEventIdentifiers = committedEventIdentifiers
    }
}

/// One stop in a proposal (§5.4).
@Model
public final class ItineraryItem {
    @Attribute(.unique) public var id: UUID

    public var title: String
    public var startsAt: Date
    public var endsAt: Date

    public var placeName: String?

    /// ## Deviation from §5.4
    ///
    /// The document types this `CLLocationCoordinate2D?`. That struct is not
    /// `Codable`, so SwiftData cannot persist it as a plain stored attribute —
    /// it needs a `Codable` wrapper or a transformable. This uses
    /// ``PAgentCore/Coordinate``, which is also what keeps the core package
    /// free of CoreLocation. Convert at the MapKit boundary.
    public var coordinate: Coordinate?

    /// Travel time from the previous item. `nil` means *not measured*, not
    /// zero — the feasibility check in
    /// ``PAgentCore/ItineraryProposalRecord/warnings()`` relies on that
    /// distinction, or it would flag every unrouted plan as unreachable.
    public var travelFromPrevious: TimeInterval?

    /// Why this item. §5.4 marks it 必填，不允许黑箱推荐.
    ///
    /// SwiftData cannot enforce non-empty, so the guarantee lives in
    /// ``PAgentCore/ItineraryItemRecord``'s initialiser and everything on the
    /// write path goes through it.
    public var rationale: String

    /// Swappable alternatives, so a user who dislikes one stop does not have
    /// to reject the whole plan.
    public var alternatives: [String]

    public var proposal: ItineraryProposal?

    public init(
        id: UUID,
        title: String,
        startsAt: Date,
        endsAt: Date,
        placeName: String? = nil,
        coordinate: Coordinate? = nil,
        travelFromPrevious: TimeInterval? = nil,
        rationale: String,
        alternatives: [String] = [],
        proposal: ItineraryProposal? = nil
    ) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.placeName = placeName
        self.coordinate = coordinate
        self.travelFromPrevious = travelFromPrevious
        self.rationale = rationale
        self.alternatives = alternatives
        self.proposal = proposal
    }
}

// MARK: - Queries

extension ItineraryProposal {
    /// Proposals the user still has to decide on.
    public static func awaitingDecision() -> FetchDescriptor<ItineraryProposal> {
        // Raw values, not enum cases: `#Predicate` cannot lower a comparison
        // against a `Codable` enum at all on Xcode 26.6 (see
        // `SignalEvent.sourceRaw`), and a captured constant does not help —
        // the unsupported type is the *value's*, not the expression's.
        let draft = ProposalStatus.draft.rawValue
        let presented = ProposalStatus.presented.rawValue
        return FetchDescriptor<ItineraryProposal>(
            predicate: #Predicate { $0.statusRaw == draft || $0.statusRaw == presented },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    /// Committed proposals, newest first — the undo surface.
    public static func committed() -> FetchDescriptor<ItineraryProposal> {
        let committed = ProposalStatus.committed.rawValue
        return FetchDescriptor<ItineraryProposal>(
            predicate: #Predicate { $0.statusRaw == committed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    /// Everything in a window, for the §4.3 cost-attribution view.
    ///
    /// Grouping by `modelUsed` over this range is how R5's "router misroute
    /// rate" gets measured against real traffic rather than estimated.
    public static func created(from start: Date, to end: Date) -> FetchDescriptor<ItineraryProposal> {
        FetchDescriptor<ItineraryProposal>(
            predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
    }

    public static func withID(_ id: UUID) -> FetchDescriptor<ItineraryProposal> {
        var descriptor = FetchDescriptor<ItineraryProposal>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }
}
