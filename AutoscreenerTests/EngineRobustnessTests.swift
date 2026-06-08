import Foundation
import Testing
@testable import Autoscreener

// MARK: - Phase 4.2 (INTEGRATION.md §8 / §13-A3): null / loss-maker robustness sweep.
//
// §13-A3: "Many keystats fields can be '-' … every gate/scorer must be null-safe, not coerce to 0."
// The adapters (Phase 1) already throw on a missing ESSENTIAL field and degrade BEST-EFFORT ones to 0,
// so the values that actually reach the engine are: zeros (degraded fields), negatives (loss-makers),
// and empty arrays (short history). This sweep feeds those realistic pathological shapes through BOTH
// archetype profiles' gates, scorers, valuators, and the full `engine.run()`, and pins the invariants
// that must hold no matter how ugly the input is:
//
//   • no crash / trap / precondition failure (the test running to completion is the proof);
//   • every scorer returns a FINITE value in [0, 1] — never NaN, never ±∞;
//   • every valuator returns a finite intrinsic value ≥ 0 and a finite margin of safety;
//   • every recommendation has a finite composite/conviction/MoS/IV and a weight in [0, maxPosition].
//
// (`price` is sourced from the last daily bar and is essential — the provider throws `noPriceData`
// rather than emit a zero price — so a "free" stock is unreachable and is not exercised here.)

private let fixedDate = Date(timeIntervalSince1970: 0)

private func bars(count: Int = 250, close: Decimal = 1000, value: Decimal = 10_000_000_000) -> [OHLCV] {
    (0..<count).map { _ in
        OHLCV(date: fixedDate, open: close, high: close, low: close, close: close, volume: 1000, value: value)
    }
}

private let oneB: Decimal = 1_000_000_000

/// Five years of negative, deepening losses with negative operating cash flow — a textbook loss-maker.
private func lossFinancials() -> [AnnualFinancials] {
    let nis: [Decimal] = [-50, -70, -90, -110, -140].map { $0 * oneB }
    let cfos: [Decimal] = [-40, -60, -80, -100, -130].map { $0 * oneB }
    return (0..<5).map { i in
        AnnualFinancials(year: 2021 + i, revenue: 800 * oneB, netIncome: nis[i], operatingCashFlow: cfos[i],
                         totalAssets: 2_000 * oneB, totalLiabilities: 2_500 * oneB,
                         currentAssets: 300 * oneB, currentLiabilities: 900 * oneB,
                         shareholderEquity: -500 * oneB, receivables: 200 * oneB, sharesOutstanding: oneB)
    }
}

private func industrial(sector: String = "Industrials", price: Decimal = 1000, eps: Decimal = -50,
                        bvps: Decimal = 300, roe: Double = -0.10, epsGrowthPct: Double = -20,
                        currentRatio: Double = 0.4, debtToEquity: Double = 5.0,
                        shares: Decimal = oneB, financials: [AnnualFinancials] = lossFinancials())
    -> SecurityData {
    let ttm = TTMFinancials(eps: eps, bookValuePerShare: bvps, netIncome: -140 * oneB,
                            operatingCashFlow: -130 * oneB, totalAssets: 2_000 * oneB,
                            epsGrowthPct: epsGrowthPct, currentRatio: currentRatio,
                            debtToEquity: debtToEquity, returnOnEquity: roe)
    return SecurityData(ticker: "BAD", sector: sector, price: price, sharesOutstanding: shares,
                        freeFloatPct: 0.40, financials: financials, ttm: ttm, dailyBars: bars(),
                        foreignNetFlow: [], brokerAccumulationSignal: 0,
                        sectorIndexBars: bars(value: 1), marketIndexBars: bars(value: 1))
}

/// Bank with the current/non-current/receivable fields and (optionally) ROE/ROA/payout all degraded to
/// 0 — exactly what the adapter emits when keystats returns "-" for a financial (§13-A1/A3).
private func bank(price: Decimal = 5000, bvps: Decimal = 2000, totalAssets: Decimal = 1_640_831 * oneB,
                  roe: Double = 0, roa: Double = 0, payout: Double = 0, shares: Decimal = 100 * oneB,
                  financials: [AnnualFinancials]? = nil) -> SecurityData {
    let fins = financials ?? (0..<5).map { i in
        AnnualFinancials(year: 2021 + i, revenue: 0, netIncome: 40 * oneB, operatingCashFlow: 40 * oneB,
                         totalAssets: totalAssets, totalLiabilities: 0, currentAssets: 0,
                         currentLiabilities: 0, shareholderEquity: 200 * oneB, receivables: 0,
                         sharesOutstanding: 0)
    }
    let ttm = TTMFinancials(eps: 100, bookValuePerShare: bvps, netIncome: 40 * oneB,
                            operatingCashFlow: 40 * oneB, totalAssets: totalAssets, epsGrowthPct: 0,
                            currentRatio: 0, debtToEquity: 0, returnOnEquity: roe,
                            payoutRatio: payout, returnOnAssets: roa)
    return SecurityData(ticker: "BANK", sector: "Keuangan", price: price, sharesOutstanding: shares,
                        freeFloatPct: 0.40, financials: fins, ttm: ttm, dailyBars: bars(value: 50 * oneB),
                        foreignNetFlow: [], brokerAccumulationSignal: 0,
                        sectorIndexBars: bars(value: 1), marketIndexBars: bars(value: 1))
}

