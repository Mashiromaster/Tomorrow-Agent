import Foundation
import Testing

@testable import PAgentCore

private let epoch = Date(timeIntervalSince1970: 1_793_000_000)
private let hour: TimeInterval = 3600

private func item(
    _ title: String,
    start: TimeInterval,
    end: TimeInterval,
    travelFromPrevious: TimeInterval? = nil,
    rationale: String = "符合你的口味偏好"
) throws -> ItineraryItemRecord {
    try ItineraryItemRecord(
        title: title,
        startsAt: epoch.addingTimeInterval(start),
        endsAt: epoch.addingTimeInterval(end),
        travelFromPrevious: travelFromPrevious,
        rationale: rationale
    )
}

private func proposal(
    _ items: [ItineraryItemRecord],
    status: ProposalStatus = .draft,
    modelUsed: String = "claude-sonnet-5"
) -> ItineraryProposalRecord {
    ItineraryProposalRecord(
        createdAt: epoch,
        requestSummary: "周六下午安排点事",
        status: status,
        modelUsed: modelUsed,
        items: items
    )
}

@Suite("ItineraryItemRecord")
struct ItineraryItemRecordTests {
    @Test("refuses an item with no rationale")
    func rationaleIsRequired() {
        // §5.4 marks `rationale` 必填，不允许黑箱推荐. Enforced in the
        // initialiser so it is a property of the type rather than something
        // the UI layer has to remember to check.
        #expect(throws: ProposalError.missingRationale(itemTitle: "神秘推荐")) {
            try item("神秘推荐", start: 0, end: hour, rationale: "")
        }
    }

    @Test("treats a whitespace-only rationale as absent")
    func whitespaceRationaleIsRejected() {
        // Otherwise a model that emits `"rationale": " "` satisfies the
        // check and the user still gets a blank explanation.
        #expect(throws: ProposalError.missingRationale(itemTitle: "空白")) {
            try item("空白", start: 0, end: hour, rationale: "   \n  ")
        }
    }

    @Test("trims the stored rationale")
    func rationaleIsTrimmed() throws {
        let trimmed = try item("书店", start: 0, end: hour, rationale: "  你常去独立书店  ")
        #expect(trimmed.rationale == "你常去独立书店")
    }

    @Test("refuses an item that ends before it starts")
    func rejectsInvertedInterval() {
        #expect(throws: ProposalError.endsBeforeItStarts(itemTitle: "倒置")) {
            try item("倒置", start: 2 * hour, end: hour)
        }
    }

    @Test("refuses a zero-length item")
    func rejectsZeroDuration() {
        // A zero-length calendar event is not something the user asked for,
        // and it would survive all the way to EventKit.
        #expect(throws: ProposalError.endsBeforeItStarts(itemTitle: "瞬间")) {
            try item("瞬间", start: hour, end: hour)
        }
    }

    @Test("reports its duration")
    func duration() throws {
        #expect(try item("徒步", start: 0, end: 2 * hour).duration == 2 * hour)
    }
}

@Suite("Proposal lifecycle")
struct ProposalLifecycleTests {
    private func singleItem() throws -> [ItineraryItemRecord] {
        [try item("独立书店", start: 0, end: 2 * hour)]
    }

    @Test("starts as a draft the user has not seen")
    func startsAsDraft() throws {
        let draft = proposal(try singleItem())
        #expect(draft.status == .draft)
        #expect(draft.committedEventIdentifiers.isEmpty)
    }

    @Test("walks draft → presented → committed")
    func happyPath() throws {
        var record = proposal(try singleItem())

        try record.present()
        #expect(record.status == .presented)

        try record.confirm(eventIdentifiers: ["evt-1", "evt-2"], at: epoch)
        #expect(record.status == .committed)
        #expect(record.committedEventIdentifiers == ["evt-1", "evt-2"])
    }

