import Foundation
import Testing
@testable import Autoscreener

@MainActor
@Suite struct PaperTradingStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-store-tests", isDirectory: true)
            .appendingPathComponent("cache-\(UUID().uuidString).json")
    }

    private func buyLine(_ symbol: String, shares: Double, price: Double) -> AllocationLine {
        AllocationLine(symbol: symbol, name: "\(symbol) Co", side: .buy,
                       currentShares: 0, targetShares: shares, deltaShares: shares,
                       price: price, estValue: shares * price, targetWeight: 0.1, rationale: "buy")
    }

    private func plan(_ lines: [AllocationLine]) -> AllocationPlan {
        AllocationPlan(stance: .neutral, score: 0, targetExposure: 0.5,
                       equity: 100_000_000, cashTarget: 50_000_000, lines: lines)
    }

    @Test func freshStoreIsSeededWith100M() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        #expect(store.state.cash == 100_000_000)
        #expect(store.state.initialCapital == 100_000_000)
        #expect(store.state.positions.isEmpty)
    }

    @Test func applyBuysSpendCashAndOpenPositions() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let v0 = store.version
        store.apply(plan: plan([buyLine("BBCA", shares: 1_000, price: 9_000)]))

        #expect(store.version == v0 + 1)
        #expect(store.state.positions["BBCA"]?.shares == 1_000)
        // Cash dropped by notional + buy fee + slippage (all positive).
        #expect(store.state.cash < 100_000_000 - 9_000_000)
        #expect(store.state.trades.count == 1)
        #expect(store.state.trades.first?.side == .buy)
    }

    @Test func emptyPlanIsANoOp() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let v0 = store.version
        store.apply(plan: plan([]))
        #expect(store.version == v0)
        #expect(store.state.cash == 100_000_000)
    }

    @Test func sellBooksRealizedPnLMatchingPortfolioMath() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        // Buy 1,000 @ 1,000 (no slippage/fees for a clean P&L assertion).
        var cfg = AllocationConfig.standard
        cfg.execution = ExecutionModel(lotSize: 100, buyFeePct: 0, sellFeePct: 0,
                                       slippagePct: 0, fillAt: .nextOpen, araArbLimit: 0.25)
        store.apply(plan: plan([buyLine("AAA", shares: 1_000, price: 1_000)]), config: cfg)

        let sell = AllocationLine(symbol: "AAA", name: "AAA", side: .sell,
                                  currentShares: 1_000, targetShares: 0, deltaShares: -1_000,
                                  price: 1_200, estValue: 1_200_000, targetWeight: 0, rationale: "exit")
        store.apply(plan: plan([sell]), config: cfg)

        #expect(store.state.positions["AAA"] == nil)
        // Realized = (1200 − 1000) × 1000 = 200,000.
        #expect(store.state.realizedPnL == 200_000)
    }

    @Test func resetReturnsToSeed() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        store.apply(plan: plan([buyLine("BBCA", shares: 1_000, price: 9_000)]))
        store.reset()
        #expect(store.state.cash == 100_000_000)
        #expect(store.state.positions.isEmpty)
        #expect(store.state.trades.isEmpty)
    }

    @Test func persistThenLoadRoundTripsPortfolioToDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = PaperTradingStore(fileURL: url, loadFromDisk: false)
        writer.apply(plan: plan([buyLine("TLKM", shares: 2_000, price: 2_800)]))
        let savedCash = writer.state.cash

        let reader = PaperTradingStore(fileURL: url, loadFromDisk: true)
        #expect(reader.state.positions["TLKM"]?.shares == 2_000)
        #expect(reader.state.cash == savedCash)
        #expect(reader.state.trades.count == 1)
    }

    @Test func corruptFileKeepsSeed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = PaperTradingStore(fileURL: url, loadFromDisk: true)
        #expect(store.state.cash == 100_000_000)
        #expect(store.state.positions.isEmpty)
    }

    // MARK: - Gate-5 Phase 3: entry-thesis capture + HoldingsProvider

    private func thesis(iv: Double, mos: Double = 0.30, category: LynchCategory? = nil) -> EntryThesis {
        EntryThesis(entryDate: Date(timeIntervalSince1970: 0), entryIntrinsicValue: iv,
                    entryMarginOfSafety: mos, lynchCategory: category)
    }

    @Test func aBuyThatOpensALotStampsTheThesis() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let t = thesis(iv: 9_500, category: .stalwart)
        store.apply(plan: plan([buyLine("BBCA", shares: 1_000, price: 9_000)]), theses: ["BBCA": t])
        #expect(store.state.positions["BBCA"]?.thesis == t)
    }

    @Test func aBuyThatAddsToAnOpenLotPreservesTheOriginalThesis() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let entry = thesis(iv: 9_500, category: .stalwart)
        store.apply(plan: plan([buyLine("BBCA", shares: 1_000, price: 9_000)]), theses: ["BBCA": entry])
        // A later add carries a different (newer) thesis — it must NOT overwrite the entry rationale.
        store.apply(plan: plan([buyLine("BBCA", shares: 500, price: 9_500)]),
                    theses: ["BBCA": thesis(iv: 1, category: .cyclical)])
        #expect(store.state.positions["BBCA"]?.shares == 1_500)
        #expect(store.state.positions["BBCA"]?.thesis == entry)
    }

    @Test func aLotClosedThenReboughtTakesAFreshThesis() {
        var cfg = AllocationConfig.standard
        cfg.execution = ExecutionModel(lotSize: 100, buyFeePct: 0, sellFeePct: 0,
                                       slippagePct: 0, fillAt: .nextOpen, araArbLimit: 0.25)
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let first = thesis(iv: 1_000, category: .stalwart)
        store.apply(plan: plan([buyLine("AAA", shares: 1_000, price: 1_000)]), theses: ["AAA": first], config: cfg)
        let sell = AllocationLine(symbol: "AAA", name: "AAA", side: .sell, currentShares: 1_000,
                                  targetShares: 0, deltaShares: -1_000, price: 1_200,
                                  estValue: 1_200_000, targetWeight: 0, rationale: "exit")
        store.apply(plan: plan([sell]), config: cfg)        // lot closes → thesis dropped with it
        #expect(store.state.positions["AAA"] == nil)
        let second = thesis(iv: 2_000, category: .fastGrower)
        store.apply(plan: plan([buyLine("AAA", shares: 500, price: 1_300)]), theses: ["AAA": second], config: cfg)
        #expect(store.state.positions["AAA"]?.thesis == second)
    }

    @Test func aThesisRoundTripsThroughDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = thesis(iv: 2_800, category: .assetPlay)
        let writer = PaperTradingStore(fileURL: url, loadFromDisk: false)
        writer.apply(plan: plan([buyLine("TLKM", shares: 2_000, price: 2_800)]), theses: ["TLKM": t])

        let reader = PaperTradingStore(fileURL: url, loadFromDisk: true)
        #expect(reader.state.positions["TLKM"]?.thesis == t)
    }

    @Test func heldPositionsMapsTheStoreIntoTheGate5Boundary() {
        let store = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        let t = thesis(iv: 9_500, category: .stalwart)
        store.apply(plan: plan([buyLine("BBCA", shares: 1_000, price: 9_000)]), theses: ["BBCA": t])
        store.apply(plan: plan([buyLine("TLKM", shares: 2_000, price: 2_800)]))   // no thesis

        let held = store.heldPositions().sorted { $0.ticker < $1.ticker }
        #expect(held.map(\.ticker) == ["BBCA", "TLKM"])
        #expect(held.first(where: { $0.ticker == "BBCA" })?.thesis == t)
        #expect(held.first(where: { $0.ticker == "TLKM" })?.thesis == nil)
        #expect(held.first(where: { $0.ticker == "BBCA" })?.shares == 1_000)
    }
}
