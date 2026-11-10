import Foundation
import SwiftData
import Testing

import PAgentCore

@testable import PAgentData

/// Runtime verification of the §5 schema.
///
/// ## Why these tests exist separately from `PAgentCore`'s
///
/// Everything in `PAgentCore` is tested against values. These tests are the
/// opposite: they assert that SwiftData can actually *translate* the schema,
/// which is a question compilation cannot answer. A `@Model` class that
/// compiles cleanly can still fail the moment `ModelContainer` is built:
///
/// - a `Codable` struct SwiftData declines to persist as an attribute
///   (`ItineraryItem.coordinate` — the §5.4 deviation),
/// - a `#Predicate` it cannot lower into a query,
/// - an `@Relationship(inverse:)` keypath that does not pair up,
/// - a `@ModelActor` whose generated initialiser differs from the call site.
///
/// Each of those is a Phase 1 blocker discovered at launch rather than at
/// build time, so each gets a test here.
///
/// A fresh in-memory container per test: `@Model` instances are owned by their
/// context, so sharing one across tests would leak state between them.
private func freshContext() throws -> (ModelContainer, ModelContext) {
    let container = try PAgentSchema.inMemoryContainer()
    return (container, ModelContext(container))
}

private let epoch = Date(timeIntervalSince1970: 1_793_000_000)
private let day: TimeInterval = 24 * 60 * 60

@Suite("Schema translatability")
struct SchemaTranslatabilityTests {
    @Test("the whole §5 schema builds into a container")
    func containerBuilds() throws {
        // The broadest check available: SwiftData validates every model,
        // attribute, index, and relationship when the container is created.
        // If any of the six models is untranslatable, this is where it shows.
        _ = try PAgentSchema.inMemoryContainer()
    }

    @Test("every §5 model is registered")
    func allModelsRegistered() {
        #expect(PAgentSchema.models.count == 6)
        let names = PAgentSchema.models.map { String(describing: $0) }.sorted()
        #expect(
            names == [
                "InterestTag",
                "ItineraryItem",
                "ItineraryProposal",
                "ProfileSnapshot",
                "SignalEvent",
                "TagEvidence",
            ]
        )
    }

    @Test("the schema is versioned from the start")
    func schemaIsVersioned() {
        // Versioned before it needs to be, so the first property change is a
        // deliberate migration rather than a lightweight-migration guess.
        #expect(PAgentSchema.V1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(PAgentSchema.Plan.schemas.count == 1)
    }

    @Test("sync is off at the container, as §9.3 requires")
    func cloudKitIsDisabled() throws {
        // Not a default — a compliance requirement. `SignalEvent` holds every
        // source in one table, so enabling sync would propagate HealthKit
        // signals to iCloud the moment Phase 3 lands, violating the rule in
        // §9.3. The container is the enforcement point.
        //
        // `ModelConfiguration.cloudKitDatabase` is not introspectable, so this
        // asserts the observable consequence: the configuration carries no
        // CloudKit container identifier.
        let configuration = PAgentSchema.configuration()
        #expect(configuration.cloudKitContainerIdentifier == nil)
    }
}

@Suite("Signal persistence")
struct SignalPersistenceTests {
    @Test("a captured signal round-trips through the store")
    func roundTrip() throws {
        let (_, context) = try freshContext()
        let captured = try SignalRecord.capture(
            .shared(url: URL(string: "https://example.com/a"), text: "一家独立书店", sharedAt: epoch)
        )

        context.insert(SignalEvent(captured))
        try context.save()

        let stored = try context.fetch(SignalEvent.pendingForDigest())
        #expect(stored.count == 1)

        // Back to a value type, and the payload still decodes.
        let recovered = stored[0].record
        #expect(recovered.id == captured.id)
        #expect(recovered.source == .shared)
        #expect(recovered.retentionUntil == epoch.addingTimeInterval(180 * day))

        guard case .shared(_, let text, _) = try stored[0].decodedPayload() else {
            Issue.record("expected a shared payload")
            return
        }
        #expect(text == "一家独立书店")
    }

