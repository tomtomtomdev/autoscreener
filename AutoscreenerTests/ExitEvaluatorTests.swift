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
    currentAssets: Decimal = 1500,   // billions; < total liabilities ⇒ NCAV negative by default
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

// Industrial IV here = Graham √(22.5·150·1200) ≈ 2012; NCAV is negative (CA 1,500B < TL 2,000B) so the
// earnings-based Graham number binds (IV = max(Graham, NCAV), and a non-positive NCAV is never a candidate).

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

private struct ThrowingData: DataProvider {
    let securities: [Ticker: SecurityData]
    let failures: [Ticker: any Error]
    let context: MarketContext
    func universe() async throws -> [Ticker] { Array(securities.keys) }
    func data(for t: Ticker) async throws -> SecurityData {
        if let e = failures[t] { throw e }
        return securities[t]!
    }
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

    @Test func skipsAnUnvaluableHeldNameAndKeepsReviewingTheRest() async throws {
        // Regression (sell-side mirror of the buy engine): a held name whose fundamentals can't be
        // re-fetched must be SKIPPED, not abort the whole review — otherwise one bad holding empties
        // the Recommendations screen with "…AdapterError error 0".
        let keep = makeSecurity(ticker: "KEEP", price: 1000)
        let provider = ThrowingData(
            securities: ["KEEP": keep],
            failures: ["BAD": SelectionFundamentals.AdapterError.missingField(id: "1498", name: "Current Ratio")],
            context: neutralContext())
        let holdings = StubHoldings(positions: [
            HeldPosition(ticker: "KEEP", shares: 1000, avgCost: 900),
            HeldPosition(ticker: "BAD", shares: 1000, avgCost: 900)])

        var skipped: [SkippedName] = []
        let decisions = try await PositionReviewer(holdings: holdings, provider: provider).review { skipped.append($0) }

        #expect(decisions.map(\.ticker) == ["KEEP"])
        #expect(skipped.map(\.ticker) == ["BAD"])
    }
}

// MARK: - 3. Gate-5 PHASE 2 — EntryThesis (thesis-break + Lynch category-aware bands)
//
// Phase 1 re-evaluates CURRENT data only. Phase 2 persists an `EntryThesis` snapshot at purchase so the
// evaluator can also see two things current data alone cannot — both grounded in the buy-side skills
// REVERSED (consulted in-session, not from priors):
//
//   • Fisher, "When to Sell" — Reason 1 (a mistake was made in the original analysis) and Reason 2 (the
//     business has deteriorated) both surface as the re-computed intrinsic value FALLING materially below
//     the IV that justified the purchase. This is independent of price (distinct from the Graham
//     overvaluation tier): a name can be DOWN on price with an intact/higher IV (hold), or UP on price
//     with a collapsed IV (sell). Fisher's Reason 3 (a superior opportunity) stays the buy engine's job.
//   • Lynch, six categories — each has its own sell discipline, modelled as a multiplier on the exit
//     band: fast growers / asset plays run (>1, wider band); stalwarts / cyclicals / slow growers get
//     recycled on modest gains (<1, tighter band). Absent category ⇒ ×1.0 ⇒ the flat Phase-1 floor.
//
// Test List (one behaviour per test, simplest first):
//  17. thesis present, IV unchanged, no category        → .hold   (thesis path defaults to Phase 1)
//  18. IV collapsed ≥ floor since entry, price < cur IV  → .exit   (Fisher reason 1/2, price-independent)
//  19. IV dipped only slightly since entry               → .hold   (a temporary dip is NOT a break)
//  20. IV ROSE since entry (winner), price < cur IV      → .hold   (entry IV is a floor, not a ceiling)
//  21. Lynch fastGrower widens the band                  → .hold   (a flat-floor exit now holds)
//  22. Lynch slowGrower tightens the band                → .exit   (a flat-floor hold now exits)
//  23. IV-collapse fires BEFORE the price tier           → reason is the thesis-break, not "ran past IV"
//  24. honorEntryThesis = false                          → thesis ignored (Phase-1 behaviour)
//  25. EntryThesis.snapshot factory                      → builds entryIV/entryMoS from the valuator
//  26. bank: justified-P/B IV collapses (ROE fell)       → .exit   (financial-archetype routing)

