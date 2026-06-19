import Foundation
import Testing
@testable import Autoscreener

// MARK: - Phase 4.1 (INTEGRATION.md §8 / §13-A2): measured betas via rolling regression.
//
// The timing modifier used hardcoded placeholder betas (marketBeta 1.0 / sectorBeta 0.5) applied to
// every name. §13-A2 calls for "a rolling regression per name" against each security's own bars.
// `FactorRegression.betas` is that regression: a no-intercept two-factor OLS over the most-recent
// daily returns, decomposing the stock's return into a market loading and a sector-excess loading —
//
//     stockReturn ≈ βmarket · marketReturn  +  βsector · (sectorReturn − marketReturn)
//
// — exactly the factor model the timing modifier's `idio` residual assumes. It returns nil (→ the
// caller falls back to the configured placeholders) when the data is insufficient or degenerate
// (a factor has no variance, or the two factors are collinear). The numbers below are hand-derived
// from the synthetic series, not copied from a run (Beck: Evident Data).

private let fixedDate = Date(timeIntervalSince1970: 0)

/// Build a bar series whose close-to-close returns reproduce `rs` (N returns → N+1 bars). Only `close`
/// matters to the regression; the other fields are filler.
private func bars(fromReturns rs: [Double], start: Double = 100) -> [OHLCV] {
    var close = start
    var out: [OHLCV] = [OHLCV(date: fixedDate, open: Decimal(close), high: Decimal(close),
                              low: Decimal(close), close: Decimal(close), volume: 0, value: 0)]
    for r in rs {
        close *= (1 + r)
        out.append(OHLCV(date: fixedDate, open: Decimal(close), high: Decimal(close),
                         low: Decimal(close), close: Decimal(close), volume: 0, value: 0))
    }
    return out
}

/// Two clearly-independent factor return series (periods 5 and 7 → not collinear), 42 observations.
private let marketReturns: [Double] = (0..<42).map { Double($0 % 5 - 2) * 0.01 }   // cycles −0.02…0.02
private let sectorReturns: [Double] = (0..<42).map { Double($0 % 7 - 3) * 0.01 }   // cycles −0.03…0.03

@Suite struct FactorRegressionTests {

    @Test func recoversKnownTwoFactorBetas() {
        // Stock return is EXACTLY βm·market + βs·(sector − market) with βm = 1.2, βs = 0.4.
        let bm = 1.2, bs = 0.4
        let stockReturns = zip(marketReturns, sectorReturns).map { m, s in bm * m + bs * (s - m) }
        let result = FactorRegression.betas(stock: bars(fromReturns: stockReturns),
                                            market: bars(fromReturns: marketReturns),
                                            sector: bars(fromReturns: sectorReturns),
                                            lookback: 252)
        let r = try? #require(result)
        #expect(abs((r?.market ?? .nan) - bm) < 1e-4)
        #expect(abs((r?.sector ?? .nan) - bs) < 1e-4)
    }

    @Test func recoversMarketBetaWhenStockHasNoSectorLoading() {
        // Stock = 0.8·market, no sector-excess loading → βm ≈ 0.8, βs ≈ 0.
        let stockReturns = marketReturns.map { 0.8 * $0 }
        let r = try? #require(FactorRegression.betas(stock: bars(fromReturns: stockReturns),
                                                     market: bars(fromReturns: marketReturns),
                                                     sector: bars(fromReturns: sectorReturns),
                                                     lookback: 252))
        #expect(abs((r?.market ?? .nan) - 0.8) < 1e-4)
        #expect(abs(r?.sector ?? .nan) < 1e-4)
    }

    @Test func returnsNilForFlatSeries() {
        // The golden-master case: flat prices → zero-variance factors → degenerate → nil → fallback.
        let flat = bars(fromReturns: Array(repeating: 0.0, count: 42))
        #expect(FactorRegression.betas(stock: flat, market: flat, sector: flat, lookback: 252) == nil)
    }

    @Test func returnsNilForCollinearFactors() {
        // Sector index identical to the market index → sector-excess is identically zero → the two
        // factors are collinear → the regression is singular → nil.
        let market = bars(fromReturns: marketReturns)
        let stock = bars(fromReturns: marketReturns.map { 1.1 * $0 })
        #expect(FactorRegression.betas(stock: stock, market: market, sector: market, lookback: 252) == nil)
    }

    @Test func returnsNilForInsufficientObservations() {
        // Fewer than the minimum observations needed for a stable beta → nil.
        let short = Array(marketReturns.prefix(10))
        #expect(FactorRegression.betas(stock: bars(fromReturns: short.map { 1.2 * $0 }),
                                       market: bars(fromReturns: short),
                                       sector: bars(fromReturns: Array(sectorReturns.prefix(10))),
                                       lookback: 252) == nil)
    }

    @Test func lookbackTrimsToTheMostRecentObservations() {
        // A long history whose OLDEST half loads differently from the recent half: with a short
        // lookback only the recent loading (βm 2.0) is measured, proving the window trims by recency.
        let old = (0..<40).map { Double($0 % 5 - 2) * 0.01 }
        let recent = (0..<40).map { Double($0 % 5 - 2) * 0.01 }
        let market = old + recent
        let sector = (0..<80).map { Double($0 % 7 - 3) * 0.01 }
        // Oldest 40 stock returns load market at 0.5; the most-recent 40 load it at 2.0 (sector flat-loaded 0).
        let stock = zip(market, sector).enumerated().map { i, ms in (i < 40 ? 0.5 : 2.0) * ms.0 }
        let r = try? #require(FactorRegression.betas(stock: bars(fromReturns: stock),
                                                     market: bars(fromReturns: market),
                                                     sector: bars(fromReturns: sector),
                                                     lookback: 35))
        #expect(abs((r?.market ?? .nan) - 2.0) < 1e-3)
    }
}

// MARK: - Modifiers.timing wiring: uses measured betas, falls back + labels the source.

@Suite struct TimingModifierBetaTests {
    private func security(stock: [Double], market: [Double], sector: [Double]) -> SecurityData {
        let ttm = TTMFinancials(eps: 100, bookValuePerShare: 500, netIncome: 0, operatingCashFlow: 0,
                                totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                                returnOnEquity: 0)
        return SecurityData(ticker: "X", sector: "Industrials", price: 100, sharesOutstanding: 0,
                            freeFloatPct: 0, financials: [], ttm: ttm,
                            dailyBars: bars(fromReturns: stock), foreignNetFlow: [],
                            brokerAccumulationSignal: 0,
                            sectorIndexBars: bars(fromReturns: sector),
                            marketIndexBars: bars(fromReturns: market))
    }

    @Test func usesAndReportsMeasuredBetasWhenBarsHaveVariance() {
        let stock = zip(marketReturns, sectorReturns).map { m, s in 1.2 * m + 0.4 * (s - m) }
        let (_, why) = Modifiers.smartMoneyMomentum(security(stock: stock, market: marketReturns, sector: sectorReturns),
                                                    leaders: nil, config: .balanced)
        #expect(why.contains("measured"))
        #expect(why.contains("β 1.20/0.40"))
    }

    @Test func fallsBackToConfigBetasOnFlatBars() {
        let flat = Array(repeating: 0.0, count: 42)
        let (mod, why) = Modifiers.smartMoneyMomentum(security(stock: flat, market: flat, sector: flat), leaders: nil, config: .balanced)
        #expect(mod == 0)
        #expect(why.contains("default"))
        #expect(why.contains("β 1.00/0.50"))   // the configured .balanced placeholders
    }
}
