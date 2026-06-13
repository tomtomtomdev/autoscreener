import Foundation
import Testing
@testable import Autoscreener

// MARK: - Gate-5 exit/sell discipline — ExitEvaluator + PositionReviewer
//
// Test List (Kent Beck canon — one behaviour per test, simplest first):
//   1. healthy intact name                         → .hold            (starter)
//   2. Forensic gate now fails (CFO << NI)          → .exit            (deterioration)
//   3. Solvency gate now fails (current ratio)      → .exit            (deterioration)
//   4. concern-severity insider-selling flag        → .exit            (Gate-2 integrity)
//   5. concern-severity dilution flag               → .exit            (Gate-2 integrity)
//   6. watch-severity flag only                     → .hold            (NOT a veto)
//   7. price ran ≥30% past intrinsic value          → .exit            (Graham valuation)
//   8. deep drawdown, gates pass, price < IV         → .hold           (Fisher non-trigger; cost ignored)
//   9. price ABOVE IV but within the −30% band       → .hold           (Fisher: a price rise alone ≠ sell)
//  10. loss-maker, no computable value (IV 0)        → .exit           (earnings power gone)
//  11. honorHardGates = false                        → gate fail ignored
//  12. honorGovernanceVeto = false                   → concern flag ignored
//  13. bank: CapitalStrength gate fails              → .exit           (financial-profile routing)
//  14. deep risk-off (target exposure 0)             → .trim           (regime)
//  15. PositionReviewer end-to-end over a mixed book → maps each name's decision

// MARK: - Object Mother (Fresh Fixture; tuned to the .balanced thresholds)

private let B: Decimal = 1_000_000_000
private let day = Date(timeIntervalSince1970: 0)

private func bars(_ n: Int, value: Decimal = 10_000_000_000) -> [OHLCV] {
    (0..<n).map { _ in
        OHLCV(date: day, open: 1000, high: 1000, low: 1000, close: 1000, volume: 1000, value: value)
    }
}

/// `years` clean annual statements. CFO defaults to 1.2× NI (passes Forensic); flat revenue and
/// receivables (no receivables-vs-revenue flag). Knobs let a single test deteriorate one dimension.
private func makeFinancials(
    years: Int = 5,
    netIncome: Decimal = 100,        // billions; positive ⇒ profitable
    cfoMultiple: Double = 1.2,
    revenue: Decimal = 1000,         // billions, flat
    currentAssets: Decimal = 4500,   // billions
    totalLiabilities: Decimal = 2000 // billions  (NCAV/share = (CA − TL)/shares)
) -> [AnnualFinancials] {
    let cfo = netIncome * Decimal(cfoMultiple)
    return (0..<years).map { i in
        AnnualFinancials(
            year: 2021 + i,
            revenue: revenue * B, netIncome: netIncome * B, operatingCashFlow: cfo * B,
            totalAssets: 3000 * B, totalLiabilities: totalLiabilities * B,
            currentAssets: currentAssets * B, currentLiabilities: 1000 * B,
            shareholderEquity: 1000 * B, receivables: 50 * B,
            sharesOutstanding: B)
    }
}

private func makeSecurity(
    ticker: Ticker = "HELD",
    sector: String = "Industrials",
    price: Decimal = 1000,
    eps: Decimal = 150,
    bvps: Decimal = 1200,
    roe: Double = 0.20,
    payout: Double = 0.30,
    currentRatio: Double = 2.0,
    debtToEquity: Double = 0.5,
    sharesOutstanding: Decimal = 1_000_000_000,
    totalAssetsTTM: Decimal = 2_000_000_000_000,   // 2,000 B
    barCount: Int = 250,
    barValue: Decimal = 10_000_000_000,
    financials: [AnnualFinancials] = makeFinancials(),
    governance: GovernanceAssessment? = nil
) -> SecurityData {
    let ttm = TTMFinancials(
        eps: eps, bookValuePerShare: bvps,
        netIncome: 100 * B, operatingCashFlow: 120 * B, totalAssets: totalAssetsTTM,
        epsGrowthPct: 12.0, currentRatio: currentRatio, debtToEquity: debtToEquity,
        returnOnEquity: roe, payoutRatio: payout, returnOnAssets: 0.03)
    return SecurityData(
        ticker: ticker, sector: sector, price: price,
        sharesOutstanding: sharesOutstanding, freeFloatPct: 0.40,
        financials: financials, ttm: ttm,
        dailyBars: bars(barCount, value: barValue),
        foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: bars(barCount, value: 1),
        marketIndexBars: bars(barCount, value: 1),
        governance: governance)
}

