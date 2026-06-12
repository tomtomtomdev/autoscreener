import Foundation
import Testing
@testable import Autoscreener

/// Tests the pure regime-gated, conviction-weighted, risk-capped allocator.
@Suite struct AllocationEngineTests {

    // MARK: - Builders

    private func read(_ stance: RegimeStance, score: Double) -> RegimeRead {
        RegimeRead(stance: stance, score: score,
                   factors: [RegimeFactor(kind: .breadth, signal: .neutral, detail: "test")],
                   asOf: "2026-06-12", valuationCapped: false)
    }

    /// `n` watchlist names SYM00…, descending conviction, each priced at `price`.
    private func universe(_ n: Int, score: (Int) -> Double = { 5 - Double($0) * 0.1 },
                          price: Double = 1_000) -> (rows: [WatchlistRow], prices: [String: Double]) {
        var rows: [WatchlistRow] = []
        var prices: [String: Double] = [:]
        for i in 0..<n {
            let sym = String(format: "SYM%02d", i)
            // matchedScreeners drives `score`; fabricate a set summing near the target.
            rows.append(WatchlistRow(symbol: sym, name: "\(sym) Co", matchedScreeners: []))
            prices[sym] = price
        }
        // WatchlistRow.score is derived from matchedScreeners; for sizing tests we need
        // a real spread, so wrap with an explicit-score shim via a parallel sort key.
        _ = score
        return (rows, prices)
    }

    private let seed = PaperPortfolioState.seed   // 100M cash, no positions

    // MARK: - Layer 1: regime → exposure

