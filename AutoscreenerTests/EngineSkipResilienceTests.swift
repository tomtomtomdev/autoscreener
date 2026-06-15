import Foundation
import Testing
@testable import Autoscreener

// MARK: - Regression: a single un-valuable name must NOT abort the whole Recommendations run.
//
// Bug: `StockSelectionEngine.run()` called `try await provider.data(for:)` with no catch, so one
// ticker whose fundamentals are missing (`SelectionFundamentals.AdapterError`) — or whose price feed
// is empty (`SelectionProviderError.noPriceData`) — threw all the way out of `run()`, emptying the
// Recommendations screen with "…AdapterError error 0". The engine must instead SKIP that name
// (reporting it via `onSkip`) and keep ranking the rest, while a genuine infrastructure error
// (e.g. `URLError`) still propagates so a real outage surfaces rather than masquerading as "no picks".

private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}

private let oneB: Decimal = 1_000_000_000

private func bars(count: Int = 250, close: Decimal = 1000) -> [OHLCV] {
    (0..<count).map { _ in
        OHLCV(date: Date(timeIntervalSince1970: 0), open: close, high: close, low: close,
              close: close, volume: 1000, value: 10_000_000_000)
    }
}

/// A plain, valuable industrial — enough to reach the engine without throwing (whether it clears the
/// gates is irrelevant to this suite; we only care that `run()` does not abort).
private func validSecurity(_ ticker: Ticker) -> SecurityData {
    let ttm = TTMFinancials(eps: 100, bookValuePerShare: 500, netIncome: 100 * oneB,
                            operatingCashFlow: 120 * oneB, totalAssets: 1_000 * oneB,
                            epsGrowthPct: 10, currentRatio: 2.0, debtToEquity: 0.5, returnOnEquity: 0.18)
    let annuals = (0..<5).map { i in
        AnnualFinancials(year: 2021 + i, revenue: 800 * oneB, netIncome: 100 * oneB,
                         operatingCashFlow: 120 * oneB, totalAssets: 1_000 * oneB,
                         totalLiabilities: 400 * oneB, currentAssets: 600 * oneB,
                         currentLiabilities: 300 * oneB, shareholderEquity: 600 * oneB,
                         receivables: 100 * oneB, sharesOutstanding: oneB)
    }
    return SecurityData(ticker: ticker, sector: "Industrials", price: 1000, sharesOutstanding: oneB,
                        freeFloatPct: 0.40, financials: annuals, ttm: ttm, dailyBars: bars(),
                        foreignNetFlow: [], brokerAccumulationSignal: 0,
                        sectorIndexBars: bars(), marketIndexBars: bars())
}

/// Provider whose `data(for:)` throws a per-ticker error for tickers in `failures`, and returns a
/// valuable security for the rest. `order` is the universe.
private struct PartiallyFailingProvider: DataProvider {
    let order: [Ticker]
    let failures: [Ticker: any Error]
    func universe() async throws -> [Ticker] { order }
    func data(for t: Ticker) async throws -> SecurityData {
        if let e = failures[t] { throw e }
        return validSecurity(t)
    }
    func marketContext() async throws -> MarketContext { neutralContext() }
}

@Suite struct EngineSkipResilienceTests {

    @Test func skipsANameWithMissingFundamentalsAndKeepsRunning() async throws {
        let provider = PartiallyFailingProvider(
            order: ["GOOD1", "BAD", "GOOD2"],
            failures: ["BAD": SelectionFundamentals.AdapterError.missingField(id: "1498", name: "Current Ratio")])
        let engine = StockSelectionEngine(provider: provider, config: .balanced)

        var skipped: [SkippedName] = []
        // Must not throw — the bad name is skipped, not fatal.
        _ = try await engine.run { skipped.append($0) }

        #expect(skipped.map(\.ticker) == ["BAD"])
        #expect(skipped.first?.reason.contains("Current Ratio") == true)
    }

    @Test func skipsANameWithNoPriceData() async throws {
        let provider = PartiallyFailingProvider(
            order: ["GOOD", "NOPRICE"],
            failures: ["NOPRICE": SelectionProviderError.noPriceData("NOPRICE")])
        let engine = StockSelectionEngine(provider: provider, config: .balanced)

        var skipped: [SkippedName] = []
        _ = try await engine.run { skipped.append($0) }

        #expect(skipped.map(\.ticker) == ["NOPRICE"])
    }

    @Test func infrastructureErrorStillPropagates() async throws {
        let provider = PartiallyFailingProvider(
            order: ["GOOD", "DOWN"],
            failures: ["DOWN": URLError(.notConnectedToInternet)])
        let engine = StockSelectionEngine(provider: provider, config: .balanced)

        await #expect(throws: URLError.self) {
            _ = try await engine.run()
        }
    }
}
