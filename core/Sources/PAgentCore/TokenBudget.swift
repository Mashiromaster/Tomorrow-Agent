import Foundation

/// Counts tokens the way the model that will read them does.
///
/// On device this is backed by `SystemLanguageModel.default.tokenCount(for:)`
/// (iOS 26.4+, back-deployed). It is a protocol because of
/// IMPLEMENTATION.md §2.1: the real limit must be *read*, never hardcoded —
/// and because a counter you can substitute is a counter you can test.
public protocol TokenCounting: Sendable {
    func tokenCount(for text: String) throws -> Int
}

/// The on-device context budget.
///
/// `contextSize` covers **everything**: system instructions, the prompt, the
/// `@Generable` schema, tool definitions, and the response. The 4096 figure in
/// §2.1 is therefore not an input allowance — it is the whole envelope, which
/// is why `promptAllowance` subtracts a reserve rather than using the full
/// window.
public struct TokenBudget: Sendable, Hashable {
    /// Read from `SystemLanguageModel.default.contextSize`, never hardcoded.
    public let contextSize: Int

    /// Held back for system instructions, the output schema, and the response.
    /// §6.1 sizes this at ~1000 of a 4096 window.
    public let reserve: Int

    /// Hard ceiling for one batch's prompt text (§6.1 uses 2500).
    public let batchLimit: Int

    public init(contextSize: Int, reserve: Int = 1000, batchLimit: Int = 2500) {
        precondition(contextSize > 0, "contextSize must be positive")
        precondition(reserve >= 0, "reserve cannot be negative")
        precondition(batchLimit > 0, "batchLimit must be positive")
        self.contextSize = contextSize
        self.reserve = reserve
        self.batchLimit = batchLimit
    }

    /// What is actually available for prompt text.
    ///
    /// `batchLimit` is an independent policy ceiling, so the effective
    /// allowance is whichever binds first. A `batchLimit` of 2500 against a
    /// 4096 window with a 1000 reserve gives 2500; the same limit against a
    /// hypothetically smaller window gives the window's figure.
    public var promptAllowance: Int {
        min(batchLimit, max(0, contextSize - reserve))
    }
}

/// One signal awaiting nightly digest, rendered for the model.
public struct DigestItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Serialised form of `SignalEvent.payload` as the model will read it.
    public let text: String

    public init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// A group of items that fits the budget, with its measured cost.
public struct DigestBatch: Sendable, Hashable {
    public let items: [DigestItem]
    public let tokenCount: Int

    /// Splitting a batch in half is §6.1's retry strategy for a guardrail
    /// false positive or an unexpected overflow. Token counts are
    /// recalculated by the caller, so the halves carry `0` until re-measured.
    public func halved() -> (DigestBatch, DigestBatch)? {
        guard items.count >= 2 else { return nil }
        let midpoint = items.count / 2
        return (
            DigestBatch(items: Array(items[..<midpoint]), tokenCount: 0),
            DigestBatch(items: Array(items[midpoint...]), tokenCount: 0)
        )
    }
}

/// The outcome of planning a digest run.
public struct DigestPlan: Sendable, Hashable {
    /// Batches to send to the on-device model, in `occurredAt` order.
    public let batches: [DigestBatch]

    /// Items that do not fit the budget even alone.
    ///
    /// These are **not** dropped and **not** silently truncated — truncating a
    /// signal would corrupt the only record of it (§5.1 keeps payloads raw so
    /// they can be replayed). They are handed back so the caller can route
    /// them to the Haiku fallback described in §6.1, which is exactly the
    /// `skipped` state in that pipeline.
    public let oversize: [DigestItem]
}

/// Groups pending signals into batches the on-device model can actually hold.
///
/// §2.1 is unambiguous that exceeding the window throws
/// `.exceededContextWindowSize`, and that the token figure in that error is
/// the count *at the moment of the throw* rather than the true limit. So the
/// budget must be computed ahead of the call; the error is not a usable
/// signal to plan against.
public struct DigestBatcher: Sendable {
    private let counter: any TokenCounting
    private let budget: TokenBudget

    /// Cost of the separator the caller will place between items in a prompt.
    private let joinerTokenCount: Int

    public init(counter: any TokenCounting, budget: TokenBudget, joinerTokenCount: Int = 1) {
        self.counter = counter
        self.budget = budget
        self.joinerTokenCount = max(0, joinerTokenCount)
    }

    /// Greedy first-fit in the caller's order.
    ///
    /// Order is preserved deliberately: §6.1 sorts by `occurredAt`, and a day's
    /// signals read as a narrative. Repacking them to fill batches more tightly
    /// would save a few calls and cost the model the sequence.
    public func plan(_ items: [DigestItem]) throws -> DigestPlan {
        let allowance = budget.promptAllowance
        var batches: [DigestBatch] = []
        var oversize: [DigestItem] = []

        var current: [DigestItem] = []
        var currentCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            batches.append(DigestBatch(items: current, tokenCount: currentCount))
            current = []
            currentCount = 0
        }

        for item in items {
            let itemCount = try counter.tokenCount(for: item.text)

            // An item that cannot fit alone will never fit; batching it would
            // guarantee a failed call.
            if itemCount > allowance {
                flush()
                oversize.append(item)
                continue
            }

            let projected = current.isEmpty ? itemCount : currentCount + joinerTokenCount + itemCount
            if projected > allowance {
                flush()
                currentCount = itemCount
                current = [item]
            } else {
                currentCount = projected
                current.append(item)
            }
        }
        flush()

        return DigestPlan(batches: batches, oversize: oversize)
    }
}
