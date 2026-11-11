import Foundation
import SwiftData

import PAgentCore
import PAgentData

/// The SwiftData-backed ``ConversationStoring``.
///
/// Lives in the app target rather than in `PAgentData` because it translates
/// between the storage models and the view's `ConversationTurn` — a direction
/// `PAgentData` should not know about. The package stays a schema.
@MainActor
public final class SwiftDataConversationStore: ConversationStoring {
    private let context: ModelContext
    private let retention: RetentionPolicy

    public init(context: ModelContext, retention: RetentionPolicy = .standard) {
        self.context = context
        self.retention = retention
    }

    public func createConversation(titledFrom prompt: String) throws -> UUID {
        let now = Date()
        let conversation = Conversation(
            title: Conversation.title(from: prompt),
            createdAt: now,
            // Same horizon as a signal. §9.3's retention promise covers the
            // transcript too — see the note on `Conversation`.
            retentionUntil: retention.expiry(forSignalAt: now)
        )
        context.insert(conversation)
        try context.save()
        return conversation.id
    }

    public func append(_ turn: ConversationTurn, to conversationID: UUID) throws {
        guard let conversation = try context.fetch(Conversation.withID(conversationID)).first else {
            // The conversation was deleted while the turn was in flight.
            // Dropping the turn is right — re-creating the conversation would
            // resurrect something the user explicitly removed.
            return
        }

        let stored = StoredTurn(
            id: turn.id,
            startedAt: turn.startedAt,
            prompt: turn.prompt,
            segmentsData: try JSONEncoder().encode(turn.storableSegments),
            failureTitle: turn.failure?.title,
            failureDetail: turn.failure?.detail,
            usage: turn.usage,
            requestBody: turn.requestBody
        )
        stored.conversation = conversation
        context.insert(stored)
        conversation.updatedAt = turn.startedAt
        try context.save()
    }

    public func recentConversations(limit: Int) throws -> [ConversationSummary] {
        try context.fetch(Conversation.recent(limit: limit)).map {
            ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    public func turns(in conversationID: UUID) throws -> [ConversationTurn] {
        try context.fetch(StoredTurn.inConversation(conversationID)).map { stored in
            let turn = ConversationTurn(prompt: stored.prompt, startedAt: stored.startedAt)
            // A decode failure costs one turn's content, not the conversation.
            // The prompt is still there, which is the part the user wrote.
            let segments = (try? stored.decodedSegments()) ?? []
            turn.restore(segments)
            turn.usage = stored.usage
            turn.requestBody = stored.requestBody
            if let title = stored.failureTitle {
                turn.status = .failed(
                    .init(title: title, detail: stored.failureDetail ?? "", isRetryable: true)
                )
            } else {
                turn.status = .finished
            }
            return turn
        }
    }

    public func deleteConversation(_ conversationID: UUID) throws {
        guard let conversation = try context.fetch(Conversation.withID(conversationID)).first else {
            return
        }
        context.delete(conversation)
        try context.save()
    }
}