    @Test("refuses to commit a draft the user has never seen")
    func cannotCommitUnpresentedDraft() throws {
        // The lifecycle half of 写操作必须用户确认: the only transition into
        // `.committed` starts from `.presented`, so a proposal that was never
        // rendered cannot reach EventKit even if a caller tries.
        var record = proposal(try singleItem())

        #expect(throws: ProposalError.illegalTransition(from: .draft, to: .committed)) {
            try record.confirm(eventIdentifiers: ["evt-1"], at: epoch)
        }
        #expect(record.status == .draft)
        #expect(record.committedEventIdentifiers.isEmpty)
    }

    @Test("refuses a commit with no event identifiers")
    func commitNeedsIdentifiers() throws {
        // §5.4 stores the identifiers so undo is one deterministic delete.
        // A commit without them would be unundoable, which is worse than a
        // failed commit.
        var record = proposal(try singleItem())
        try record.present()

        #expect(throws: ProposalError.commitWithoutEventIdentifiers) {
            try record.confirm(eventIdentifiers: [], at: epoch)
        }
        #expect(record.status == .presented)
    }

    @Test("cannot be presented twice")
    func presentIsIdempotentlyRejected() throws {
        var record = proposal(try singleItem())
        try record.present()

        #expect(throws: ProposalError.illegalTransition(from: .presented, to: .presented)) {
            try record.present()
        }
    }

    @Test("can be discarded from draft or presented")
    func discardable() throws {
        var fromDraft = proposal(try singleItem())
        try fromDraft.discard()
        #expect(fromDraft.status == .discarded)

        var fromPresented = proposal(try singleItem())
        try fromPresented.present()
        try fromPresented.discard()
        #expect(fromPresented.status == .discarded)
    }

    @Test("cannot be discarded once committed — that is an undo")
    func committedMustBeUndoneNotDiscarded() throws {
        // Discarding a committed proposal would mark it dead while leaving
        // eight events in the user's calendar with nothing pointing at them.
        var record = proposal(try singleItem())
        try record.present()
        try record.confirm(eventIdentifiers: ["evt-1"], at: epoch)

        #expect(throws: ProposalError.illegalTransition(from: .committed, to: .discarded)) {
            try record.discard()
        }
        #expect(record.status == .committed)
    }

    @Test("undo hands back every identifier to delete")
    func undoReturnsIdentifiers() throws {
        // §5.4's one-tap undo: the caller deletes exactly these and the user
        // does not hunt down eight events by hand.
        var record = proposal(try singleItem())
        try record.present()
        try record.confirm(eventIdentifiers: ["evt-1", "evt-2", "evt-3"], at: epoch)

        let toDelete = try record.undo()
        #expect(toDelete == ["evt-1", "evt-2", "evt-3"])
        #expect(record.status == .discarded)
    }

    @Test("a second undo has nothing to return")
    func undoIsNotRepeatable() throws {
        // A double-tap must not ask EventKit to delete already-deleted
        // events: `undo` clears the identifiers as it hands them over.
        var record = proposal(try singleItem())
        try record.present()
        try record.confirm(eventIdentifiers: ["evt-1"], at: epoch)
        _ = try record.undo()

        #expect(throws: ProposalError.nothingToUndo(status: .discarded)) {
            _ = try record.undo()
        }
        #expect(record.committedEventIdentifiers.isEmpty)
    }

    @Test("an uncommitted proposal has nothing to undo")
    func cannotUndoDraft() throws {
        var record = proposal(try singleItem())
        #expect(throws: ProposalError.nothingToUndo(status: .draft)) {
            _ = try record.undo()
        }
    }

    @Test("records which model produced it, for cost attribution")
    func recordsModel() throws {
        // §4.3's unit economics and R5's router review both need this: a
        // Sonnet task misrouted to Opus costs 1.65× and is otherwise
        // invisible in the bill.
        let router = Router()
        let decision = router.route(for: .complexPlanning, availability: .available)
        let record = proposal(try singleItem(), modelUsed: decision.modelIdentifier)

        #expect(record.modelUsed == "deepseek-v4-pro")
    }
}

@Suite("Itinerary feasibility")
struct ItineraryFeasibilityTests {
    @Test("orders items by start time on construction")
    func itemsAreSorted() throws {
        let record = proposal([
            try item("晚餐", start: 6 * hour, end: 8 * hour),
            try item("书店", start: 0, end: 2 * hour),
            try item("咖啡", start: 3 * hour, end: 4 * hour),
        ])
        #expect(record.items.map(\.title) == ["书店", "咖啡", "晚餐"])
    }

