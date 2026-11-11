import Foundation
import SwiftData

import PAgentCore

/// A saved conversation (§5, extending the Phase 0 baseline).
///
/// ## Why this is stored at all
///
/// The transcript is the only record of what the user asked for. Losing it on
/// quit means a plan built over several turns is gone, and §3.1 puts the
/// `messages` array on the device precisely so a turn can be continued.
///
/// ## Why it expires
///
/// A transcript holds whatever the user typed, which is the least predictable
/// personal data in the store — more so than a calendar title, because it is
/// unstructured. §9.3 promises automatic retention, so this carries the same
/// `retentionUntil` machinery as `SignalEvent` rather than living forever.
@Model
public final class Conversation {
    /// Only `updatedAt` — the list is ordered by it and nothing else queries
    /// a conversation by anything but its id.
    #Index<Conversation>([\.updatedAt])

    @Attribute(.unique) public var id: UUID

    /// First prompt, truncated. Shown in the conversation list.
    ///
    /// Stored rather than derived so the list does not have to fault in every
    /// turn of every conversation to render a title.
    public var title: String

    public var createdAt: Date
    /// Bumped on every turn. The list sorts by this, so a revisited old
    /// conversation rises back to the top.
    public var updatedAt: Date

    /// The §9.3 horizon, set at creation from ``PAgentCore/RetentionPolicy``.
    public var retentionUntil: Date

    /// `.cascade` because a turn has no meaning without its conversation.
    @Relationship(deleteRule: .cascade, inverse: \StoredTurn.conversation)
    public var turns: [StoredTurn]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        retentionUntil: Date,
        turns: [StoredTurn] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.retentionUntil = retentionUntil
        self.turns = turns
    }

    /// Clips a prompt down to something that fits a list row.
    public static func title(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return firstLine.count <= 40 ? firstLine : String(firstLine.prefix(39)) + "…"
    }
}

/// One exchange, as stored.
///
/// The in-memory `ConversationTurn` keeps its segments as observable class
/// instances so SwiftUI can watch a single block mutate while it streams.
/// Those are the wrong shape for storage — a stream of deltas is not a record.
/// This is the settled form: the prompt, the segments as a decoded array, and
/// the outcome.
@Model
public final class StoredTurn {
    #Index<StoredTurn>([\.startedAt])

    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var prompt: String

    /// JSON-encoded `[TurnSegment]`.
    ///
    /// Opaque `Data` for the same reason §5.1 stores signal payloads that way:
    /// the segment shape *will* change — a future phase adds proposal cards,
    /// images, citations — and re-encoding every stored turn for each of those
    /// is a migration this avoids entirely.
    public var segmentsData: Data

    /// `nil` unless the turn failed. Stored because "this one failed" is part
    /// of the history; silently dropping failures would make the transcript a
    /// record of only the successes.
    public var failureTitle: String?
    public var failureDetail: String?

    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int

    /// The exact bytes sent, for §9.3 clause 5.1.2.
    ///
    /// Nullable because a turn that failed during construction never produced
    /// any.
    public var requestBody: String?

    public var conversation: Conversation?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        prompt: String,
        segmentsData: Data,
        failureTitle: String? = nil,
        failureDetail: String? = nil,
        usage: Usage? = nil,
        requestBody: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.prompt = prompt
        self.segmentsData = segmentsData
        self.failureTitle = failureTitle
        self.failureDetail = failureDetail
        self.inputTokens = usage?.inputTokens ?? 0
        self.outputTokens = usage?.outputTokens ?? 0
        self.cacheReadInputTokens = usage?.cacheReadInputTokens ?? 0
        self.requestBody = requestBody
    }

    public var usage: Usage? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return Usage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens
        )
    }

    public func decodedSegments() throws -> [TurnSegment] {
        try JSONDecoder().decode([TurnSegment].self, from: segmentsData)
    }
}


// MARK: - Queries

extension Conversation {
    /// Most recently used first.
    public static func recent(limit: Int? = nil) -> FetchDescriptor<Conversation> {
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Conversations past their retention horizon, for the nightly sweep.
    public static func expired(asOf now: Date) -> FetchDescriptor<Conversation> {
        FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.retentionUntil <= now },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
    }

    public static func withID(_ id: UUID) -> FetchDescriptor<Conversation> {
        FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
    }
}

extension StoredTurn {
    /// A conversation's turns, oldest first — the order they are replayed in.
    public static func inConversation(_ conversationID: UUID) -> FetchDescriptor<StoredTurn> {
        FetchDescriptor<StoredTurn>(
            predicate: #Predicate { $0.conversation?.id == conversationID },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
    }
}