    @Test("pendingForDigest() returns only undigested signals, oldest first")
    func pendingQuery() throws {
        let (_, context) = try freshContext()

        for offset in [2.0, 0.0, 1.0] {
            let signal = try SignalRecord.capture(
                .shared(url: nil, text: "signal \(offset)", sharedAt: epoch + offset * day)
            )
            context.insert(SignalEvent(signal))
        }
        let digested = try SignalRecord.capture(
            .shared(url: nil, text: "already done", sharedAt: epoch - day)
        )
        let digestedRow = SignalEvent(digested)
        digestedRow.digestedAt = epoch
        context.insert(digestedRow)
        try context.save()

        let pending = try context.fetch(SignalEvent.pendingForDigest())
        // §6.1 feeds this straight into DigestBatcher, which preserves order.
        #expect(pending.map(\.occurredAt) == [epoch, epoch + day, epoch + 2 * day])
    }

    @Test("pendingForDigest() honours a fetch limit")
    func pendingLimit() throws {
        let (_, context) = try freshContext()
        for offset in 0..<10 {
            let signal = try SignalRecord.capture(
                .shared(url: nil, text: "s\(offset)", sharedAt: epoch + Double(offset) * day)
            )
            context.insert(SignalEvent(signal))
        }
        try context.save()

        #expect(try context.fetch(SignalEvent.pendingForDigest(limit: 3)).count == 3)
    }

    @Test("fromSource() isolates one data source for the §9.3 purge")
    func sourceQuery() throws {
        let (_, context) = try freshContext()

        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "shared", sharedAt: epoch))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .photo(coordinate: nil, capturedAt: epoch, assetIdentifier: "a"))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .photo(coordinate: nil, capturedAt: epoch + day, assetIdentifier: "b"))))
        try context.save()

        #expect(try context.fetch(SignalEvent.fromSource(.photo)).count == 2)
        #expect(try context.fetch(SignalEvent.fromSource(.shared)).count == 1)
        #expect(try context.fetch(SignalEvent.fromSource(.health)).isEmpty)
    }

    @Test("expired(asOf:) finds signals past the retention horizon")
    func expiryQuery() throws {
        let (_, context) = try freshContext()
        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "old", sharedAt: epoch))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "recent", sharedAt: epoch + 170 * day))))
        try context.save()

        #expect(try context.fetch(SignalEvent.expired(asOf: epoch + 100 * day)).isEmpty)
        #expect(try context.fetch(SignalEvent.expired(asOf: epoch + 181 * day)).count == 1)
    }
}

@Suite("Interest graph persistence")
struct InterestGraphPersistenceTests {
    @Test("forProfileCard() cannot return a rejected tag")
    func rejectedTagsAreExcludedByTheQuery() throws {
        // §6.3 makes the card the only payload that leaves the device, so the
        // filter is in the predicate rather than applied afterwards — a caller
        // cannot forget it. Note the rejected tag here outscores the kept one.
        let (_, context) = try freshContext()

        context.insert(InterestTag(
            slug: "cuisine.sichuan", displayName: "川菜",
            score: 0.6, lastReinforcedAt: epoch))
        context.insert(InterestTag(
            slug: "activity.mall", displayName: "商场",
            score: 0.99, lastReinforcedAt: epoch, userVerdict: .rejected))
        try context.save()

        let card = try context.fetch(InterestTag.forProfileCard())
        #expect(card.map(\.slug) == ["cuisine.sichuan"])
    }

    @Test("forProfileCard() drops faded tags and orders by score")
    func cardOrdering() throws {
        let (_, context) = try freshContext()

        for (slug, score) in [("a", 0.3), ("b", 0.9), ("c", 0.6), ("faded", 0.0)] {
            context.insert(InterestTag(
                slug: slug, displayName: slug, score: score, lastReinforcedAt: epoch))
        }
        try context.save()

        #expect(try context.fetch(InterestTag.forProfileCard()).map(\.slug) == ["b", "c", "a"])
    }

