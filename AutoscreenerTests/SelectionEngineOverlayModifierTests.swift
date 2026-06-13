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
        peerComparison: peers, seasonality: seasonality, brokerDistribution: distribution)
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

// MARK: - Seasonality modifier

@Suite struct SeasonalityModifierTests {

    private func season(month: String, prob: Double, avg: Double) -> Seasonality {
        Seasonality(symbol: "TST",
                    months: [SeasonalMonth(name: month, upCount: 0, downCount: 0, totalYears: 10,
                                           avgReturnPct: avg, probabilityUpPct: prob)])
    }

    @Test func absentSeasonalityIsInert() {
        let (d, why) = Modifiers.seasonality(overlaySecurity(seasonality: nil), config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func favorableCurrentMonthTiltsPositive() {
        // June bar; June P(up)=80 → prob signal +0.6; avg +4% / span 5 → +0.8; blend 0.7 × cap 0.02.
        let s = overlaySecurity(seasonality: season(month: "Jun", prob: 80, avg: 4.0), lastBarMonth: 6)
        let (d, why) = Modifiers.seasonality(s, config: .balanced)
        #expect(abs(d - 0.014) < 1e-9)
        #expect(why.contains("Jun"))
    }

    @Test func unfavorableCurrentMonthTiltsNegative() {
        let s = overlaySecurity(seasonality: season(month: "Jun", prob: 20, avg: -4.0), lastBarMonth: 6)
        let (d, _) = Modifiers.seasonality(s, config: .balanced)
        #expect(abs(d - -0.014) < 1e-9)
    }

    @Test func currentMonthNotInTableIsInert() {
        // June bar, but the table only has January.
        let s = overlaySecurity(seasonality: season(month: "Jan", prob: 90, avg: 9), lastBarMonth: 6)
        let (d, why) = Modifiers.seasonality(s, config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func tiltIsClampedToTheCap() {
        // P(up)=100 → +1; avg 50% / span 5 → clamps to +1; blend 1.0 × cap, but never beyond the cap.
        let s = overlaySecurity(seasonality: season(month: "Jun", prob: 100, avg: 50), lastBarMonth: 6)
        let (d, _) = Modifiers.seasonality(s, config: .balanced)
        #expect(abs(d - 0.02) < 1e-9)
    }

    @Test func noBarsMeansNoCurrentMonthSoInert() {
        let s = overlaySecurity(seasonality: season(month: "Jun", prob: 80, avg: 4), hasBars: false)
        let (d, why) = Modifiers.seasonality(s, config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }
}

// MARK: - Accumulation modifier

@Suite struct AccumulationModifierTests {

    private func distribution(buy: Double, sell: Double) -> BrokerDistribution {
        BrokerDistribution(symbol: "TST", date: "2026-06-11",
                           topBuyers: buy > 0 ? [DistributionLeg(code: "XL", type: "Asing", amount: buy)] : [],
                           topSellers: sell > 0 ? [DistributionLeg(code: "YP", type: "Lokal", amount: sell)] : [])
    }

    @Test func absentBothSourcesIsInert() {
        let (d, why) = Modifiers.accumulation(overlaySecurity(distribution: nil), leaders: nil, config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func netBuyingTiltsPositive() {
        // buy 8B, sell 2B → imbalance (8−2)/10 = 0.6 → 0.6 × cap 0.03 = 0.018.
        let s = overlaySecurity(distribution: distribution(buy: 8_000_000_000, sell: 2_000_000_000))
        let (d, why) = Modifiers.accumulation(s, leaders: nil, config: .balanced)
        #expect(abs(d - 0.018) < 1e-9)
        #expect(why.contains("net 0.60"))
    }

    @Test func netSellingTiltsNegative() {
        let s = overlaySecurity(distribution: distribution(buy: 2_000_000_000, sell: 8_000_000_000))
        let (d, _) = Modifiers.accumulation(s, leaders: nil, config: .balanced)
        #expect(abs(d - -0.018) < 1e-9)
    }

    @Test func leaderboardTopBuyMembershipTiltsToTheFullCap() {
        let s = overlaySecurity(ticker: "TST", distribution: nil)
        let (d, why) = Modifiers.accumulation(s, leaders: leaderboard(topBuy: ["TST"], topSell: []),
                                              config: .balanced)
        #expect(abs(d - 0.03) < 1e-9)
        #expect(why.contains("top-buy"))
    }

    @Test func leaderboardTopSellMembershipTiltsToTheNegativeCap() {
        let s = overlaySecurity(ticker: "TST", distribution: nil)
        let (d, why) = Modifiers.accumulation(s, leaders: leaderboard(topBuy: [], topSell: ["TST"]),
                                              config: .balanced)
        #expect(abs(d - -0.03) < 1e-9)
        #expect(why.contains("top-sell"))
    }

    @Test func tickerAbsentFromLeaderboardContributesNothing() {
        let s = overlaySecurity(ticker: "TST", distribution: nil)
        let (d, why) = Modifiers.accumulation(s, leaders: leaderboard(topBuy: ["BBCA"], topSell: ["GOTO"]),
                                              config: .balanced)
        #expect(d == 0)
        #expect(why.isEmpty)
    }

    @Test func bothSourcesAverageTogether() {
        // distribution imbalance 0.6 + leaderboard top-buy 1.0 → mean 0.8 × cap 0.03 = 0.024.
        let s = overlaySecurity(ticker: "TST", distribution: distribution(buy: 8_000_000_000, sell: 2_000_000_000))
        let (d, _) = Modifiers.accumulation(s, leaders: leaderboard(topBuy: ["TST"], topSell: []),
                                            config: .balanced)
        #expect(abs(d - 0.024) < 1e-9)
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
    private func cleanSecurity(withOverlays: Bool) -> SecurityData {
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
            peerComparison: peers, seasonality: season, brokerDistribution: dist)
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

    @Test func overlayLessNameProducesNoTiltLines() async throws {
        let engine = StockSelectionEngine(
            provider: StubProvider(security: cleanSecurity(withOverlays: false), context: neutralContext()),
            config: .balanced)
        let r = try #require(try await engine.run().first)
        #expect(!r.audit.contains { $0.hasPrefix("relValue") })
        #expect(!r.audit.contains { $0.hasPrefix("seasonality") })
        #expect(!r.audit.contains { $0.hasPrefix("accumulation") })
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

        let rel = try #require(boosted.audit.firstIndex { $0.hasPrefix("relValue") })
        let sea = try #require(boosted.audit.firstIndex { $0.hasPrefix("seasonality") })
        let acc = try #require(boosted.audit.firstIndex { $0.hasPrefix("accumulation") })
        let timing = try #require(boosted.audit.firstIndex { $0.hasPrefix("timing") })
        let conviction = try #require(boosted.audit.firstIndex { $0.hasPrefix("→ conviction") })
        // Tilts sit between the core modifiers and the sizing line, in declared order.
        #expect(timing < rel)
        #expect(rel < sea)
        #expect(sea < acc)
        #expect(acc < conviction)
    }
}
