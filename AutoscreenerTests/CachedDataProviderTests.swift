import Foundation
import Testing
@testable import Autoscreener

// The read-only provider that lets the engine rank from the sweep-filled cache. These pin its
// contract: a hit returns the cached payload, a miss is a SKIP-able `.notCached` throw (never a live
// fetch), and a missing regime context refuses to score (`.noRegimeInputs`) so the screen can show a
// "waiting for the sweep" state instead of a phantom regime.

@Suite struct CachedDataProviderTests {

    private func security(_ t: Ticker) -> SecurityData {
        SecurityData(
            ticker: t, sector: "Industrials", price: 100, sharesOutstanding: 0, freeFloatPct: 0,
            financials: [],
            ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                               totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                               returnOnEquity: 0),
            dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
            sectorIndexBars: [], marketIndexBars: [])
    }

    private func context() -> MarketContext {
        MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                      idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                      commodityTailwind: true)
    }

    @Test func universeEchoesTheRequestedTickersNotJustCachedKeys() async throws {
        let provider = CachedDataProvider(cached: ["WIFI": security("WIFI")], context: context(),
                                          tickers: ["WIFI", "BBCA"])
        #expect(try await provider.universe() == ["WIFI", "BBCA"])
    }

    @Test func hitReturnsCachedData() async throws {
        let provider = CachedDataProvider(cached: ["WIFI": security("WIFI")], context: context(),
                                          tickers: ["WIFI"])
        let data = try await provider.data(for: "WIFI")
        #expect(data.ticker == "WIFI")
    }

    @Test func missThrowsNotCachedSoTheEngineSkipsIt() async {
        let provider = CachedDataProvider(cached: [:], context: context(), tickers: ["BBCA"])
        await #expect(throws: SelectionProviderError.notCached("BBCA")) {
            _ = try await provider.data(for: "BBCA")
        }
    }

    @Test func missingContextRefusesToScore() async {
        let provider = CachedDataProvider(cached: ["WIFI": security("WIFI")], context: nil,
                                          tickers: ["WIFI"])
        await #expect(throws: SelectionProviderError.noRegimeInputs) {
            _ = try await provider.marketContext()
        }
    }

    // The bug this whole change fixes: the engine must rank from cache without ever fetching. With an
    // empty cache it skips every candidate (a SKIP, never a stall) and ranks nothing — instead of the
    // old per-symbol live fan-out that left the screen on "Sizing today's actions…".
    @Test func engineOverEmptyCacheSkipsEveryNameInsteadOfFetching() async throws {
        let provider = CachedDataProvider(cached: [:], context: context(), tickers: ["WIFI", "BBCA"])
        let engine = StockSelectionEngine(provider: provider, config: .balanced)
        let collector = SkipCollector()
        let recs = try await engine.run { collector.add($0) }
        #expect(recs.isEmpty)
        #expect(Set(collector.all.map(\.ticker)) == ["WIFI", "BBCA"])
    }
}