    @Test("forProfileCard() breaks score ties by slug, for R8")
    func cardTiesAreDeterministic() throws {
        // Two tags on the same score must not swap places between runs: the
        // card sits inside the cached prefix, and a reordering reads
        // identically to a human while invalidating the cache for a full day.
        let (_, context) = try freshContext()

        for slug in ["zeta", "alpha", "mu"] {
            context.insert(InterestTag(
                slug: slug, displayName: slug, score: 0.5, lastReinforcedAt: epoch))
        }
        try context.save()

        #expect(
            try context.fetch(InterestTag.forProfileCard()).map(\.slug) == ["alpha", "mu", "zeta"]
        )
    }

    @Test("awaitingReview() returns only unreviewed tags")
    func reviewQueue() throws {
        let (_, context) = try freshContext()

        context.insert(InterestTag(slug: "new", displayName: "new",
                                   score: 0.5, lastReinforcedAt: epoch))
        context.insert(InterestTag(slug: "ok", displayName: "ok", score: 0.5,
                                   lastReinforcedAt: epoch, userVerdict: .confirmed))
        context.insert(InterestTag(slug: "no", displayName: "no", score: 0.5,
                                   lastReinforcedAt: epoch, userVerdict: .rejected))
        try context.save()

        #expect(try context.fetch(InterestTag.awaitingReview()).map(\.slug) == ["new"])
    }

    @Test("a duplicate slug is rejected")
    func slugIsUnique() throws {
        // The digest merges by slug. Two rows for one tag would split its
        // score and each half would then decay independently.
        let (_, context) = try freshContext()

        context.insert(InterestTag(slug: "cuisine.sichuan", displayName: "川菜",
                                   score: 0.5, lastReinforcedAt: epoch))
        try context.save()

        context.insert(InterestTag(slug: "cuisine.sichuan", displayName: "川菜 again",
                                   score: 0.9, lastReinforcedAt: epoch))
        try context.save()

        // `.unique` upserts rather than throwing, so the invariant to assert
        // is that there is still exactly one row for the slug.
        #expect(try context.fetch(InterestTag.withSlug("cuisine.sichuan")).count == 1)
    }

    @Test("evidence attaches through the inverse and cascades on delete")
    func evidenceRelationship() throws {
        let (_, context) = try freshContext()

        let tag = InterestTag(slug: "activity.hiking", displayName: "徒步",
                              score: 0.4, lastReinforcedAt: epoch)
        context.insert(tag)
        tag.addEvidence(
            TagReinforcement(confidence: 0.8, source: .shared, signalEventID: UUID()),
            rationale: "你分享了一条徒步路线",
            at: epoch
        )
        tag.addEvidence(
            TagReinforcement(confidence: 0.5, source: .photo, signalEventID: UUID()),
            rationale: "9/14 的照片拍在山上",
            at: epoch
        )
        try context.save()

        #expect(tag.evidence.count == 2)
        #expect(tag.evidence.allSatisfy { $0.tag?.slug == "activity.hiking" })
        // Already-weighted, so a later change to SignalSource.weight cannot
        // silently rewrite history: 0.8 × 1.0 (shared) and 0.5 × 0.4 (photo).
        #expect(tag.evidence.map(\.weight).sorted() == [0.2, 0.8])

        context.delete(tag)
        try context.save()
        // Orphaned evidence would accumulate on every veto.
        #expect(try context.fetch(FetchDescriptor<TagEvidence>()).isEmpty)
    }

    @Test("state round-trips through the §6.2 updater")
    func stateBridging() throws {
        let (_, context) = try freshContext()

        let tag = InterestTag(slug: "cuisine.yunnan", displayName: "云南菜",
                              score: 0.8, lastReinforcedAt: epoch)
        context.insert(tag)

        let updated = InterestGraphUpdater().update(
            tag.state,
            with: [TagReinforcement(confidence: 0.5, source: .shared, signalEventID: UUID())],
            at: epoch + 90 * day
        )
        tag.apply(updated)
        try context.save()

        // 0.8 × 0.5 (one half-life) + 0.5 = 0.9
        #expect(abs(tag.score - 0.9) < 1e-9)
        #expect(tag.lastReinforcedAt == epoch + 90 * day)
    }
}