private func thesis(entryIV: Double, mos: Double = 0.30, category: LynchCategory? = nil) -> EntryThesis {
    EntryThesis(entryDate: day, entryIntrinsicValue: entryIV, entryMarginOfSafety: mos, lynchCategory: category)
}

private func heldWithThesis(_ t: EntryThesis, ticker: Ticker = "HELD", avgCost: Double = 1000) -> HeldPosition {
    HeldPosition(ticker: ticker, shares: 1000, avgCost: avgCost, thesis: t)
}

// Industrial Graham IV for makeSecurity = √(22.5 · eps · 1200). NCAV is negative (default CA 1,500B <
// TL 2,000B), so the earnings-based Graham number is the binding IV and tracks eps:
//   eps 150 → √(22.5·150·1200) ≈ 2012   (the baseline "entry" IV)
//   eps  60 → √(22.5· 60·1200) ≈ 1273   (≈ −37% vs 2012: a collapse)
//   eps 130 → √(22.5·130·1200) ≈ 1873   (≈  −7% vs 2012: a mild dip)
//   eps 200 → √(22.5·200·1200) ≈ 2324   (≈ +15% vs 2012: a compounding winner)

@Suite struct EntryThesisExitTests {

    @Test func intactThesisHoldsLikePhase1() {
        // A position that carries a thesis but is otherwise intact (IV unchanged, no Lynch category)
        // must behave exactly like the Phase-1 no-thesis path: hold.
        let pos = heldWithThesis(thesis(entryIV: 2012))
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 900), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func intrinsicValueCollapseSinceEntryExits() {
        // Current IV ≈ 1273 vs entry 2012 ⇒ −37% ≤ the −35% collapse floor ⇒ the thesis broke. Price 900
        // is BELOW current IV (MoS positive) so the Graham overvaluation tier would HOLD — only the
        // entry-relative collapse can sell this, which is the whole point of Phase 2.
        let pos = heldWithThesis(thesis(entryIV: 2012))
        let s = makeSecurity(price: 900, eps: 60)
        let d = ExitEvaluator().evaluate(pos, data: s, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("thesis broke"))
    }

