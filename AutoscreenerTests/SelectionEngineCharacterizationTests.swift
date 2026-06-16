import Foundation
import Testing
@testable import Autoscreener

// MARK: - Characterization tests for the vendored StockSelectionEngine.
//
// Phase 0.1 of INTEGRATION.md drops StockSelectionEngine.swift / BacktestHarness.swift
// into the app target verbatim. These tests pin the engine's CURRENT behaviour against a
// deterministic in-memory `DataProvider` stub so that the Phase 2 archetype refactor
// ("industrial path byte-for-byte unchanged") has a golden-master baseline to verify against.
// The expected numbers below are hand-derived from the formulas, not copied from a run.

// MARK: - Verdict helpers (Verdict isn't Equatable)

private func failReason(_ v: Verdict) -> String? {
    if case let .fail(reason) = v { return reason }
    return nil
}
private func isPass(_ v: Verdict) -> Bool {
    if case .pass = v { return true }
    return false
}

// MARK: - Object Mother

private let fixedDate = Date(timeIntervalSince1970: 0)

private func flatBars(count: Int, close: Decimal = 1000, value: Decimal) -> [OHLCV] {
    (0..<count).map { _ in
        OHLCV(date: fixedDate, open: close, high: close, low: close, close: close,
              volume: 1000, value: value)
    }
}

/// Five clean years: margin a flat 10% (consistency = 1), net income strictly rising
/// (monotone up), CFO a steady 1.2× NI (CFO/NI = 1.2), receivables flat, and a consistent balance
/// sheet (current assets 1,500B ≤ total assets 3,000B; equity = TA − TL) whose NCAV is negative
/// (CA 1,500B < total liabilities 2,000B), so the earnings-based Graham number (≈2,012) is the binding
/// intrinsic value.
private func defaultFinancials() -> [AnnualFinancials] {
    let b: Decimal = 1_000_000_000
    let nis: [Decimal] = [100, 110, 120, 130, 140].map { Decimal($0) * b }
    let revs: [Decimal] = [1000, 1100, 1200, 1300, 1400].map { Decimal($0) * b }
    let cfos: [Decimal] = [120, 132, 144, 156, 168].map { Decimal($0) * b }   // 1.2× NI
    return (0..<5).map { i in
        AnnualFinancials(
            year: 2021 + i,
            revenue: revs[i], netIncome: nis[i], operatingCashFlow: cfos[i],
            totalAssets: Decimal(3_000) * b, totalLiabilities: Decimal(2_000) * b,
            currentAssets: Decimal(1_500) * b, currentLiabilities: Decimal(1_000) * b,
            shareholderEquity: Decimal(1_000) * b, receivables: Decimal(50) * b,
            sharesOutstanding: b)
    }
}

private func makeSecurity(
    ticker: Ticker = "GOOD",
    sector: String = "Industrials",
    price: Decimal = 1000,
    eps: Decimal = 150,
    bvps: Decimal = 1200,
    freeFloat: Ratio = 0.40,
    currentRatio: Double = 2.0,
    debtToEquity: Double = 0.5,
    roe: Double = 0.20,
    epsGrowthPct: Double = 15.0,
    barCount: Int = 250,
    barValue: Decimal = 10_000_000_000,
    financials: [AnnualFinancials] = defaultFinancials()
) -> SecurityData {
    let ttm = TTMFinancials(
        eps: eps, bookValuePerShare: bvps,
        netIncome: Decimal(140) * 1_000_000_000, operatingCashFlow: Decimal(168) * 1_000_000_000,
        totalAssets: Decimal(2_000) * 1_000_000_000,
        epsGrowthPct: epsGrowthPct, currentRatio: currentRatio,
        debtToEquity: debtToEquity, returnOnEquity: roe)
    return SecurityData(
        ticker: ticker, sector: sector, price: price,
        sharesOutstanding: 1_000_000_000, freeFloatPct: freeFloat,
        financials: financials, ttm: ttm,
        dailyBars: flatBars(count: barCount, value: barValue),
        foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: flatBars(count: barCount, value: 1),
        marketIndexBars: flatBars(count: barCount, value: 1))
}

private struct StubDataProvider: DataProvider {
    var securities: [Ticker: SecurityData]
    var context: MarketContext
    var tickers: [Ticker]
    func universe() async throws -> [Ticker] { tickers }
    func data(for t: Ticker) async throws -> SecurityData { securities[t]! }
    func marketContext() async throws -> MarketContext { context }
}