private func governance(_ kind: GovernanceFlag.Kind, _ severity: GovernanceSeverity) -> GovernanceAssessment {
    GovernanceAssessment(
        level: severity == .concern ? .significant : .watch,
        flags: [GovernanceFlag(kind: kind, severity: severity, evidence: "", whyItMatters: "", whatToCheckNext: "")],
        missingSections: [])
}

// `.balanced` neutral policy (the buy MoS floor here is +0.30; the exit floor is −0.30 — the band).
private let neutral = RegimePolicy(regime: .neutral, minMarginOfSafety: 0.30, maxTotalExposure: 0.65,
                                   maxPositionPct: 0.10, maxSectorPct: 0.25, maxNames: 10, weightTilt: [:])
// Deep risk-off: the cycle has collapsed target exposure to zero.
private let zeroExposure = RegimePolicy(regime: .riskOff, minMarginOfSafety: 0.99, maxTotalExposure: 0.0,
                                        maxPositionPct: 0, maxSectorPct: 0, maxNames: 0, weightTilt: [:])

private let anyPosition = HeldPosition(ticker: "HELD", shares: 1000, avgCost: 1000)

// Industrial IV here = min(Graham √(22.5·150·1200) ≈ 2012, NCAV/share (4500−2000)B/1e9 = 2500) ≈ 2012.

// MARK: - 1. Single-name decisions

@Suite struct ExitEvaluatorTests {

    @Test func intactNameIsHeld() {
        let d = ExitEvaluator().evaluate(anyPosition, data: makeSecurity(price: 1000), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func forensicDeteriorationExits() {
        // CFO collapses to 0.3× NI across all recent years ⇒ "CFO persistently << NI".
        let s = makeSecurity(financials: makeFinancials(cfoMultiple: 0.3))
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("Forensic"))
    }

    @Test func solvencyDeteriorationExits() {
        let s = makeSecurity(currentRatio: 0.5)   // below the 1.0 floor
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("Solvency"))
    }

