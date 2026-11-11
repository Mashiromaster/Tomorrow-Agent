import Foundation

import PAgentCore

/// Where finished turns go.
///
/// A protocol rather than a direct `ModelContext` reference so `PlannerModel`
/// does not import SwiftData. Two reasons that matters:
///
/// - **The model stays testable.** A `ModelContext` needs a container, which
///   needs a schema, which drags the whole §5 store into any test of the
///   conversation logic.
/// - **Failure to save must not break the conversation.** A full disk should
///   lose the transcript, not the answer on screen. Making the dependency
///   explicit is what makes that policy visible — see ``NullConversationStore``.
@MainActor
public protocol ConversationStoring: AnyObject {
    /// Creates a conversation and returns its id.
    func createConversation(titledFrom prompt: String) throws -> UUID

    /// Appends a finished turn.
    func append(_ turn: ConversationTurn, to conversationID: UUID) throws

    /// Conversations for the list, newest use first.
    func recentConversations(limit: Int) throws -> [ConversationSummary]

    /// Every turn of one conversation, oldest first.
    func turns(in conversationID: UUID) throws -> [ConversationTurn]

    func deleteConversation(_ conversationID: UUID) throws
}

/// A conversation as the list needs it — no turns faulted in.
public struct ConversationSummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// Discards everything.
///
/// The default, so `PlannerModel` works with no store at all — which is what
/// the Phase 0 acceptance path and most tests want. Named for what it does
/// rather than called an "in-memory store", because it does not remember
/// anything and pretending otherwise would hide a bug.
@MainActor
public final class NullConversationStore: ConversationStoring {
    public init() {}
    public func createConversation(titledFrom prompt: String) throws -> UUID { UUID() }
    public func append(_ turn: ConversationTurn, to conversationID: UUID) throws {}
    public func recentConversations(limit: Int) throws -> [ConversationSummary] { [] }
    public func turns(in conversationID: UUID) throws -> [ConversationTurn] { [] }
    public func deleteConversation(_ conversationID: UUID) throws {}
}
