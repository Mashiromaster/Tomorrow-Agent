import Foundation

import PAgentCore

/// One exchange in the conversation.
///
/// Holds the agent's work as an ordered list rather than as flat strings. The
/// Phase 0 screen kept `thinking` and `answer` as two accumulating `String`s,
/// which could not express the thing a planning turn actually does: think,
/// call a tool, think again, answer. Ordering matters because the reasoning
/// after a tool result is about that result — collapsing it into one blob
/// loses which came first.
@MainActor
@Observable
public final class ConversationTurn: Identifiable {
    public enum Status: Sendable, Equatable {
        case streaming
        case finished
        case failed(Failure)

        public var isStreaming: Bool { self == .streaming }
    }

    /// A failure worth showing, already translated out of the typed errors.
    public struct Failure: Sendable, Equatable {
        public let title: String
        public let detail: String
        public let isRetryable: Bool

        public init(title: String, detail: String, isRetryable: Bool) {
            self.title = title
            self.detail = detail
            self.isRetryable = isRetryable
        }
    }

    /// A tool the model invoked, and how it ended.
    @Observable
    public final class ToolCall: Identifiable {
        public let id = UUID()
        public let name: String
        public var finished = false
        public var failed = false

        init(name: String) { self.name = name }
    }

    /// The pieces of a turn, in the order they arrived.
    public enum Segment: Identifiable {
        case thinking(ThinkingBlock)
        case text(TextBlock)
        case tool(ToolCall)

        public var id: UUID {
            switch self {
            case .thinking(let block): block.id
            case .text(let block): block.id
            case .tool(let call): call.id
            }
        }
    }

    @Observable
    public final class ThinkingBlock: Identifiable {
        public let id = UUID()
        public var text = ""
        /// Collapsed once the answer starts, the way a reader would want it:
        /// visible while it is the only thing happening, out of the way after.
        public var isExpanded = true

        /// First sentence, for the collapsed row.
        public var summary: String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init)
            return firstLine ?? trimmed
        }
    }

    @Observable
    public final class TextBlock: Identifiable {
        public let id = UUID()
        public var text = ""
    }

    public let id = UUID()
    public let prompt: String
    public let startedAt: Date

    public private(set) var segments: [Segment] = []
    public var status: Status = .streaming
    public var usage: Usage?
    /// The exact bytes sent, for the §9.3 disclosure screen.
    public var requestBody: String?

    public init(prompt: String, startedAt: Date = .now) {
        self.prompt = prompt
        self.startedAt = startedAt
    }

    // MARK: - Applying activity

    /// Appends a delta to the trailing thinking block, starting one if the
    /// previous segment was something else.
    public func appendThinking(_ delta: String) {
        if case .thinking(let block) = segments.last {
            block.text += delta
        } else {
            let block = ThinkingBlock()
            block.text = delta
            segments.append(.thinking(block))
        }
    }

    public func appendText(_ delta: String) {
        // Once prose starts, the reasoning that led to it is no longer the
        // main event.
        collapseThinking()
        if case .text(let block) = segments.last {
            block.text += delta
        } else {
            let block = TextBlock()
            block.text = delta
            segments.append(.text(block))
        }
    }

    public func startTool(named name: String) {
        collapseThinking()
        segments.append(.tool(ToolCall(name: name)))
    }

    public func finishTool(named name: String, failed: Bool) {
        // Searches backwards: the same tool can be called more than once in a
        // turn, and the one just finished is the most recent unfinished one.
        for segment in segments.reversed() {
            if case .tool(let call) = segment, call.name == name, !call.finished {
                call.finished = true
                call.failed = failed
                return
            }
        }
    }

    private func collapseThinking() {
        if case .thinking(let block) = segments.last { block.isExpanded = false }
    }

    // MARK: - Derived

    /// Every tool call in the turn, for the summary line.
    public var toolCalls: [ToolCall] {
        segments.compactMap { if case .tool(let call) = $0 { call } else { nil } }
    }

    /// Whether anything has been rendered yet — drives the "thinking…" state.
    public var isEmpty: Bool { segments.isEmpty }

    public var failure: Failure? {
        if case .failed(let failure) = status { return failure }
        return nil
    }
}
