import Foundation
import Testing
@testable import Autoscreener

// MARK: - Slice 6: captured-endpoint overlays → scoring tilts.
//
// The three overlay modifiers (relativeValue / seasonality / accumulation) are capped, additive tilts
// layered on the fundamental composite — parallel to flow/timing. Each is INERT when its overlay is
// absent: it returns `(0, "")`, the engine appends no audit line, and an overlay-less name stays
// byte-for-byte unchanged (the existing SelectionEnginePipelineGoldenMaster proves that end). These
// tests pin each modifier's signal in isolation, then prove the engine wiring (favorable overlays raise
// the composite and add ordered audit lines; nil overlays add nothing). Expected numbers are
// hand-derived from the formulas, not copied from a run.

// MARK: - Fixtures

private func utcDate(year: Int, month: Int, day: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: year, month: month, day: day))!
}

private func bar(_ date: Date, value: Decimal = 1, close: Decimal = 1000) -> OHLCV {
    OHLCV(date: date, open: close, high: close, low: close, close: close, volume: 1000, value: value)
}

/// Minimal security carrying only what the overlay modifiers read. Defaults to a single June-2026 bar
/// so the seasonality month is a deterministic "Jun".
private func overlaySecurity(
    ticker: String = "TST",
    peers: PeerComparison? = nil,
    seasonality: Seasonality? = nil,
    distribution: BrokerDistribution? = nil,
    analystCoverage: AnalystCoverage? = nil,
    lastBarMonth: Int = 6,
    hasBars: Bool = true
) -> SecurityData {
    let ttm = TTMFinancials(
        eps: 100, bookValuePerShare: 1000,
        netIncome: 1, operatingCashFlow: 1, totalAssets: 1,
        epsGrowthPct: 10, currentRatio: 2, debtToEquity: 0.5, returnOnEquity: 0.2)
    return SecurityData(
        ticker: ticker, sector: "Industrials", price: 1000,
        sharesOutstanding: 1, freeFloatPct: 0.4, financials: [], ttm: ttm,
        dailyBars: hasBars ? [bar(utcDate(year: 2026, month: lastBarMonth, day: 15))] : [],
        foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: [], marketIndexBars: [],
        peerComparison: peers, seasonality: seasonality, brokerDistribution: distribution,
        analystCoverage: analystCoverage)
}

/// Builds an `AnalystCoverage` for the consensus tests. `current` defaults to the overlay/clean
/// security price (1000) so `targetUpsidePct` = (target − 1000) / 1000.
private func coverage(buy: Int, hold: Int, sell: Int, target: Double, current: Double = 1000) -> AnalystCoverage {
    AnalystCoverage(
        priceTarget: AnalystPriceTarget(best: target, low: target, high: target, current: current),
        recommendation: buy > sell ? "Buy" : (sell > buy ? "Sell" : "Hold"),
        totalBuy: buy, totalHold: hold, totalSell: sell, totalAnalyst: buy + hold + sell,
        lastUpdated: "11 Jun 26")
}

private func valuationMetric(_ name: String, subject: Double, industry: Double, sector: Double) -> PeerMetric {
    PeerMetric(id: 0, name: name, raw: [:], numeric: ["TST": subject, "INDUSTRY": industry, "SECTOR": sector])
}
private func peerTable(_ metrics: [PeerMetric]) -> PeerComparison {
    PeerComparison(symbols: ["TST", "INDUSTRY", "SECTOR"],
                   groups: [PeerMetricGroup(name: "Valuation", metrics: metrics)])
}
// The three lower-is-cheaper metric names .balanced ships with.
private let peMetric = "Current PE Ratio (Annualised)"
private let pbvMetric = "Current Price to Book Value"
private let evMetric = "EV to EBITDA (TTM)"

private func leaderboard(topBuy: [String], topSell: [String]) -> FlowLeaderboard {
    func rows(_ codes: [String], sign: String) -> String {
        codes.enumerated().map { i, c in
            "{\"rank\":\(i + 1),\"code\":\"\(c)\",\"value\":{\"raw\":\"\(sign)1000000000\",\"formatted\":\"1 B\"}," +
            "\"lot\":{\"raw\":\"1000\",\"formatted\":\"1000\"},\"foreign_value\":{\"raw\":\"\(sign)1000000\",\"formatted\":\"1 M\"}}"
        }.joined(separator: ",")
    }
    let json = "{\"message\":\"ok\",\"data\":{\"top_buy\":[\(rows(topBuy, sign: ""))]," +
        "\"top_sell\":[\(rows(topSell, sign: "-"))]}}"
    return try! OrderTradeFlowService.parseTopStocks(Data(json.utf8))
}