/// The pathological shapes the adapters can realistically hand the engine. Each builds its own
/// `SecurityData`; the enum is the parameter set so one assertion body covers them all.
enum PathologicalCase: String, CaseIterable, Sendable, CustomStringConvertible {
    case lossMakerIndustrial, zeroBookValueIndustrial, emptyFinancialsIndustrial, zeroSharesIndustrial
    case degradedBank, lossMakerBank, zeroAssetsBank, zeroBookValueBank
    var description: String { rawValue }

    var security: SecurityData {
        switch self {
        case .lossMakerIndustrial:       return industrial()
        case .zeroBookValueIndustrial:   return industrial(bvps: 0)
        case .emptyFinancialsIndustrial: return industrial(eps: 100, bvps: 1200, roe: 0.2, financials: [])
        case .zeroSharesIndustrial:      return industrial(eps: 100, bvps: 1200, roe: 0.2, shares: 0)
        case .degradedBank:              return bank()                          // ROE/ROA/payout all 0
        case .lossMakerBank:             return bank(roe: -0.05)
        case .zeroAssetsBank:            return bank(totalAssets: 0, roe: 0.18)
        case .zeroBookValueBank:         return bank(bvps: 0, roe: 0.18)
        }
    }
}

private func isFinite01(_ x: Double) -> Bool { x.isFinite && x >= 0 && x <= 1 }

private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}
private let neutralPolicy = RegimeAssessor.assess(neutralContext(), config: .balanced)

private struct StubProvider: DataProvider {
    let security: SecurityData
    func universe() async throws -> [Ticker] { [security.ticker] }
    func data(for t: Ticker) async throws -> SecurityData { security }
    func marketContext() async throws -> MarketContext { neutralContext() }
}

@Suite struct EngineRobustnessSweep {

    // Each pathological name is routed to its OWN archetype profile (industrial vs financial), then
    // every gate/scorer/valuator in that profile is exercised directly — independent of whether the
    // gates would screen the name — so the scoring math itself is proven null-safe.
    @Test(arguments: PathologicalCase.allCases)
    func everyProfileStageStaysFiniteAndInRange(_ c: PathologicalCase) {
        let s = c.security
        let profile = StockSelectionEngine.defaultProfile(for: s, config: .balanced)

        for gate in profile.gates {
            // Exercising the gate must not crash; a fail must carry a non-empty reason.
            if case let .fail(reason) = gate.evaluate(s, config: .balanced, policy: neutralPolicy) {
                #expect(!reason.isEmpty, "\(c).\(gate.name) failed with an empty reason")
            }
        }
        for scorer in profile.scorers {
            let v = scorer.score(s, config: .balanced).value
            #expect(isFinite01(v), "\(c).\(scorer.id.rawValue) produced \(v) — not finite in [0,1]")
        }
        let iv = profile.valuator.intrinsicValue(s, config: .balanced)
        #expect(iv.isFinite && iv >= 0, "\(c) intrinsic value \(iv) — not finite & non-negative")
        #expect(profile.valuator.marginOfSafety(s, config: .balanced).isFinite, "\(c) MoS not finite")
    }

    // The whole pipeline over each pathological name must never emit a garbage recommendation: every
    // output number is finite and within its natural bounds (composite in [0,1], weight ≤ maxPosition).
    @Test(arguments: PathologicalCase.allCases)
    func engineRunNeverEmitsAGarbageRecommendation(_ c: PathologicalCase) async throws {
        let engine = StockSelectionEngine(provider: StubProvider(security: c.security), config: .balanced)
        for r in try await engine.run() {
            #expect(isFinite01(r.compositeScore), "\(c) composite \(r.compositeScore)")
            #expect(isFinite01(r.conviction), "\(c) conviction \(r.conviction)")
            #expect(r.marginOfSafety.isFinite, "\(c) MoS \(r.marginOfSafety)")
            #expect(r.intrinsicValue.isFinite && r.intrinsicValue >= 0, "\(c) IV \(r.intrinsicValue)")
            #expect(r.suggestedWeight.isFinite && r.suggestedWeight >= 0
                    && r.suggestedWeight <= neutralPolicy.maxPositionPct, "\(c) weight \(r.suggestedWeight)")
        }
    }
}