private func provider(_ s: SecurityData, context: MarketContext) -> StubDataProvider {
    StubDataProvider(securities: [s.ticker: s], context: context, tickers: [s.ticker])
}

// MARK: - MarketContext mothers (risk scores hand-computed against .balanced weights)

/// risk = 0.2·1.0 + (1−0.8)·0.5 = 0.30  → < riskOnMax(0.6) → riskOn
private func riskOnContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.2, breadthAbove200dma: 0.8, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}
/// risk = 0.5·1.0 + (1−0.6)·0.5 = 0.70  → in [0.6, 1.1) → neutral (empty weightTilt)
private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}
/// risk = 1.0 + 0.25 + 0.5 + 0.25 + 0.15 + 0.25 + 0.10 = 2.50  → ≥ neutralMax(1.1) → riskOff
private func riskOffContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 1.0, breadthAbove200dma: 0.0, indexAbove200dma: false,
                  idrWeakeningTrend: true, biRateRising: true, marketForeignFlowNet: -1,
                  commodityTailwind: false)
}

// MARK: - Regime assessor (pure)

@Suite struct RegimeAssessorCharacterizationTests {
    @Test func lowRiskContextSelectsRiskOnPolicy() {
        let p = RegimeAssessor.assess(riskOnContext(), config: .balanced)
        #expect(p.regime == .riskOn)
        #expect(p.minMarginOfSafety == 0.20)
    }
    @Test func midRiskContextSelectsNeutralPolicy() {
        let p = RegimeAssessor.assess(neutralContext(), config: .balanced)
        #expect(p.regime == .neutral)
        #expect(p.minMarginOfSafety == 0.30)
        #expect(p.weightTilt.isEmpty)
    }
    @Test func highRiskContextSelectsRiskOffPolicy() {
        let p = RegimeAssessor.assess(riskOffContext(), config: .balanced)
        #expect(p.regime == .riskOff)
        #expect(p.minMarginOfSafety == 0.45)
    }
}

// MARK: - Hard gates (each returns a stable failure reason)

@Suite struct GateCharacterizationTests {
    private let neutral = RegimeAssessor.assess(neutralContext(), config: .balanced)

    @Test func cleanSecurityPassesEveryGate() {
        let s = makeSecurity()
        for g in [DataIntegrityGate() as Gate, LiquidityGate(), ForensicGate(), SolvencyGate()] {
            #expect(isPass(g.evaluate(s, config: .balanced, policy: neutral)), "\(g.name) should pass")
        }
    }
    @Test func dataIntegrityFailsOnTooFewBars() {
        let s = makeSecurity(barCount: 100)
        #expect(failReason(DataIntegrityGate().evaluate(s, config: .balanced, policy: neutral)) == "<200 bars")
    }
    @Test func dataIntegrityFailsOnTooFewFinancialYears() {
        let s = makeSecurity(financials: Array(defaultFinancials().prefix(3)))
        #expect(failReason(DataIntegrityGate().evaluate(s, config: .balanced, policy: neutral)) == "<5y financials")
    }
    @Test func liquidityFailsOnThinFreeFloat() {
        let s = makeSecurity(freeFloat: 0.05)
        #expect(failReason(LiquidityGate().evaluate(s, config: .balanced, policy: neutral)) == "low free float")
    }
    @Test func liquidityFailsOnThinADV() {
        let s = makeSecurity(barValue: 1_000_000_000)   // 1B ADV < 5B floor
        #expect(failReason(LiquidityGate().evaluate(s, config: .balanced, policy: neutral)) == "thin ADV")
    }
    @Test func solvencyFailsOnLowCurrentRatio() {
        let s = makeSecurity(currentRatio: 0.5)
        #expect(failReason(SolvencyGate().evaluate(s, config: .balanced, policy: neutral)) == "current ratio low")
    }
    @Test func solvencyFailsOnHighDebtToEquity() {
        let s = makeSecurity(debtToEquity: 3.0)
        #expect(failReason(SolvencyGate().evaluate(s, config: .balanced, policy: neutral)) == "D/E high")
    }

    // MARK: - Regression: sector-aware current-ratio floor (selection-gate-strictness bug #3).
    //
    // Graham's current-ratio ≥ floor is an industrial-economy liquidity test. The negative-working-capital
    // business models — telco/utilities/regulated (IDX-IC "Infrastruktur") and supplier-financed
    // staples/retail ("Barang Konsumen Primer" / "Barang Konsumen Non-Primer") — run a current ratio < 1
    // BY DESIGN yet are sound; the flat 1.0 floor false-failed them before they were ever scored. Graham
    // himself exempts "utilities/regulated firms" from the ratio and warns the 1930s thresholds break for
    // modern asset-light businesses (graham-financial-statements). Those sectors are exempt here; leverage
    // is still gated for EVERY name by the debt-to-equity check, so the exemption never blanket-passes an
    // over-levered company.