// MARK: - Relative-value modifier

@Suite struct RelativeValueModifierTests {

    @Test func absentPeerComparisonIsInert() {
        let (d, why) = Modifiers.relativeValue(overlaySecurity(peers: nil), config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func cheaperThanBothBenchmarksOnEveryMetricTiltsToTheFullCap() {
        let peers = peerTable([
            valuationMetric(peMetric, subject: 8, industry: 12, sector: 11),
            valuationMetric(pbvMetric, subject: 1.0, industry: 2.0, sector: 1.8),
            valuationMetric(evMetric, subject: 5, industry: 9, sector: 8),
        ])
        let (d, why) = Modifiers.relativeValue(overlaySecurity(peers: peers), config: .balanced)
        #expect(abs(d - 0.03) < 1e-9)          // mean vote +1 × cap 0.03
        #expect(why.contains("vote 1.00"))
    }

    @Test func richerThanBothBenchmarksTiltsToTheNegativeCap() {
        let peers = peerTable([
            valuationMetric(peMetric, subject: 20, industry: 12, sector: 11),
            valuationMetric(pbvMetric, subject: 3.0, industry: 2.0, sector: 1.8),
            valuationMetric(evMetric, subject: 14, industry: 9, sector: 8),
        ])
        let (d, _) = Modifiers.relativeValue(overlaySecurity(peers: peers), config: .balanced)
        #expect(abs(d - -0.03) < 1e-9)
    }

    @Test func mixedVotesNetToZeroButStillAudit() {
        let peers = peerTable([
            valuationMetric(peMetric, subject: 8, industry: 12, sector: 11),    // cheap → +1
            valuationMetric(pbvMetric, subject: 3.0, industry: 2.0, sector: 1.8), // rich  → −1
            valuationMetric(evMetric, subject: 9, industry: 9, sector: 8),       // between → 0
        ])
        let (d, why) = Modifiers.relativeValue(overlaySecurity(peers: peers), config: .balanced)
        #expect(d == 0)
        #expect(!why.isEmpty)                  // present overlay → audited even at net-zero tilt
        #expect(why.contains("vote 0.00"))
    }

    @Test func metricsWithNoNumericSubjectCellAreSkippedToInert() {
        // Metric present but the subject's cell was non-numeric ("-") → omitted from `numeric`.
        let blind = PeerMetric(id: 0, name: peMetric, raw: [:], numeric: ["INDUSTRY": 12, "SECTOR": 11])
        let (d, why) = Modifiers.relativeValue(overlaySecurity(peers: peerTable([blind])), config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)                   // no scoreable metric ⇒ inert, no line
    }
}

// MARK: - Smart-money / momentum modifier (Phase 5: flow + timing + accumulation consolidated)
//
// One capped tilt blends three [-1,1] sub-signals — foreign+broker FLOW, idiosyncratic+MA-extension
// TIMING, and broker-distribution + leaderboard ACCUMULATION — and applies `config.momentum.cap`
// (0.10). Flow is always considered (so the tilt is always audited); timing needs enough bars (the
// `overlaySecurity` fixture has one bar, so timing is absent here); accumulation needs its overlay.
// The seasonality tilt was removed entirely. Expected numbers are hand-derived from the blend formula.

@Suite struct SmartMoneyMomentumTests {

    private func distribution(buy: Double, sell: Double) -> BrokerDistribution {
        BrokerDistribution(symbol: "TST", date: "2026-06-11",
                           topBuyers: buy > 0 ? [DistributionLeg(code: "XL", type: "Asing", amount: buy)] : [],
                           topSellers: sell > 0 ? [DistributionLeg(code: "YP", type: "Lokal", amount: sell)] : [])
    }

    @Test func noFlowNoAccumulationIsZeroButStillAudited() {
        // overlaySecurity: empty foreign flow + broker 0 ⇒ flow sub-signal 0; one bar ⇒ timing absent;
        // no distribution/leaderboard ⇒ accumulation absent. Mean of [0] = 0 ⇒ modifier 0, but the
        // flow leg is always considered, so the rationale is non-empty (the tilt is always audited).
        let (d, why) = Modifiers.smartMoneyMomentum(overlaySecurity(distribution: nil), leaders: nil, config: .balanced)
        #expect(d == 0)
        #expect(why.contains("foreign"))
    }

    @Test func netBuyingDistributionTiltsPositive() {
        // flow 0 averaged with distribution imbalance (8−2)/10 = 0.6 ⇒ mean 0.3 × cap 0.10 = 0.03.
        let s = overlaySecurity(distribution: distribution(buy: 8_000_000_000, sell: 2_000_000_000))
        let (d, why) = Modifiers.smartMoneyMomentum(s, leaders: nil, config: .balanced)
        #expect(abs(d - 0.03) < 1e-9)
        #expect(why.contains("net 0.60"))
    }

    @Test func netSellingDistributionTiltsNegative() {
        // flow 0 averaged with imbalance −0.6 ⇒ mean −0.3 × cap 0.10 = −0.03.
        let s = overlaySecurity(distribution: distribution(buy: 2_000_000_000, sell: 8_000_000_000))
        let (d, _) = Modifiers.smartMoneyMomentum(s, leaders: nil, config: .balanced)
        #expect(abs(d - -0.03) < 1e-9)
    }

    @Test func leaderboardTopBuyTiltsPositive() {
        // accumulation = top-buy +1 (no distribution) ⇒ flow 0 averaged with 1.0 ⇒ mean 0.5 × cap = 0.05.
        let s = overlaySecurity(ticker: "TST", distribution: nil)
        let (d, why) = Modifiers.smartMoneyMomentum(s, leaders: leaderboard(topBuy: ["TST"], topSell: []),
                                                    config: .balanced)
        #expect(abs(d - 0.05) < 1e-9)
        #expect(why.contains("top-buy"))
    }

    @Test func distributionAndLeaderboardAverageIntoTheAccumulationLeg() {
        // accumulation = (distribution 0.6 + leaderboard 1.0)/2 = 0.8; flow 0 averaged with 0.8 ⇒
        // mean 0.4 × cap 0.10 = 0.04.
        let s = overlaySecurity(ticker: "TST", distribution: distribution(buy: 8_000_000_000, sell: 2_000_000_000))
        let (d, _) = Modifiers.smartMoneyMomentum(s, leaders: leaderboard(topBuy: ["TST"], topSell: []),
                                                  config: .balanced)
        #expect(abs(d - 0.04) < 1e-9)
    }

    @Test func tickerAbsentFromLeaderboardContributesNothingToAccumulation() {
        // No distribution, ticker not in the leaderboard ⇒ accumulation absent ⇒ only flow 0 ⇒ 0.
        let s = overlaySecurity(ticker: "TST", distribution: nil)
        let (d, _) = Modifiers.smartMoneyMomentum(s, leaders: leaderboard(topBuy: ["BBCA"], topSell: ["GOTO"]),
                                                  config: .balanced)
        #expect(d == 0)
    }
}

// MARK: - Consensus modifier (Gate-3 — fade the sell-side crowd)

@Suite struct ConsensusModifierTests {

    @Test func absentCoverageIsInert() {
        let (d, why) = Modifiers.consensus(overlaySecurity(analystCoverage: nil), config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func zeroAnalystsIsInert() {
        let none = coverage(buy: 0, hold: 0, sell: 0, target: 1500)   // totalAnalyst == 0
        let (d, why) = Modifiers.consensus(overlaySecurity(analystCoverage: none), config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func bullishCrowdFadesToTheNegativeCap() {
        // all-buy → rating +1; target 1500 vs 1000 → upside +0.5 / span 0.5 → +1; bullishness +1;
        // tilt = −1 × cap 0.03.
        let c = coverage(buy: 10, hold: 0, sell: 0, target: 1500)
        let (d, why) = Modifiers.consensus(overlaySecurity(analystCoverage: c), config: .balanced)
        #expect(abs(d - -0.03) < 1e-9)
        #expect(why.contains("fade"))
        #expect(why.contains("B/H/S 10/0/0"))
    }

    @Test func bearishNeglectedNameBoostsToThePositiveCap() {
        // all-sell → rating −1; target 500 vs 1000 → upside −0.5 / span 0.5 → −1; bullishness −1;
        // tilt = +cap.
        let c = coverage(buy: 0, hold: 0, sell: 10, target: 500)
        let (d, _) = Modifiers.consensus(overlaySecurity(analystCoverage: c), config: .balanced)
        #expect(abs(d - 0.03) < 1e-9)
    }

    @Test func balancedConsensusNetsZeroButStillAudits() {
        // buy == sell → rating 0; target == price → upside 0; bullishness 0 → tilt 0, but coverage is
        // present so the line is still audited.
        let c = coverage(buy: 5, hold: 0, sell: 5, target: 1000)
        let (d, why) = Modifiers.consensus(overlaySecurity(analystCoverage: c), config: .balanced)
        #expect(d == 0)
        #expect(!why.isEmpty)
    }

    @Test func extremeBullishnessClampsToTheCap() {
        // target 9000 (+800% upside) and all-buy: each part clamps to +1, tilt never beyond −cap.
        let c = coverage(buy: 12, hold: 0, sell: 0, target: 9000)
        let (d, _) = Modifiers.consensus(overlaySecurity(analystCoverage: c), config: .balanced)
        #expect(abs(d - -0.03) < 1e-9)
    }
}

// MARK: - Engine integration: overlays move the composite & audit, absence leaves them untouched

@Suite struct SelectionEngineOverlayIntegrationTests {

    private func cleanFinancials() -> [AnnualFinancials] {
        let b: Decimal = 1_000_000_000
        let nis: [Decimal] = [100, 110, 120, 130, 140].map { Decimal($0) * b }
        let revs: [Decimal] = [1000, 1100, 1200, 1300, 1400].map { Decimal($0) * b }
        let cfos: [Decimal] = [120, 132, 144, 156, 168].map { Decimal($0) * b }
        return (0..<5).map { i in
            AnnualFinancials(year: 2021 + i, revenue: revs[i], netIncome: nis[i], operatingCashFlow: cfos[i],
                             totalAssets: Decimal(2_000) * b, totalLiabilities: Decimal(2_000) * b,
                             currentAssets: Decimal(4_500) * b, currentLiabilities: Decimal(1_000) * b,
                             shareholderEquity: Decimal(1_000) * b, receivables: Decimal(50) * b,
                             sharesOutstanding: b)
        }
    }

    /// A clean, cheap industrial that passes every gate and the neutral MoS (50% vs 30%), optionally
    /// carrying favorable overlays. Bars are dated in January so the seasonality month is "Jan".
    private func cleanSecurity(withOverlays: Bool,
                               analystCoverage: AnalystCoverage? = nil,
                               governance: GovernanceAssessment? = nil) -> SecurityData {
        let janBar = bar(utcDate(year: 2026, month: 1, day: 15), value: 10_000_000_000)
        let bars = Array(repeating: janBar, count: 250)
        let idx = Array(repeating: bar(utcDate(year: 2026, month: 1, day: 15), value: 1), count: 250)
        let ttm = TTMFinancials(
            eps: 150, bookValuePerShare: 1200,
            netIncome: Decimal(140) * 1_000_000_000, operatingCashFlow: Decimal(168) * 1_000_000_000,
            totalAssets: Decimal(2_000) * 1_000_000_000,
            epsGrowthPct: 15.0, currentRatio: 2.0, debtToEquity: 0.5, returnOnEquity: 0.20)
        let peers = withOverlays ? peerTable([
            valuationMetric(peMetric, subject: 6, industry: 11, sector: 10),
            valuationMetric(pbvMetric, subject: 0.8, industry: 1.8, sector: 1.6),
            valuationMetric(evMetric, subject: 4, industry: 8, sector: 7),
        ]) : nil
        let season = withOverlays ? Seasonality(symbol: "GOOD",
            months: [SeasonalMonth(name: "Jan", upCount: 8, downCount: 2, totalYears: 10,
                                   avgReturnPct: 4.0, probabilityUpPct: 80)]) : nil
        let dist = withOverlays ? BrokerDistribution(symbol: "GOOD", date: "2026-01-15",
            topBuyers: [DistributionLeg(code: "XL", type: "Asing", amount: 8_000_000_000)],
            topSellers: [DistributionLeg(code: "YP", type: "Lokal", amount: 2_000_000_000)]) : nil
        return SecurityData(
            ticker: "GOOD", sector: "Industrials", price: 1000,
            sharesOutstanding: 1_000_000_000, freeFloatPct: 0.40,
            financials: cleanFinancials(), ttm: ttm,
            dailyBars: bars, foreignNetFlow: [], brokerAccumulationSignal: 0,
            sectorIndexBars: idx, marketIndexBars: idx,
            peerComparison: peers, seasonality: season, brokerDistribution: dist,
            analystCoverage: analystCoverage, governance: governance)
    }

    private func neutralContext(flowLeaders: FlowLeaderboard? = nil) -> MarketContext {
        MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                      idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                      commodityTailwind: true, flowLeaders: flowLeaders)
    }

    private struct StubProvider: DataProvider {
        let security: SecurityData
        let context: MarketContext
        func universe() async throws -> [Ticker] { [security.ticker] }
        func data(for t: Ticker) async throws -> SecurityData { security }
        func marketContext() async throws -> MarketContext { context }
    }

    @Test func overlayLessNameHasMomentumButNoOverlayTiltLines() async throws {
        let engine = StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false), context: neutralContext()),
            config: .balanced)
        let r = try #require(try await engine.run().first)
        #expect(r.audit.contains { $0.hasPrefix("momentum ") })       // always applied (the flow leg)
        #expect(!r.audit.contains { $0.hasPrefix("relValue") })
        #expect(!r.audit.contains { $0.hasPrefix("consensus") })
        #expect(!r.audit.contains { $0.hasPrefix("seasonality") })    // tilt removed entirely
    }

    @Test func favorableOverlaysRaiseTheCompositeAndAddOrderedAuditLines() async throws {
        let baseline = try #require(try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false), context: neutralContext()),
            config: .balanced).run().first)

        let context = neutralContext(flowLeaders: leaderboard(topBuy: ["GOOD"], topSell: []))
        let boosted = try #require(try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: true), context: context),
            config: .balanced).run().first)

        #expect(boosted.compositeScore > baseline.compositeScore)

        // Phase 5: the consolidated momentum line precedes the present-only overlay tilts, in order.
        let momentum = try #require(boosted.audit.firstIndex { $0.hasPrefix("momentum ") })
        let rel = try #require(boosted.audit.firstIndex { $0.hasPrefix("relValue") })
        let conviction = try #require(boosted.audit.firstIndex { $0.hasPrefix("→ conviction") })
        #expect(momentum < rel)
        #expect(rel < conviction)
    }

    @Test func bullishConsensusFadesTheCompositeAndCoverageLessNameHasNoLine() async throws {
        // Same clean, cheap name with vs without a crowded-bullish analyst coverage attached. The
        // FADE lowers the faded name's composite; the coverage-less baseline carries no consensus line
        // (the golden-master byte-for-byte-unchanged property).
        let baseline = try #require(try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false), context: neutralContext()),
            config: .balanced).run().first)
        let faded = try #require(try await StockSelectionEngine(
            provider: StubProvider(
                security: cleanSecurity(withOverlays: false,
                                        analystCoverage: coverage(buy: 10, hold: 0, sell: 0, target: 1500)),
                context: neutralContext()),
            config: .balanced).run().first)

        #expect(faded.compositeScore < baseline.compositeScore)
        #expect(faded.audit.contains { $0.hasPrefix("consensus") })
        #expect(!baseline.audit.contains { $0.hasPrefix("consensus") })
    }

    @Test func consensusLineIsOrderedAfterMomentumBeforeConviction() async throws {
        let context = neutralContext(flowLeaders: leaderboard(topBuy: ["GOOD"], topSell: []))
        let r = try #require(try await StockSelectionEngine(
            provider: StubProvider(
                security: cleanSecurity(withOverlays: true,
                                        analystCoverage: coverage(buy: 10, hold: 0, sell: 0, target: 1500)),
                context: context),
            config: .balanced).run().first)
        let momentum = try #require(r.audit.firstIndex { $0.hasPrefix("momentum ") })
        let con = try #require(r.audit.firstIndex { $0.hasPrefix("consensus") })
        let conviction = try #require(r.audit.firstIndex { $0.hasPrefix("→ conviction") })
        #expect(momentum < con)
        #expect(con < conviction)
    }

    // MARK: Gate-2 governance veto wiring

    private func governanceAssessment(_ flags: [GovernanceFlag], level: GovernanceLevel) -> GovernanceAssessment {
        GovernanceAssessment(level: level, flags: flags, missingSections: [])
    }
    private func concernInsiderFlag() -> GovernanceFlag {
        GovernanceFlag(kind: .insiderSelling, severity: .concern,
                       evidence: "e", whyItMatters: "w", whatToCheckNext: "c")
    }

    @Test func concernGovernanceFlagEliminatesTheName() async throws {
        // The same clean, cheap name that survives without governance is dropped when carrying a
        // concern-severity insider-selling flag.
        let veto = governanceAssessment([concernInsiderFlag()], level: .significant)
        let recs = try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false, governance: veto),
                                   context: neutralContext()),
            config: .balanced).run()
        #expect(recs.isEmpty)
    }

    @Test func cleanGovernanceSurvivesWithAuditLineAndNilIsUnchanged() async throws {
        let clean = governanceAssessment([], level: .clean)
        let withGov = try #require(try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false, governance: clean),
                                   context: neutralContext()),
            config: .balanced).run().first)
        #expect(withGov.audit.contains { $0.hasPrefix("governance OK") })

        let withoutGov = try #require(try await StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false), context: neutralContext()),
            config: .balanced).run().first)
        #expect(!withoutGov.audit.contains { $0.hasPrefix("governance") })
    }
}