    @Test func riskOffParksMostOfTheBookInCash() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOff, score: -0.9), prices: prices)
        #expect(plan.targetExposure <= 0.30)        // risk-off band
        #expect(plan.cashTarget >= plan.equity * 0.70)
    }

    @Test func riskOnDeploysHeavilyButNeverFully() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices)
        #expect(plan.targetExposure > 0.60)
        #expect(plan.targetExposure <= 0.95)        // survive-first cash floor
        #expect(plan.cashTarget >= plan.equity * 0.05 - 1)
    }

    @Test func nilRegimeFallsBackToNeutralBand() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, watchlist: rows, regime: nil, prices: prices)
        #expect(plan.stance == .neutral)
        #expect(plan.targetExposure >= 0.50 && plan.targetExposure <= 0.60)
    }

    // MARK: - Layer 3: sizing, caps, diversification

    @Test func noNameExceedsThePerNameCap() {
        let (rows, prices) = scoredUniverse(20)
        let cfg = AllocationConfig.standard
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        for line in plan.lines where line.side == .buy {
            #expect(line.targetWeight <= cfg.effectivePerNameCap + 1e-6)
        }
    }

    @Test func fullDeploymentHonoursPositionCountFloor() {
        let (rows, prices) = scoredUniverse(20)
        let cfg = AllocationConfig.standard
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let bought = plan.lines.filter { $0.side == .buy }
        #expect(bought.count >= cfg.minPositions)   // ≥6 names share the deployed book
    }

    @Test func fractionalKellyDampsTheTopNameVsRawProportional() {
        // Top name has 4× the conviction of the rest. √-damping must pull its weight
        // well below the 80% a raw-proportional split would hand it.
        let rows = [
            WatchlistRow(symbol: "AAA", name: "AAA", matchedScreeners: [.accumulating, .shiftToday]), // score 4.0
            WatchlistRow(symbol: "BBB", name: "BBB", matchedScreeners: [.foreignFlow1M]),              // 1.0
            WatchlistRow(symbol: "CCC", name: "CCC", matchedScreeners: [.foreignFlow3M]),              // 1.0
            WatchlistRow(symbol: "DDD", name: "DDD", matchedScreeners: [.freqSpike]),                  // 1.0
        ]
        let prices = Dictionary(uniqueKeysWithValues: rows.map { ($0.symbol, 1_000.0) })
        var cfg = AllocationConfig.standard
        cfg.perNameCap = 1.0; cfg.minPositions = 1   // disable caps to isolate the damping
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let top = plan.lines.first { $0.symbol == "AAA" }
        #expect(top != nil)
        let rawShare = 4.0 / (4.0 + 1 + 1 + 1)      // 0.571 of the deployed sleeve
        // √-damped: √4 / (√4 + 3·√1) = 2/5 = 0.40 of the sleeve → well under raw.
        #expect((top!.targetWeight / plan.targetExposure) < rawShare - 0.1)
    }

    @Test func lotRoundingProducesWholeLots() {
        let (rows, prices) = scoredUniverse(8, price: 333)   // awkward price forces rounding
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 0.8), prices: prices)
        for line in plan.lines {
            #expect(line.targetShares.truncatingRemainder(dividingBy: 100) == 0)
            #expect(abs(line.deltaShares).truncatingRemainder(dividingBy: 100) == 0)
        }
    }

    @Test func emptyWatchlistProducesNoBuys() {
        let plan = AllocationEngine.plan(state: seed, watchlist: [],
                                         regime: read(.riskOn, score: 1.0), prices: [:])
        #expect(plan.lines.allSatisfy { $0.side == .sell })
        #expect(plan.lines.isEmpty)
    }

    @Test func nameWithoutAPriceIsSkipped() {
        let rows = [
            WatchlistRow(symbol: "AAA", name: "AAA", matchedScreeners: [.accumulating]),
            WatchlistRow(symbol: "NPR", name: "No Price", matchedScreeners: [.accumulating]),
        ]
        let prices = ["AAA": 1_000.0]   // NPR absent
        let plan = AllocationEngine.plan(state: seed, watchlist: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices)
        #expect(plan.lines.contains { $0.symbol == "AAA" })
        #expect(!plan.lines.contains { $0.symbol == "NPR" })
    }

    @Test func subBandDeltaIsSuppressed() {
        // Already holding almost exactly the target → the tiny top-up is below the
        // rebalance band and must not generate a line.
        let rows = [WatchlistRow(symbol: "AAA", name: "AAA", matchedScreeners: [.accumulating])]
        let prices = ["AAA": 1_000.0]
        var state = PaperPortfolioState.seed
        // Neutral, single name → weight is the per-name cap. Seed the holding *by buying*
        // (so cash is deducted and equity stays ~100M) at exactly that capped target, so
        // the recomputed delta is ~0 and falls inside the rebalance band.
        var cfg = AllocationConfig.standard
        cfg.execution = ExecutionModel(lotSize: 100, buyFeePct: 0, sellFeePct: 0,
                                       slippagePct: 0, fillAt: .nextOpen, araArbLimit: 0.25)
        let target = cfg.effectivePerNameCap * state.equity(prices: prices) / 1_000
        let lots = (target / 100).rounded(.down) * 100
        state.apply(side: .buy, symbol: "AAA", shares: lots, price: 1_000, feePct: 0,
                    date: Date(timeIntervalSince1970: 0))
        let plan = AllocationEngine.plan(state: state, watchlist: rows,
                                         regime: read(.neutral, score: 0), prices: prices, config: cfg)
        #expect(!plan.lines.contains { $0.symbol == "AAA" })
    }

    @Test func droppedNameIsFullyExited() {
        // Hold a name that isn't in the watchlist any more → expect a full sell.
        let rows = [WatchlistRow(symbol: "AAA", name: "AAA", matchedScreeners: [.accumulating])]
        let prices = ["AAA": 1_000.0, "OLD": 2_000.0]
        var state = PaperPortfolioState.seed
        state.positions["OLD"] = PaperPosition(shares: 5_000, avgCost: 1_800)
        let plan = AllocationEngine.plan(state: state, watchlist: rows,
                                         regime: read(.neutral, score: 0), prices: prices)
        let exit = plan.lines.first { $0.symbol == "OLD" }
        #expect(exit?.side == .sell)
        #expect(exit?.targetShares == 0)
        #expect(exit?.deltaShares == -5_000)
    }

    // MARK: - Helpers

    /// A universe whose `WatchlistRow.score` genuinely descends, by handing each row a
    /// distinct count of (real) matched screeners. Index 0 is the highest conviction.
    private func scoredUniverse(_ n: Int, price: Double = 1_000)
        -> (rows: [WatchlistRow], prices: [String: Double]) {
        let pool = BandarScreenerKind.allCases
        var rows: [WatchlistRow] = []
        var prices: [String: Double] = [:]
        for i in 0..<n {
            let sym = String(format: "SYM%02d", i)
            // More screeners for lower i → higher score, strictly descending.
            let count = max(1, min(pool.count, n - i))
            rows.append(WatchlistRow(symbol: sym, name: "\(sym) Co",
                                     matchedScreeners: Set(pool.prefix(count))))
            prices[sym] = price
        }
        return (rows, prices)
    }
}