    @Test func concernInsiderSellingExits() {
        let s = makeSecurity(governance: governance(.insiderSelling, .concern))
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("Governance"))
    }

    @Test func concernDilutionExits() {
        let s = makeSecurity(governance: governance(.recentDilution, .concern))
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .exit)
    }

    @Test func watchSeverityIsNotAVeto() {
        // A single watch-level flag is "a question, not a thesis" — it must not force a sell.
        let s = makeSecurity(governance: governance(.insiderSelling, .watch))
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func priceFarPastIntrinsicValueExits() {
        // IV ≈ 2012; price 2700 ⇒ MoS ≈ −0.34 ≤ −0.30 ⇒ valuation exit (Graham).
        let d = ExitEvaluator().evaluate(anyPosition, data: makeSecurity(price: 2700), policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.contains("intrinsic value"))
    }

    @Test func deepDrawdownWithIntactThesisHolds() {
        // Fisher's headline non-trigger: a paper loss is NOT a reason to sell. Cost 2500, price 800
        // (−68% on paper), gates pass, price well below IV ⇒ HOLD. avgCost must not influence this.
        let downHeavy = HeldPosition(ticker: "HELD", shares: 1000, avgCost: 2500)
        let d = ExitEvaluator().evaluate(downHeavy, data: makeSecurity(price: 800), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func priceAboveIVButWithinBandHolds() {
        // Price 2200 is ABOVE IV (≈2012) ⇒ MoS ≈ −0.09, negative but inside the −0.30 band ⇒ HOLD.
        // This is the hysteresis: a rising price alone never triggers the sell.
        let d = ExitEvaluator().evaluate(anyPosition, data: makeSecurity(price: 2200), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func lossMakerWithNoComputableValueExits() {
        // Negative EPS (no Graham number) AND liabilities > current assets (negative NCAV) ⇒ IV 0 ⇒
        // MoS −1 ⇒ exit. Symmetric with the buy side, which would never have bought a no-value name.
        let s = makeSecurity(eps: -50,
                             financials: makeFinancials(netIncome: -100, currentAssets: 4500, totalLiabilities: 5000))
        let d = ExitEvaluator().evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .exit)
    }

    @Test func honorHardGatesFalseSuppressesGateExit() {
        var cfg = SelectionConfig.balanced
        cfg.exit.honorHardGates = false
        let s = makeSecurity(currentRatio: 0.5)   // would fail Solvency if gates were honored
        let d = ExitEvaluator(config: cfg).evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .hold)                // falls through to valuation (IV intact) → hold
    }

    @Test func honorGovernanceVetoFalseSuppressesGovernanceExit() {
        var cfg = SelectionConfig.balanced
        cfg.exit.honorGovernanceVeto = false
        let s = makeSecurity(governance: governance(.insiderSelling, .concern))
        let d = ExitEvaluator(config: cfg).evaluate(anyPosition, data: s, policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func bankCapitalStrengthFailureExits() {
        // Financial archetype (sector "Keuangan") routes to [DataIntegrity, Liquidity, CapitalStrength].
        // equity = bvps·shares = 100·1e9 = 100 B; assets 2,000 B ⇒ 5% < the 6% floor ⇒ CapitalStrength fail.
        let bank = makeSecurity(ticker: "BANK", sector: "Keuangan", bvps: 100, roe: 0.15)
        let d = ExitEvaluator().evaluate(HeldPosition(ticker: "BANK", shares: 100, avgCost: 1000),
                                         data: bank, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("CapitalStrength"))
    }

    @Test func deepRiskOffTrimsTheName() {
        // Intact name, but the cycle collapsed target exposure to zero ⇒ trim (defer sizing to AllocationEngine).
        let d = ExitEvaluator().evaluate(anyPosition, data: makeSecurity(price: 1000), policy: zeroExposure)
        #expect(d.action == .trim)
    }
}

// MARK: - 2. PositionReviewer (sibling use case) end-to-end

private struct StubHoldings: HoldingsProvider {
    let positions: [HeldPosition]
    func heldPositions() async throws -> [HeldPosition] { positions }
}

private struct StubData: DataProvider {
    let securities: [Ticker: SecurityData]
    let context: MarketContext
    func universe() async throws -> [Ticker] { Array(securities.keys) }
    func data(for t: Ticker) async throws -> SecurityData { securities[t]! }
    func marketContext() async throws -> MarketContext { context }
}

private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0, commodityTailwind: true)
}

@Suite struct PositionReviewerTests {

    @Test func reviewsEachHeldNameAgainstCurrentData() async throws {
        let keep = makeSecurity(ticker: "KEEP", price: 1000)                       // intact → hold
        let dump = makeSecurity(ticker: "DUMP", price: 1000, currentRatio: 0.5)    // solvency broke → exit
        let provider = StubData(securities: ["KEEP": keep, "DUMP": dump], context: neutralContext())
        let holdings = StubHoldings(positions: [
            HeldPosition(ticker: "KEEP", shares: 1000, avgCost: 900),
            HeldPosition(ticker: "DUMP", shares: 1000, avgCost: 900)])

        let decisions = try await PositionReviewer(holdings: holdings, provider: provider).review()

        let byTicker = Dictionary(uniqueKeysWithValues: decisions.map { ($0.ticker, $0.action) })
        #expect(decisions.count == 2)
        #expect(byTicker["KEEP"] == .hold)
        #expect(byTicker["DUMP"] == .exit)
    }

    @Test func emptyBookYieldsNoDecisions() async throws {
        let provider = StubData(securities: [:], context: neutralContext())
        let decisions = try await PositionReviewer(holdings: StubHoldings(positions: []), provider: provider).review()
        #expect(decisions.isEmpty)
    }
}
