import Foundation
import Testing
@testable import Autoscreener

// App-wiring step (§8, post-Phase-3): the thin headless Tier-A entry point. The live provider, the
// engine, and the Watchlist composite each have their own suites — these tests only pin
// `SelectionRunner`'s orchestration: it sources the candidate universe, runs the engine over EXACTLY
// that universe, and short-circuits an empty universe without building (or fetching for) an engine.

private func neutralContext() -> MarketContext {
    // risk = 0.5·1.0 + (1−0.6)·0.5 = 0.70 → neutral → maxTotalExposure 0.65 > 0, so run() proceeds.
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}

/// A SecurityData with no bars and no financials — the first gate (`DataIntegrityGate`) eliminates
/// it, so the engine produces no recommendation and `run()` returns [] cleanly (no throw, no crash).
/// Enough to exercise the pipeline without recreating the full scoring Object Mother.
private func barrenSecurity(_ t: Ticker) -> SecurityData {
    SecurityData(
        ticker: t, sector: "Industrials", price: 0, sharesOutstanding: 0, freeFloatPct: 0,
        financials: [],
        ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                           totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                           returnOnEquity: 0),
        dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: [], marketIndexBars: [])
}

/// In-memory provider that echoes whatever universe the engine was built for.
private struct EchoProvider: DataProvider {
    let tickers: [Ticker]
    func universe() async throws -> [Ticker] { tickers }
    func data(for t: Ticker) async throws -> SecurityData { barrenSecurity(t) }
    func marketContext() async throws -> MarketContext { neutralContext() }
}

@MainActor
private final class CallSpy {
    var universe: [Ticker] = []
    var madeEngine = false
}

@Suite @MainActor struct SelectionRunnerTests {

    @Test func sourcesTheUniverseAndRunsTheEngineOverExactlyThatUniverse() async throws {
        let spy = CallSpy()
        let runner = SelectionRunner(
            universeSource: { ["WIFI", "BBCA"] },
            makeEngine: { universe, config in
                spy.universe = universe
                spy.madeEngine = true
                return StockSelectionEngine(provider: EchoProvider(tickers: universe), config: config)
            })

        _ = try await runner.run(config: .balanced)

        #expect(spy.madeEngine)
        #expect(spy.universe == ["WIFI", "BBCA"])   // sourced universe threaded straight into the engine
    }

    @Test func emptyUniverseShortCircuitsWithoutBuildingAnEngine() async throws {
        let spy = CallSpy()
        let runner = SelectionRunner(
            universeSource: { [] },
            makeEngine: { universe, config in
                spy.madeEngine = true
                return StockSelectionEngine(provider: EchoProvider(tickers: universe), config: config)
            })

        let outcome = try await runner.run()

        #expect(outcome.recommendations.isEmpty)
        #expect(outcome.skipped.isEmpty)
        #expect(spy.madeEngine == false)            // no candidates → no market fetch, no engine
    }
}
