import Foundation
import SwiftData

import PAgentCore

/// The SwiftData schema and its migration plan (IMPLEMENTATION.md §10 Phase 0).
public enum PAgentSchema {
    /// Every model in §5, in one place.
    ///
    /// A single list rather than per-feature containers: `TagEvidence` points
    /// at `SignalEvent.id`, and the §4.3 cost view reads proposals alongside
    /// snapshots. Splitting the store would turn those into cross-container
    /// reads for no benefit.
    public static let models: [any PersistentModel.Type] = [
        SignalEvent.self,
        InterestTag.self,
        TagEvidence.self,
        ProfileSnapshot.self,
        ItineraryProposal.self,
        ItineraryItem.self,
    ]

    /// Schema version 1 — the Phase 0 baseline.
    ///
    /// `VersionedSchema` from the start, even with one version, because the
    /// alternative is a lightweight-migration guess the first time a property
    /// changes. §5.1 stores signal payloads as opaque `Data` precisely so
    /// most future changes do not need a migration at all; this covers the
    /// ones that do.
    public enum V1: VersionedSchema {
        public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

        public static var models: [any PersistentModel.Type] { PAgentSchema.models }
    }

    /// Stages are appended here as the schema evolves.
    ///
    /// Phase 1 ships only V1. Each later stage is `.lightweight` when the
    /// change is additive, and `.custom` when data has to be rewritten —
    /// e.g. a `SignalPayload` case gaining a required field, where the
    /// `willMigrate` hook re-decodes and re-encodes the affected rows rather
    /// than letting them fail to decode at read time.
    public static var migrationPlan: any SchemaMigrationPlan.Type { Plan.self }

    public enum Plan: SchemaMigrationPlan {
        public static var schemas: [any VersionedSchema.Type] { [V1.self] }
        public static var stages: [MigrationStage] { [] }
    }

    // MARK: - Containers

    /// The App Group that the app and the Share Extension both belong to.
    ///
    /// They are separate processes with separate sandboxes, so a store in
    /// either one's private container is invisible to the other. §4.1 makes
    /// the Share Extension the only general way to get content in from other
    /// apps, which means its captured signals have to land in the *same*
    /// store the nightly digest reads — so the store lives in the shared
    /// container.
    ///
    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both targets.
    public static let appGroupIdentifier = "group.com.example.PAgent"

    /// The store file inside the shared container.
    ///
    /// Returns `nil` when the App Group is not provisioned — a missing
    /// entitlement, or a build signed without it. The caller decides what to
    /// do, and the one thing it must not do is fall back to a private-container
    /// store: the app and the extension would then each accumulate signals the
    /// other could not see, and the bug would present as "shared items
    /// sometimes vanish" rather than as a configuration error.
    public static func sharedStoreURL(
        appGroup: String = PAgentSchema.appGroupIdentifier
    ) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("PAgent.store")
    }

    /// The on-device store.
    ///
    /// ## `cloudKitDatabase: .none` is a compliance requirement, not a default
    ///
    /// §9.3 records App Review's HealthKit rules: health data **must not** be
    /// written to iCloud. Since `SignalEvent` holds every source in one table,
    /// enabling CloudKit on this container would sync health signals the
    /// moment Phase 3 lands — and the violation would be invisible until
    /// review. Turning sync off at the container is the enforcement point.
    ///
    /// It also happens to be what makes "原始数据不出设备" (§1) literally
    /// true rather than aspirational: with sync off, the only path off the
    /// device is the ≤500-token profile card in §6.3.
    ///
    /// If selective sync is ever wanted, it needs a *separate* container for
    /// the syncable subset — not a flag flipped here.
    public static func configuration(
        url: URL? = nil
    ) -> ModelConfiguration {
        if let url {
            return ModelConfiguration(
                schema: Schema(models),
                url: url,
                cloudKitDatabase: .none
            )
        }
        return ModelConfiguration(
            schema: Schema(models),
            cloudKitDatabase: .none
        )
    }

    public static func container(url: URL? = nil) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(models),
            migrationPlan: migrationPlan,
            configurations: configuration(url: url)
        )
    }

    /// An in-memory container, for tests and SwiftUI previews.
    public static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(models),
            migrationPlan: migrationPlan,
            configurations: ModelConfiguration(
                schema: Schema(models),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
    }
}

// MARK: - Retention

/// Deletes signals past their §5.1 horizon.
///
/// Run from the nightly `BGProcessingTask` alongside the digest (§6.1). It is
/// a separate pass on purpose: if the digest fails — a guardrail false
/// positive storm, say (R3) — retention must still be enforced. Coupling them
/// would let a broken digest quietly extend the 180-day promise indefinitely,
/// which is the behaviour §9.3 undertakes to App Review that the app does not
/// have.
@ModelActor
public actor RetentionSweeper {
    /// Returns how many signals were deleted.
    public func sweep(asOf now: Date = .now) throws -> Int {
        let expired = try modelContext.fetch(SignalEvent.expired(asOf: now))
        guard !expired.isEmpty else { return 0 }

        for signal in expired {
            modelContext.delete(signal)
        }
        try modelContext.save()
        return expired.count
    }

    /// Deletes every signal from one source.
    ///
    /// §9.3 promises each data source can be switched off independently, with
    /// the feature degrading rather than breaking. A toggle that stops future
    /// capture but leaves the history in place is cosmetic, so revoking a
    /// source purges what it already contributed.
    ///
    /// Derived tags are intentionally left alone: they are the user's
    /// profile, the evidence rows carry their own `rationale` for the
    /// explanation UI, and §5.2 already gives the user per-tag veto if they
    /// want any of it gone.
    public func purge(source: SignalSource) throws -> Int {
        let rows = try modelContext.fetch(SignalEvent.fromSource(source))
        guard !rows.isEmpty else { return 0 }

        for signal in rows {
            modelContext.delete(signal)
        }
        try modelContext.save()
        return rows.count
    }
}