    /// THE BUG: a sound telco/utility-type name ("Infrastruktur") with a by-design current ratio of 0.6
    /// and healthy leverage. The flat floor failed it ("current ratio low"); the sector exemption now lets
    /// it through to scoring.
    @Test func negativeWorkingCapitalSectorIsExemptFromTheCurrentRatioFloor() {
        let s = makeSecurity(sector: "Infrastruktur", currentRatio: 0.6, debtToEquity: 0.8)
        #expect(isPass(SolvencyGate().evaluate(s, config: .balanced, policy: neutral)))
    }

    /// No-regression: the exemption is sector-scoped. A non-exempt industrial with the same low current
    /// ratio still fails — the flat floor stands for the businesses Graham's liquidity test is meant for.
    @Test func nonExemptSectorStillFailsOnLowCurrentRatio() {
        let s = makeSecurity(sector: "Perindustrian", currentRatio: 0.6)
        #expect(failReason(SolvencyGate().evaluate(s, config: .balanced, policy: neutral)) == "current ratio low")
    }

    /// No-regression: the exemption removes only the current-ratio test, never the leverage guard. An
    /// exempt-sector name that is genuinely over-levered still fails on debt-to-equity.
    @Test func exemptSectorStillFailsOnHighDebtToEquity() {
        let s = makeSecurity(sector: "Infrastruktur", currentRatio: 0.6, debtToEquity: 3.0)
        #expect(failReason(SolvencyGate().evaluate(s, config: .balanced, policy: neutral)) == "D/E high")
    }
}

// MARK: - Full pipeline golden master

@Suite struct SelectionEnginePipelineGoldenMaster {

    @Test func balancedConfigRecommendsTheCleanCheapName() async throws {
        let engine = StockSelectionEngine(provider: provider(makeSecurity(), context: neutralContext()),
                                          config: .balanced)
        let recs = try await engine.run()

        #expect(recs.count == 1)
        let r = try #require(recs.first)
        #expect(r.ticker == "GOOD")
        #expect(abs(r.compositeScore - 0.850823) < 1e-4)
        #expect(abs(r.conviction - 0.850823) < 1e-4)
        #expect(abs(r.marginOfSafety - 0.503096) < 1e-3)
        #expect(abs(r.intrinsicValue - 2012.4612) < 1e-1)
        #expect(abs(r.suggestedWeight - 0.0850823) < 1e-4)
    }

    @Test func auditTrailIsTheGoldenSnapshot() async throws {
        let engine = StockSelectionEngine(provider: provider(makeSecurity(), context: neutralContext()),
                                          config: .balanced)
        let r = try #require(try await engine.run().first)
        let expected = [
            "regime=neutral",
            "✓ DataIntegrity",
            "✓ Liquidity",
            "✓ Forensic",
            "✓ Solvency",
            "MoS 50% vs req 30%",
            "GrahamValue 0.89 — GrahamNo 2012 MoS 50% · P/B 0.83",
            "Quality 0.83 — ROE 20% · margin-stable",
            "GrowthLynch 0.70 — PEG 0.44 (P/E 6.67 g 15.0%)",
            "EarningsQuality 1.00 — CFO/NI 1.20",
            "flow +0.000 [foreign + · broker 0.00]",
            // Phase 4.1 (§13-A2): the timing rationale now surfaces the betas it used. Flat golden-
            // master bars are degenerate for the regression, so it falls back to the configured
            // placeholders (1.00/0.50) and labels them "default" — the +0.000 modifier is unchanged.
            "timing +0.000 [idio 0% · ext 0% · β 1.00/0.50 default]",
            "→ conviction 0.85 weight 9%",
        ]
        #expect(r.audit == expected)
    }

    @Test func nameFailingTheMoSGateIsNotRecommended() async throws {
        // Same clean name but expensive (price above the Graham number) → negative MoS, screened out.
        let expensive = makeSecurity(price: 3000)
        let engine = StockSelectionEngine(provider: provider(expensive, context: neutralContext()),
                                          config: .balanced)
        #expect(try await engine.run().isEmpty)
    }
}
