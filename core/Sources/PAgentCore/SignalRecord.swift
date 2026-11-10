import Foundation

/// A latitude/longitude pair.
///
/// Deliberately **not** `CLLocationCoordinate2D`, for two reasons. The first
/// keeps this package free of SDK dependencies. The second is a correction to
/// IMPLEMENTATION.md §5.4, which types `ItineraryItem.coordinate` as
/// `CLLocationCoordinate2D?`: that struct is not `Codable`, so SwiftData
/// cannot persist it as a plain stored attribute — it needs a `Codable`
/// wrapper or a transformable. This is that wrapper.
public struct Coordinate: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Retention

/// When a raw signal is deleted.
///
/// §5.1 makes `retentionUntil` the enforcement point for data minimisation,
/// and §9.3 cites automatic cleanup when answering App Review clause 5.1.1.
/// Keeping the policy as a value — rather than an inline `+ 180 * 86400`
/// somewhere in the capture layer — is what lets the horizon be shown in
/// settings and asserted in a test.
public struct RetentionPolicy: Sendable, Hashable {
    /// §5.1's default: six months of raw signals.
    public static let standard = RetentionPolicy(duration: 180 * 24 * 60 * 60)

    public let duration: TimeInterval

    public init(duration: TimeInterval) {
        precondition(duration > 0, "retention duration must be positive")
        self.duration = duration
    }

    /// Measured from `occurredAt`, not from capture: a photo imported today
    /// but taken last year is already most of the way through its window.
    public func expiry(forSignalAt occurredAt: Date) -> Date {
        occurredAt.addingTimeInterval(duration)
    }
}

// MARK: - Signal payloads

/// The source-specific body of a signal.
///
/// §5.1 keeps payloads raw and un-normalised on the grounds that the
/// normalisation rules *will* change, and replaying original signals is the
/// only way to correct a bad extraction. So this enum is a tagged container,
/// not a common schema: adding a case cannot alter how an existing one
/// decodes, which is what makes a replay years later still mean the same
/// thing.
public enum SignalPayload: Sendable, Hashable, Codable {
    /// A calendar event. The title is kept locally; §7.2 redacts it to a
    /// category before anything is sent to the model.
    case calendar(title: String, startsAt: Date, endsAt: Date, isAllDay: Bool)

    /// A detected visit. No dwell-time threshold is applied here — that is a
    /// normalisation rule, and §5.1 keeps those out of the stored payload.
    case visit(coordinate: Coordinate, arrivedAt: Date, departedAt: Date?)

    /// Photo **metadata only** — capture time and place, never pixels (§4.1).
    case photo(coordinate: Coordinate?, capturedAt: Date, assetIdentifier: String)

    /// Sleep and activity, Phase 3. Derived tags never carry the raw figures
    /// (§9.3), and these rows are purged like any other signal.
    case health(kind: String, value: Double, unit: String, measuredAt: Date)

    /// Content the user shared in from another app.
    ///
    /// **Untrusted input** (§9.4). Stored verbatim so it can be re-parsed, and
    /// wrapped in boundary markers before it reaches a model.
    case shared(url: URL?, text: String, sharedAt: Date)

    /// Hand-picked during onboarding (R7's cold start).
    case manual(slug: String, note: String?)

    /// The source this payload belongs to. Pairing a payload with the wrong
    /// `SignalSource` would silently mis-weight it in §6.2's scoring, so the
    /// mapping lives here rather than at each call site.
    public var source: SignalSource {
        switch self {
        case .calendar: .calendar
        case .visit: .visit
        case .photo: .photo
        case .health: .health
        case .shared: .shared
        case .manual: .manual
        }
    }

    /// When the thing described actually happened.
    public var occurredAt: Date {
        switch self {
        case .calendar(_, let startsAt, _, _): startsAt
        case .visit(_, let arrivedAt, _): arrivedAt
        case .photo(_, let capturedAt, _): capturedAt
        case .health(_, _, _, let measuredAt): measuredAt
        case .shared(_, _, let sharedAt): sharedAt
        // A hand-picked interest is not an event; the caller stamps it.
        case .manual: Date(timeIntervalSince1970: 0)
        }
    }
}

// MARK: - Signal record

/// One captured signal — the append-only raw fact from §5.1.
///
/// `digestedAt == nil` is the work queue: everything with a nil stamp is
/// waiting for the nightly pass.
public struct SignalRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let source: SignalSource
    public let occurredAt: Date
    /// JSON-encoded `SignalPayload`. Stored as bytes so the on-disk shape does
    /// not move when an unrelated case is added to the enum.
    public let payload: Data
    /// `nil` while pending. Set once the digest has consumed it.
    public var digestedAt: Date?
    public let retentionUntil: Date

    public init(
        id: UUID = UUID(),
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

    /// Builds a record from a typed payload, deriving `source`, `occurredAt`,
    /// and `retentionUntil` so the three cannot disagree with the body.
    public static func capture(
        _ payload: SignalPayload,
        id: UUID = UUID(),
        occurredAt: Date? = nil,
        retention: RetentionPolicy = .standard
    ) throws -> SignalRecord {
        let when = occurredAt ?? payload.occurredAt
        return SignalRecord(
            id: id,
            source: payload.source,
            occurredAt: when,
            payload: try DeterministicJSON.encoder.encode(payload),
            retentionUntil: retention.expiry(forSignalAt: when)
        )
    }

    public func decodedPayload() throws -> SignalPayload {
        try JSONDecoder().decode(SignalPayload.self, from: payload)
    }

    public var isPendingDigest: Bool { digestedAt == nil }

    public func hasExpired(at now: Date) -> Bool { retentionUntil <= now }
}

extension Array where Element == SignalRecord {
    /// The digest work queue: pending signals in `occurredAt` order.
    ///
    /// Ordered because §6.1 feeds these straight into ``DigestBatcher``, and a
    /// day's signals read as a narrative — shuffling them costs the model the
    /// sequence.
    public func pendingForDigest() -> [SignalRecord] {
        filter(\.isPendingDigest).sorted { $0.occurredAt < $1.occurredAt }
    }

    /// Signals past their retention horizon.
    ///
    /// Expiry is unconditional — a signal that was never digested is deleted
    /// anyway. Keeping it "just until we get to it" would quietly turn the
    /// 180-day promise into an indefinite one whenever the digest fell behind.
    public func expired(at now: Date) -> [SignalRecord] {
        filter { $0.hasExpired(at: now) }
    }

    /// Rendered for the on-device model, ready to batch.
    ///
    /// `describe` is supplied by the caller because prompt wording is a
    /// Phase 2 tuning exercise, not a storage concern.
    public func digestItems(describe: (SignalPayload) -> String) throws -> [DigestItem] {
        try pendingForDigest().map { record in
            DigestItem(id: record.id, text: describe(try record.decodedPayload()))
        }
    }
}
