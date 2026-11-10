import Foundation
import Testing

@testable import PAgentCore

/// Counts a token per whitespace-separated word, plus one per CJK character.
///
/// Not an attempt to imitate Apple's tokenizer — the point of `TokenCounting`
/// being a protocol is that the real count comes from
/// `SystemLanguageModel.default.tokenCount(for:)` on device (§2.1). What the
/// tests need is a counter that is *monotonic and deterministic*, so batching
/// and trimming decisions can be asserted exactly.
struct WordTokenCounter: TokenCounting {
    func tokenCount(for text: String) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace)
        let asciiWords = words.filter { $0.allSatisfy(\.isASCII) }.count
        let cjk = text.unicodeScalars.count { $0.value >= 0x2E80 }
        return asciiWords + cjk
    }
}

/// Fails on demand, to exercise the guardrail-failure path.
struct ThrowingTokenCounter: TokenCounting {
    struct Failure: Error {}
    func tokenCount(for text: String) throws -> Int {
        throw Failure()
    }
}

private func item(_ text: String) -> DigestItem {
    DigestItem(id: UUID(), text: text)
}

@Suite("TokenBudget")
struct TokenBudgetTests {
    @Test("promptAllowance holds back the reserve for schema and output")
    func reserveIsSubtracted() {
        // §6.1's shape: a 4096 window, ~1000 reserved, 2500 per batch.
        let budget = TokenBudget(contextSize: 4096, reserve: 1000, batchLimit: 2500)
        #expect(budget.promptAllowance == 2500)
    }

    @Test("the window binds when it is tighter than the batch limit")
    func windowCanBind() {
        // A smaller context than §2.1 documents — the point is that the code
        // reads `contextSize` rather than assuming 4096.
        let budget = TokenBudget(contextSize: 2048, reserve: 1000, batchLimit: 2500)
        #expect(budget.promptAllowance == 1048)
    }

    @Test("a reserve larger than the window yields no allowance rather than a negative one")
    func reserveCanExhaustWindow() {
        let budget = TokenBudget(contextSize: 500, reserve: 1000, batchLimit: 2500)
        #expect(budget.promptAllowance == 0)
    }
}

@Suite("DigestBatcher")
struct DigestBatcherTests {
    private let counter = WordTokenCounter()

    private func batcher(allowance: Int, joiner: Int = 1) -> DigestBatcher {
        DigestBatcher(
            counter: counter,
            budget: TokenBudget(contextSize: 4096, reserve: 0, batchLimit: allowance),
            joinerTokenCount: joiner
        )
    }

    @Test("packs items up to the allowance and then opens a new batch")
    func packsGreedily() throws {
        // Three items of 2 tokens each, joiner 1 → 2 + 1 + 2 = 5 fits, adding
        // a third would reach 8.
        let plan = try batcher(allowance: 5).plan([
            item("one two"),
            item("three four"),
            item("five six"),
        ])

        #expect(plan.batches.count == 2)
        #expect(plan.batches[0].items.count == 2)
        #expect(plan.batches[0].tokenCount == 5)
        #expect(plan.batches[1].items.count == 1)
        #expect(plan.oversize.isEmpty)
    }

    @Test("preserves occurredAt order rather than repacking for density")
    func preservesOrder() throws {
        // §6.1 sorts by occurredAt and a day's signals read as a sequence.
        // A tighter packing exists here (the two 1-token items together) and
        // is deliberately not taken.
        let first = item("alpha")
        let big = item("a b c d")
        let last = item("omega")

        let plan = try batcher(allowance: 4).plan([first, big, last])

        let flattened = plan.batches.flatMap(\.items)
        #expect(flattened.map(\.id) == [first.id, big.id, last.id])
    }

    @Test("an item that cannot fit alone is reported, never truncated")
    func oversizeIsSurfaced() throws {
        // §5.1 keeps payloads raw so signals can be replayed; truncating one
        // to fit would corrupt the only copy. §6.1 routes these to Haiku.
        let huge = item("a b c d e f g h i j")
        let plan = try batcher(allowance: 4).plan([item("small"), huge, item("also small")])

        #expect(plan.oversize.map(\.id) == [huge.id])
        #expect(plan.batches.flatMap(\.items).contains { $0.id == huge.id } == false)
        // The items either side still get batched.
        #expect(plan.batches.flatMap(\.items).count == 2)
    }

    @Test("an oversize item does not merge the batches around it")
    func oversizeFlushesCurrentBatch() throws {
        let plan = try batcher(allowance: 4).plan([
            item("before"),
            item("a b c d e f"),
            item("after"),
        ])

        // Two separate batches, not one containing both neighbours.
        #expect(plan.batches.count == 2)
        #expect(plan.batches.allSatisfy { $0.items.count == 1 })
    }

    @Test("no items yields no batches")
    func emptyInput() throws {
        let plan = try batcher(allowance: 100).plan([])
        #expect(plan.batches.isEmpty)
        #expect(plan.oversize.isEmpty)
    }

    @Test("counts the joiner between items, not before the first")
    func joinerAccounting() throws {
        // Two 1-token items with a 3-token joiner: 1 + 3 + 1 = 5.
        let plan = try batcher(allowance: 5, joiner: 3).plan([item("x"), item("y")])
        #expect(plan.batches.count == 1)
        #expect(plan.batches[0].tokenCount == 5)

        // The same pair with allowance 4 no longer fits together.
        let split = try batcher(allowance: 4, joiner: 3).plan([item("x"), item("y")])
        #expect(split.batches.count == 2)
    }

    @Test("every batch is within the allowance")
    func allBatchesFit() throws {
        let allowance = 17
        let items = (1...40).map { item(String(repeating: "w ", count: $0 % 7 + 1)) }
        let plan = try batcher(allowance: allowance).plan(items)

        for batch in plan.batches {
            #expect(batch.tokenCount <= allowance)
        }
        // Nothing is lost: every item is either batched or reported oversize.
        let accounted = plan.batches.flatMap(\.items).count + plan.oversize.count
        #expect(accounted == items.count)
    }

    @Test("a failing counter propagates rather than silently under-counting")
    func counterFailurePropagates() {
        let strict = DigestBatcher(
            counter: ThrowingTokenCounter(),
            budget: TokenBudget(contextSize: 4096)
        )
        #expect(throws: ThrowingTokenCounter.Failure.self) {
            try strict.plan([item("anything")])
        }
    }
}

@Suite("DigestBatch halving")
struct DigestBatchHalvingTests {
    @Test("splits in half for the §6.1 retry")
    func halves() {
        let items = (1...5).map { item("item \($0)") }
        let batch = DigestBatch(items: items, tokenCount: 50)

        let halves = batch.halved()
        #expect(halves != nil)
        #expect(halves?.0.items.count == 2)
        #expect(halves?.1.items.count == 3)
        // Order is preserved across the split.
        #expect((halves?.0.items.map(\.id) ?? []) == items[0..<2].map(\.id))
        #expect((halves?.1.items.map(\.id) ?? []) == items[2...].map(\.id))
    }

    @Test("a single-item batch cannot be halved")
    func singleItemCannotHalve() {
        // There is nothing left to split; §6.1 marks these `skipped` for the
        // cloud fallback instead of retrying forever.
        #expect(DigestBatch(items: [item("alone")], tokenCount: 10).halved() == nil)
        #expect(DigestBatch(items: [], tokenCount: 0).halved() == nil)
    }
}