@Suite("Snapshot persistence")
struct SnapshotPersistenceTests {
    @Test("latest() returns the newest snapshot only")
    func latestSnapshot() throws {
        // §5.3's whole point: the planning path does one read instead of an
        // aggregate query (R10).
        let (_, context) = try freshContext()

        for offset in [0.0, 2.0, 1.0] {
            context.insert(ProfileSnapshot(
                generatedAt: epoch + offset * day,
                cardMarkdown: "## 画像\nday \(offset)",
                cardTokenCount: 100,
                topTagSlugs: ["cuisine.sichuan"],
                routineSummary: "工作日 7:10 起"
            ))
        }
        try context.save()

        let latest = try context.fetch(ProfileSnapshot.latest())
        #expect(latest.count == 1)
        #expect(latest[0].generatedAt == epoch + 2 * day)
    }

    @Test("the stored card is reused verbatim, not re-rendered")
    func cardIsVerbatim() throws {
        // Re-rendering from tags could produce different bytes and break the
        // cached prefix mid-day (R8). The stored markdown is what was sent.
        let (_, context) = try freshContext()
        let markdown = "## 画像\n口味：川菜/云南菜偏好强；不吃生食。"

        context.insert(ProfileSnapshot(
            generatedAt: epoch,
            cardMarkdown: markdown,
            cardTokenCount: 123,
            topTagSlugs: ["cuisine.sichuan", "cuisine.yunnan"],
            routineSummary: "工作日 7:10 起"
        ))
        try context.save()

        let card = try context.fetch(ProfileSnapshot.latest())[0].profileCard
        #expect(card.markdown == markdown)
        #expect(card.tokenCount == 123)
        #expect(card.includedSlugs == ["cuisine.sichuan", "cuisine.yunnan"])
    }

    @Test("supersededBefore() finds snapshots to prune")
    func pruning() throws {
        let (_, context) = try freshContext()
        for offset in 0..<5 {
            context.insert(ProfileSnapshot(
                generatedAt: epoch + Double(offset) * day,
                cardMarkdown: "## 画像", cardTokenCount: 10,
                topTagSlugs: [], routineSummary: ""
            ))
        }
        try context.save()

        #expect(try context.fetch(ProfileSnapshot.supersededBefore(epoch + 3 * day)).count == 3)
    }
}

@Suite("Proposal persistence")
struct ProposalPersistenceTests {
    private func sampleProposal() throws -> ItineraryProposalRecord {
        ItineraryProposalRecord(
            createdAt: epoch,
            requestSummary: "周六下午安排点事",
            status: .presented,
            modelUsed: "deepseek-flash",
            items: [
                try ItineraryItemRecord(
                    title: "独立书店",
                    startsAt: epoch, endsAt: epoch + 2 * 3600,
                    placeName: "城西",
                    coordinate: Coordinate(latitude: 30.2594, longitude: 120.1632),
                    rationale: "你常去独立书店"
                ),
                try ItineraryItemRecord(
                    title: "咖啡",
                    startsAt: epoch + 3 * 3600, endsAt: epoch + 4 * 3600,
                    travelFromPrevious: 20 * 60,
                    rationale: "书店步行 20 分钟可到"
                ),
            ]
        )
    }

    @Test("a Codable Coordinate persists as a stored attribute")
    func coordinatePersists() throws {
        // The §5.4 deviation under test. The document types this
        // `CLLocationCoordinate2D?`, which is not `Codable` and so cannot be
        // a plain stored attribute; `Coordinate` is the replacement. Whether
        // SwiftData will persist a `Codable` struct is a runtime question —
        // this is the answer.
        let (_, context) = try freshContext()
        let coordinate = Coordinate(latitude: 30.2594, longitude: 120.1632)

        context.insert(ItineraryProposal(try sampleProposal()))
        try context.save()

        let stored = try context.fetch(ItineraryProposal.awaitingDecision())
        #expect(stored.count == 1)
        let bookstore = stored[0].items.first { $0.title == "独立书店" }
        #expect(bookstore?.coordinate == coordinate)
        // And `nil` stays `nil` rather than becoming (0, 0).
        #expect(stored[0].items.first { $0.title == "咖啡" }?.coordinate == nil)
    }