    @Test("a well-spaced plan has no warnings")
    func cleanPlan() throws {
        let record = proposal([
            try item("书店", start: 0, end: 2 * hour),
            try item("咖啡", start: 3 * hour, end: 4 * hour, travelFromPrevious: 20 * 60),
        ])
        #expect(record.warnings().isEmpty)
        #expect(record.isExecutable)
    }

    @Test("flags two stops that overlap in time")
    func detectsOverlap() throws {
        // Reads perfectly well in prose and cannot be executed. Worth
        // catching before the user is asked to confirm it.
        let record = proposal([
            try item("书店", start: 0, end: 3 * hour),
            try item("咖啡", start: 2 * hour, end: 4 * hour),
        ])

        #expect(record.warnings() == [.overlap(earlier: "书店", later: "咖啡")])
        #expect(record.isExecutable == false)
    }

    @Test("flags a gap too short for the travel time between stops")
    func detectsUnreachable() throws {
        // §7.4 has the model call `get_travel_time` in parallel; this is
        // where we check it used the answer. A 10-minute gap with a
        // 40-minute transit leg is a plan the user discovers is broken while
        // standing on a platform.
        let record = proposal([
            try item("城西书店", start: 0, end: 2 * hour),
            try item("城东展览", start: 2 * hour + 600, end: 4 * hour, travelFromPrevious: 40 * 60),
        ])

        #expect(
            record.warnings() == [
                .unreachable(from: "城西书店", to: "城东展览", shortfallSeconds: 30 * 60)
            ]
        )
    }

    @Test("accepts a gap exactly equal to the travel time")
    func exactConnectionIsAccepted() throws {
        // Tight but achievable. Warning on it would train the user to ignore
        // warnings.
        let record = proposal([
            try item("A", start: 0, end: hour),
            try item("B", start: 2 * hour, end: 3 * hour, travelFromPrevious: hour),
        ])
        #expect(record.warnings().isEmpty)
    }

    @Test("does not invent a travel warning when no route was looked up")
    func missingTravelTimeIsNotAWarning() throws {
        // `nil` means \"not measured\", not \"zero\" — reporting it as
        // unreachable would flag every plan the model did not route.
        let record = proposal([
            try item("A", start: 0, end: hour),
            try item("B", start: hour, end: 2 * hour, travelFromPrevious: nil),
        ])
        #expect(record.warnings().isEmpty)
    }

    @Test("reports an overlap once, without also reporting it as unreachable")
    func overlapSupersedesTravel() throws {
        // Two warnings for one defect would read as two separate problems.
        let record = proposal([
            try item("A", start: 0, end: 3 * hour),
            try item("B", start: hour, end: 4 * hour, travelFromPrevious: 30 * 60),
        ])
        #expect(record.warnings().count == 1)
    }

    @Test("checks every consecutive pair in a multi-day plan")
    func checksAllPairs() throws {
        let record = proposal([
            try item("A", start: 0, end: hour),
            try item("B", start: 2 * hour, end: 3 * hour, travelFromPrevious: 30 * 60),
            try item("C", start: 3 * hour + 60, end: 4 * hour, travelFromPrevious: 45 * 60),
            try item("D", start: 10 * hour, end: 11 * hour, travelFromPrevious: 20 * 60),
        ])

        // Only the B→C connection is broken.
        #expect(record.warnings().count == 1)
        guard case .unreachable(let from, let to, _) = record.warnings().first else {
            Issue.record("expected an unreachable warning, got \(record.warnings())")
            return
        }
        #expect(from == "B")
        #expect(to == "C")
    }

    @Test("reports the overall span, and nothing for an empty plan")
    func span() throws {
        let record = proposal([
            try item("A", start: 0, end: hour),
            try item("B", start: 5 * hour, end: 6 * hour),
        ])
        #expect(record.span == 6 * hour)
        #expect(proposal([]).span == nil)
        #expect(proposal([]).isExecutable)
    }
}