    @Test func smallIntrinsicValueDipSinceEntryHolds() {
        // Current IV ≈ 1873 vs entry 2012 ⇒ only −7%, well inside the −35% floor ⇒ a temporary dip, not
        // a broken thesis (Fisher's non-trigger). Hold.
        let pos = heldWithThesis(thesis(entryIV: 2012))
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 900, eps: 130), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func intrinsicValueRoseSinceEntryHolds() {
        // The compounding winner: current IV ≈ 2324 > entry 2012. Entry IV is a FLOOR for the break test,
        // never a ceiling — a higher IV is the opposite of a thesis break. Hold (even bought expensive).
        let pos = heldWithThesis(thesis(entryIV: 2012), avgCost: 1800)
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 1000, eps: 200), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func lynchFastGrowerWidensTheBand() {
        // Price 2700 vs IV ≈ 2012 ⇒ MoS ≈ −0.34, which exits at the flat −0.30 floor (see Phase-1 test
        // #7). As a fast grower the band widens to −0.30 × 1.5 = −0.45, so −0.34 is now inside it ⇒ hold:
        // Lynch lets a fast grower run while the story holds. IV is unchanged, so Tier 1c does not fire.
        let pos = heldWithThesis(thesis(entryIV: 2012, category: .fastGrower))
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 2700), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func lynchSlowGrowerTightensTheBand() {
        // Price 2400 vs IV ≈ 2012 ⇒ MoS ≈ −0.19, which HOLDS at the flat −0.30 floor. As a slow grower
        // the band tightens to −0.30 × 0.5 = −0.15, so −0.19 now breaches it ⇒ exit: Lynch takes the
        // modest gain and recycles rather than riding a slow grower into overvaluation.
        let pos = heldWithThesis(thesis(entryIV: 2012, category: .slowGrower))
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 2400), policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.contains("intrinsic value"))
    }

    @Test func intrinsicValueCollapseTakesPrecedenceOverPriceTier() {
        // Both would exit: IV collapsed (1273 vs 2012, −37%) AND price 2000 has run past current IV
        // (MoS ≈ −0.57 ≤ −0.30). Tier 1c is checked first, so the reason is the thesis-break — the more
        // fundamental signal — not the price-overvaluation headline.
        let pos = heldWithThesis(thesis(entryIV: 2012))
        let d = ExitEvaluator().evaluate(pos, data: makeSecurity(price: 2000, eps: 60), policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("thesis broke"))
    }

    @Test func honorEntryThesisFalseSuppressesTheThesisLayer() {
        // With the toggle off, a collapsed-IV position behaves like Phase 1: Tier 1c is skipped, and at
        // price 900 (< current IV 1273) the Graham tier holds. Symmetric with the other honor* toggles.
        var cfg = SelectionConfig.balanced
        cfg.exit.honorEntryThesis = false
        let pos = heldWithThesis(thesis(entryIV: 2012))
        let d = ExitEvaluator(config: cfg).evaluate(pos, data: makeSecurity(price: 900, eps: 60), policy: neutral)
        #expect(d.action == .hold)
    }

    @Test func snapshotFactoryRecordsValuatorIVAndMoSAtEntry() {
        // The seam Phase 3's paper-trading store calls on a fill: snapshot the archetype valuator's IV +
        // MoS at entry. Clock-free — the caller injects entryDate.
        let cfg = SelectionConfig.balanced
        let s = makeSecurity(price: 1000)
        let profile = StockSelectionEngine.defaultProfile(for: s, config: cfg)
        let t = EntryThesis.snapshot(of: s, profile: profile, config: cfg, lynchCategory: .stalwart, entryDate: day)
        #expect(abs(t.entryIntrinsicValue - profile.valuator.intrinsicValue(s, config: cfg)) < 1e-6)
        #expect(abs(t.entryMarginOfSafety - profile.valuator.marginOfSafety(s, config: cfg)) < 1e-9)
        #expect(t.lynchCategory == .stalwart)
        #expect(t.entryDate == day)
    }

    @Test func recommendationFactoryReusesRankedIVAndMoS() {
        // Gate-5 Phase 3's cheap seam: snapshot the thesis straight from a ranked Recommendation the
        // engine already produced (no SecurityData, no re-fetch). IV/MoS are copied verbatim; the
        // category is whatever the caller carries (no classifier yet ⇒ default nil); entryDate injected.
        let rec = Recommendation(ticker: "WIFI", compositeScore: 0.74, intrinsicValue: 6_364,
                                 marginOfSafety: 0.31, conviction: 0.74, suggestedWeight: 0.089,
                                 audit: ["regime=Neutral"])
        let t = EntryThesis(recommendation: rec, entryDate: day)
        #expect(t.entryIntrinsicValue == 6_364)
        #expect(t.entryMarginOfSafety == 0.31)
        #expect(t.lynchCategory == nil)
        #expect(t.entryDate == day)

        let tagged = EntryThesis(recommendation: rec, entryDate: day, lynchCategory: .fastGrower)
        #expect(tagged.lynchCategory == .fastGrower)
    }

    @Test func entryThesisRoundTripsThroughCodable() {
        // It is persisted inside each open lot (PaperPosition), so it must survive a JSON round-trip.
        let t = EntryThesis(entryDate: day, entryIntrinsicValue: 6_364,
                            entryMarginOfSafety: 0.31, lynchCategory: .stalwart)
        let data = try! JSONEncoder().encode(t)
        let decoded = try! JSONDecoder().decode(EntryThesis.self, from: data)
        #expect(decoded == t)
    }

    @Test func bankJustifiedPBCollapseSinceEntryExits() {
        // Financial archetype (sector "Keuangan") routes Tier 1c through JustifiedPBValuator. ROE has
        // fallen from the strong level at entry to 0.08, collapsing the ROE-justified P/B (and thus IV)
        // far below the entry snapshot ⇒ thesis broke. bvps 200 keeps CapitalStrength passing (equity
        // 200B / assets 2,000B = 10% ≥ 6% floor) so Tier 1a does not pre-empt the thesis tier.
        let bank = makeSecurity(ticker: "BANK", sector: "Keuangan", price: 300, bvps: 200, roe: 0.08)
        let pos = heldWithThesis(thesis(entryIV: 300, category: .stalwart), ticker: "BANK")
        let d = ExitEvaluator().evaluate(pos, data: bank, policy: neutral)
        #expect(d.action == .exit)
        #expect(d.reason.hasPrefix("thesis broke"))
    }
}