    @Test("the proposal round-trips to a validated value type")
    func proposalRoundTrip() throws {
        let (_, context) = try freshContext()
        let original = try sampleProposal()

        context.insert(ItineraryProposal(original, routingRationale: "single-day planning"))
        try context.save()

        let recovered = try context.fetch(ItineraryProposal.awaitingDecision())[0].record()
        #expect(recovered.id == original.id)
        #expect(recovered.status == .presented)
        #expect(recovered.modelUsed == "deepseek-flash")
        #expect(recovered.items.map(\.title) == ["独立书店", "咖啡"])
        // Feasibility survives the round trip — a 60-minute gap covers the
        // 20-minute walk.
        #expect(recovered.isExecutable)
    }

    @Test("items cascade on proposal delete")
    func itemsCascade() throws {
        let (_, context) = try freshContext()
        let proposal = ItineraryProposal(try sampleProposal())
        context.insert(proposal)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ItineraryItem>()).count == 2)
        context.delete(proposal)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ItineraryItem>()).isEmpty)
    }

    @Test("the commit transition is mirrored, never originated, in storage")
    func commitGoesThroughTheValueType() throws {
        // The lifecycle rules live on `ItineraryProposalRecord`, where they
        // are unit-tested. Storage only reflects the outcome, so there is no
        // second, unvalidated path into `.committed` — which is what makes
        // §7.2's "writes require confirmation" structural rather than a
        // convention.
        let (_, context) = try freshContext()
        let row = ItineraryProposal(try sampleProposal())
        context.insert(row)
        try context.save()

        var record = try row.record()
        try record.confirm(eventIdentifiers: ["evt-1", "evt-2"], at: epoch)
        row.apply(record)
        try context.save()

        let committed = try context.fetch(ItineraryProposal.committed())
        #expect(committed.count == 1)
        #expect(committed[0].committedEventIdentifiers == ["evt-1", "evt-2"])
        // No longer awaiting a decision.
        #expect(try context.fetch(ItineraryProposal.awaitingDecision()).isEmpty)
    }

    @Test("undo clears the identifiers it hands back")
    func undoClearsIdentifiers() throws {
        let (_, context) = try freshContext()
        let row = ItineraryProposal(try sampleProposal())
        context.insert(row)
        try context.save()

        var record = try row.record()
        try record.confirm(eventIdentifiers: ["evt-1"], at: epoch)
        row.apply(record)
        try context.save()

        let toDelete = try record.undo()
        row.apply(record)
        try context.save()

        #expect(toDelete == ["evt-1"])
        // A double-tap must not ask EventKit to delete the same event twice.
        #expect(row.committedEventIdentifiers.isEmpty)
        #expect(try context.fetch(ItineraryProposal.committed()).isEmpty)
    }

    @Test("created(from:to:) windows proposals for cost attribution")
    func costAttributionWindow() throws {
        // §4.3's unit economics and R5's router review both group by
        // `modelUsed` over a date range.
        let (_, context) = try freshContext()

        for (offset, model) in [(0.0, "deepseek-flash"), (5.0, "deepseek-v4-pro"), (40.0, "deepseek-flash")] {
            context.insert(ItineraryProposal(
                id: UUID(), createdAt: epoch + offset * day,
                requestSummary: "r", modelUsed: model
            ))
        }
        try context.save()

        let month = try context.fetch(
            ItineraryProposal.created(from: epoch, to: epoch + 30 * day)
        )
        #expect(month.count == 2)
        #expect(Set(month.map(\.modelUsed)) == ["deepseek-flash", "deepseek-v4-pro"])
    }

    @Test("the routing rationale is retained alongside the model")
    func routingRationaleIsStored() throws {
        // `modelUsed` records what was spent; the rationale records why, which
        // is what R5's routing review needs.
        let (_, context) = try freshContext()
        let decision = Router().route(for: .complexPlanning, availability: .available)

        context.insert(ItineraryProposal(
            id: UUID(), createdAt: epoch, requestSummary: "下周末两天",
            modelUsed: decision.modelIdentifier,
            routingRationale: decision.rationale
        ))
        try context.save()

        let stored = try context.fetch(FetchDescriptor<ItineraryProposal>())[0]
        #expect(stored.modelUsed == "deepseek-v4-pro")
        #expect(stored.routingRationale.contains("multi-day"))
    }
}

@Suite("RetentionSweeper")
struct RetentionSweeperTests {
    @Test("deletes signals past the horizon and leaves the rest")
    func sweepDeletesExpired() async throws {
        let container = try PAgentSchema.inMemoryContainer()
        let context = ModelContext(container)

        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "old", sharedAt: epoch))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "recent", sharedAt: epoch + 170 * day))))
        try context.save()

        let sweeper = RetentionSweeper(modelContainer: container)
        let deleted = try await sweeper.sweep(asOf: epoch + 181 * day)
        #expect(deleted == 1)

        let remaining = try ModelContext(container).fetch(FetchDescriptor<SignalEvent>())
        #expect(remaining.count == 1)
        #expect(remaining[0].occurredAt == epoch + 170 * day)
    }

    @Test("deletes an undigested signal anyway")
    func sweepIgnoresDigestState() async throws {
        // Holding one back "just until we get to it" would turn the 180-day
        // promise into an indefinite one whenever the digest fell behind —
        // exactly what §9.3 undertakes to App Review that the app does not do.
        let container = try PAgentSchema.inMemoryContainer()
        let context = ModelContext(container)

        let neverProcessed = SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "never processed", sharedAt: epoch)))
        #expect(neverProcessed.digestedAt == nil)
        context.insert(neverProcessed)
        try context.save()

        let sweeper = RetentionSweeper(modelContainer: container)
        #expect(try await sweeper.sweep(asOf: epoch + 181 * day) == 1)
    }

    @Test("is a no-op when nothing has expired")
    func sweepIsIdempotent() async throws {
        let container = try PAgentSchema.inMemoryContainer()
        let context = ModelContext(container)
        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "fresh", sharedAt: epoch))))
        try context.save()

        let sweeper = RetentionSweeper(modelContainer: container)
        #expect(try await sweeper.sweep(asOf: epoch + day) == 0)
        #expect(try await sweeper.sweep(asOf: epoch + day) == 0)
    }

    @Test("purging a source deletes its history but keeps derived tags")
    func purgeSource() async throws {
        // §9.3 promises each source can be switched off independently. A
        // toggle that stops future capture but leaves the history is
        // cosmetic — so revoking purges what the source contributed.
        //
        // Derived tags stay: they are the user's profile, their evidence rows
        // carry their own `rationale` for the explanation UI, and §5.2 already
        // gives per-tag veto to anyone who wants them gone.
        let container = try PAgentSchema.inMemoryContainer()
        let context = ModelContext(container)

        context.insert(SignalEvent(try SignalRecord.capture(
            .photo(coordinate: nil, capturedAt: epoch, assetIdentifier: "a"))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .photo(coordinate: nil, capturedAt: epoch + day, assetIdentifier: "b"))))
        context.insert(SignalEvent(try SignalRecord.capture(
            .shared(url: nil, text: "kept", sharedAt: epoch))))

        let tag = InterestTag(slug: "activity.hiking", displayName: "徒步",
                              score: 0.6, lastReinforcedAt: epoch)
        context.insert(tag)
        tag.addEvidence(
            TagReinforcement(confidence: 0.5, source: .photo, signalEventID: UUID()),
            rationale: "照片拍在山上", at: epoch)
        try context.save()

        let sweeper = RetentionSweeper(modelContainer: container)
        #expect(try await sweeper.purge(source: .photo) == 2)

        let verify = ModelContext(container)
        let signals = try verify.fetch(FetchDescriptor<SignalEvent>())
        #expect(signals.map(\.source) == [.shared])
        #expect(try verify.fetch(FetchDescriptor<InterestTag>()).count == 1)
        #expect(try verify.fetch(FetchDescriptor<TagEvidence>()).count == 1)
    }
}
