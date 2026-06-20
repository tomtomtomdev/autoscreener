import Foundation
import Testing
@testable import Autoscreener

// Phase 1.8 (§8): the live Tier-A `DataProvider`. Pure assembly — these tests pin the WIRING:
// that the per-ticker fan-out composes the 1.1–1.7 adapters into a correct `SecurityData`, that
// best-effort legs degrade (not abort) while essential legs propagate, that results are cached,
// that the fan-out is paced through the shared throttle, and that `marketContext()` reuses the
// regime fan-out and refuses to score a phantom regime when every input is absent. The adapters'
// own field-mapping is covered by their unit tests; here we only check orchestration.

private enum StubError: Error { case absent }

private let B: Decimal = 1_000_000_000
private func bil(_ n: Int) -> Decimal { Decimal(n) * B }

// MARK: - Canned "happy path" inputs (industrial, WIFI-like)

/// A complete industrial keystats field map — every field `ttm(fromKeystats:)` requires is present.
private let happyFields: [String: String] = [
    "13200": "242.08",     // EPS (TTM)
    "15718": "759.60",     // Book Value / share
    "1498": "3.09",        // Current Ratio
    "1508": "1.38",        // Debt / Equity
    "1461": "6.57%",       // ROE (percent → 0.0657)
    "1471": "-11.46%",     // EPS YoY growth (percent-number, verbatim)
    "1555": "490 B",       // Net Income (TTM, scaled)
    "2545": "(1,899 B)",   // Cash From Operations (TTM, scaled)
    "1559": "16,196 B",    // Total Assets (scaled)
    "15883": "7,464 B",    // Common Equity (scaled, shares fallback)
]

/// Shares derived from the happy field map: NetIncome(490 B) ÷ EPS(242.08).
private let expectedShares = Decimal(490_000_000_000.0 / 242.08)

private func series(_ legend: String, _ values: [Decimal]) -> FundachartSeries {
    FundachartSeries(legend: legend, values: values)
}

/// Three fiscal years, newest-first (as the real feed returns).
private let happyFundachart = StubFundachart(
    income: FundachartFinancials(periods: ["2025", "2024", "2023"], series: [
        series("Revenue", [bil(1659), bil(1500), bil(1400)]),
        series("Net Income", [bil(490), bil(400), bil(350)]),
    ]),
    balance: FundachartFinancials(periods: ["2025", "2024", "2023"], series: [
        series("Total Assets", [bil(16196), bil(15000), bil(14000)]),
        series("Total Liabilities", [bil(9000), bil(8500), bil(8000)]),
    ]),
    cashFlow: FundachartFinancials(periods: ["2025", "2024", "2023"], series: [
        series("Operating", [bil(-1899), bil(1200), bil(1100)]),
    ]))

private func subtotal(_ name: String, _ values: [String]) -> FinancialAccount {
    FinancialAccount(id: name, accountID: 0, name: name, level: 1, values: values,
                     isEmphasized: true, defaultExpanded: true, children: [])
}

/// Annual balance sheet with the three §1.3 subtotals, columns aligned to fundachart's years.
private let happyStatement = FinancialStatement(
    currency: "IDR",
    periods: ["12M 2025", "12M 2024", "12M 2023"],
    accounts: [
        subtotal("Aset Lancar", ["8,688 B", "8,000 B", "7,500 B"]),
        subtotal("Liabilitas Jangka Pendek", ["3,981 B", "3,800 B", "3,600 B"]),
        subtotal("Piutang Usaha", ["223 B", "200 B", "180 B"]),
    ])

private let happyInfo = EmittenInfo(
    symbol: "WIFI", name: "PT Solusi Sinergi Digital", sector: "Teknologi",
    subSector: "Perangkat Lunak & Jasa TI", indexes: ["IDXTECHNO", "LQ45"])
private let happyProfile = EmittenProfile(freeFloatDisplay: "40.00%", sharesDisplay: "156,558,200")

private func bar(day: Int, close: Decimal, value: Decimal, net: Decimal) -> HistoricalSummaryBar {
    HistoricalSummaryBar(date: Date(timeIntervalSince1970: TimeInterval(day * 86_400)),
                         open: close, high: close, low: close, close: close,
                         volume: 1000, value: value, netForeign: net)
}

/// Stock bars (deliberately newest-last-and-first-mixed so the ascending sort is exercised).
private let wifiBars: [HistoricalSummaryBar] = [
    bar(day: 3, close: 120, value: bil(12), net: bil(8)),
    bar(day: 1, close: 100, value: bil(10), net: bil(-5)),
    bar(day: 2, close: 110, value: bil(11), net: bil(3)),
]
/// Generic index bars (sector/market) — just needs to be non-empty.
private let indexBars: [HistoricalSummaryBar] = [
    bar(day: 1, close: 7000, value: bil(1), net: 0),
    bar(day: 2, close: 7050, value: bil(1), net: 0),
]
private let happyPriceFeed = StubPriceFeed(
    barsBySymbol: ["WIFI": wifiBars], defaultBars: indexBars)

private let happyBrokerRecords = [
    BrokerActivityRecord(date: Date(timeIntervalSince1970: 0),
                         netValue: bil(10), buyValue: bil(60), sellValue: bil(50)),
]

// Captured-endpoint overlays (Slice 4) — best-effort legs the provider carries onto SecurityData /
// MarketContext. Minimal but distinguishable fixtures so the wiring tests can prove they populate.
private let happyPeers = PeerComparison(
    symbols: ["WIFI", "INDUSTRY", "SECTOR"],
    groups: [PeerMetricGroup(name: "Valuation",
        metrics: [PeerMetric(id: 12148, name: "PE", raw: ["WIFI": "15.67"], numeric: ["WIFI": 15.67])])])
private let happySeasonality = Seasonality(symbol: "WIFI",
    months: [SeasonalMonth(name: "Jun", upCount: 6, downCount: 4, totalYears: 10,
                           avgReturnPct: 1.20, probabilityUpPct: 60)])
private let happyDistribution = BrokerDistribution(symbol: "WIFI", date: "2026-06-11",
    topBuyers: [DistributionLeg(code: "XL", type: "Asing", amount: 5_000_000_000)],
    topSellers: [DistributionLeg(code: "YP", type: "Lokal", amount: 3_000_000_000)])
/// Built via the real top-stock parse so the StockbitValue wiring is exercised end-to-end.
private let happyLeaderboard = try! OrderTradeFlowService.parseTopStocks(Data(#"""
{"message":"ok","data":{"top_buy":[{"rank":1,"code":"BBCA","value":{"raw":"12000000000","formatted":"12 B"},"lot":{"raw":"1000","formatted":"1000"},"foreign_value":{"raw":"8000000000","formatted":"8 B"}}],"top_sell":[]}}
"""#.utf8))

// MARK: - Regime inputs

private func makeSnapshot(valuation: Double?, rate: BIRateDirection?) -> RegimeSnapshot {
    let composite = RegimeSnapshot.IndexValuation(pe: nil, pb: nil, pePctile: valuation, pbPctile: nil)
    let biRate = rate.map { RegimeSnapshot.BIRate(value: 5.75, direction: $0, asOf: "2026-06-01") }
    return RegimeSnapshot(asOf: "2026-06-01", biRate: biRate, macro: nil,
                          indices: [RegimeSnapshot.compositeKey: composite])
}

private func makeFlow(net: Double) -> ForeignFlow {
    let m = FlowMetric(raw: net, formatted: "\(net)")
    let zero = FlowMetric(raw: 0, formatted: "0")
    let bd = ForeignFlowBreakdown(label: "", total: zero, foreignTotal: zero,
                                  foreignPercentage: 0, domesticTotal: zero, domesticPercentage: 0)
    return ForeignFlow(symbol: "IHSG", dateRange: "", from: "", to: "", lastUpdated: "",
                       foreignBuy: zero, foreignSell: zero, netForeign: m,
                       domesticBuy: zero, domesticSell: zero, netDomestic: zero,
                       value: bd, volume: bd, frequency: bd)
}

private func makeCommodity(changePercent: Double?) -> CommodityQuote {
    CommodityQuote(symbol: "USDIDR", name: "USD/IDR", price: 16000, previousClose: 15944,
                   change: 56, changePercent: changePercent, volume: nil,
                   formattedPrice: "16,000", asOf: "")
}

// MARK: - Stubs

private actor StubKeystats: KeystatsRatioServicing {
    let result: [String: String]
    private(set) var fieldsCallCount = 0
    init(_ result: [String: String]) { self.result = result }
    func ratios(symbol: String, yearLimit: Int) async throws -> ValuationRatios { throw StubError.absent }
    func fields(symbol: String, yearLimit: Int) async throws -> [String: String] {
        fieldsCallCount += 1
        return result
    }
}

private struct StubFundachart: FundachartServicing {
    let income, balance, cashFlow: FundachartFinancials
    func financials(symbol: String, dataset: FundachartDataset,
                    report: FundachartReport) async throws -> FundachartFinancials {
        switch dataset {
        case .incomeStatement: return income
        case .balanceSheet:    return balance
        case .cashFlow:        return cashFlow
        }
    }
}

private struct StubStatements: FinancialStatementServicing {
    var statement: FinancialStatement?
    func load(symbol: String, report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement {
        guard let statement else { throw StubError.absent }
        return statement
    }
}

private struct StubEmitten: EmittenServicing {
    var infoResult: EmittenInfo
    var profileResult: EmittenProfile?
    func info(symbol: String) async throws -> EmittenInfo { infoResult }
    func profile(symbol: String) async throws -> EmittenProfile {
        guard let profileResult else { throw StubError.absent }
        return profileResult
    }
}

private struct StubPriceFeed: CompanyPriceFeedServicing {
    var barsBySymbol: [String: [HistoricalSummaryBar]]
    var defaultBars: [HistoricalSummaryBar]
    var throwingSymbols: Set<String> = []
    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod, startDate: Date,
                           endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage {
        if throwingSymbols.contains(symbol) { throw StubError.absent }
        return HistoricalSummaryPage(bars: barsBySymbol[symbol] ?? defaultBars, nextPage: nil)
    }
}

private struct StubBroker: BrokerActivityServicing {
    var records: [BrokerActivityRecord]?
    func dailyActivity(symbol: String, period: BrokerActivityPeriod, brokerCodes: [String],
                       limit: Int, page: Int) async throws -> [BrokerActivityRecord] {
        guard let records else { throw StubError.absent }
        return records
    }
}

private struct StubComparison: ComparisonRatiosServicing {
    var value: PeerComparison?
    func comparison(symbol: String) async throws -> PeerComparison {
        guard let value else { throw StubError.absent }
        return value
    }
}

private struct StubSeasonality: SeasonalityServicing {
    var value: Seasonality?
    func seasonality(symbol: String, year: Int, backYear: Int) async throws -> Seasonality {
        guard let value else { throw StubError.absent }
        return value
    }
}

private struct StubOrderFlow: OrderTradeFlowServicing {
    var distributionValue: BrokerDistribution?
    var leaderboardValue: FlowLeaderboard?
    func distribution(symbol: String) async throws -> BrokerDistribution {
        guard let distributionValue else { throw StubError.absent }
        return distributionValue
    }
    func topStocks(valueType: TopStockValueType, page: Int) async throws -> FlowLeaderboard {
        guard let leaderboardValue else { throw StubError.absent }
        return leaderboardValue
    }
}

private struct StubSnapshot: RegimeSnapshotProviding {
    var value: RegimeSnapshot?
    func snapshot() async throws -> RegimeSnapshot {
        guard let value else { throw StubError.absent }
        return value
    }
}

private struct StubAggFlow: AggregateForeignFlowServicing {
    var value: ForeignFlow?
    func marketFlow(period: ForeignFlowPeriod) async throws -> ForeignFlow {
        guard let value else { throw StubError.absent }
        return value
    }
}

/// Always throws — the provider tests never need a real `PriceSeries` (the 200-day distance
/// mapping is covered by `MarketContextAdapterTests`).
private struct StubChart: ChartServicing {
    func candles(symbol: String, timeframe: ChartTimeframe,
                 chartType: ChartType) async throws -> PriceSeries { throw StubError.absent }
}

private struct StubCommodity: CommodityPriceServicing {
    var value: CommodityQuote?
    func quote(symbol: String) async throws -> CommodityQuote {
        guard let value else { throw StubError.absent }
        return value
    }
}

/// A symbol-keyed commodity stub so a test can give USD/IDR and each export-basket leg
/// (coal/CPO/nickel) distinct moves — proving the selection path reads the *basket*, not the
/// rupiah leg. Throws for any symbol absent from the map (modelling a leg that failed to price).
private struct StubCommodityBySymbol: CommodityPriceServicing {
    var changeBySymbol: [String: Double]
    func quote(symbol: String) async throws -> CommodityQuote {
        guard let change = changeBySymbol[symbol] else { throw StubError.absent }
        return CommodityQuote(symbol: symbol, name: symbol, price: 100, previousClose: 99,
                              change: 1, changePercent: change, volume: nil,
                              formattedPrice: "100", asOf: "")
    }
}

private struct StubBreadth: BreadthServicing {
    var result: BreadthReading
    func reading(symbols: [String], period: Int) async -> BreadthReading { result }
}

private actor DelayRecorder {
    private(set) var delays: [UInt64] = []
    func record(_ ns: UInt64) { delays.append(ns) }
}

/// Records the [start, end] span of every daily-bars request so a test can pin the window.
private actor SpanRecorder {
    private(set) var spans: [TimeInterval] = []
    func record(_ s: TimeInterval) { spans.append(s) }
    var maxSpan: TimeInterval { spans.max() ?? 0 }
}

private struct SpanSpyPriceFeed: CompanyPriceFeedServicing {
    let recorder: SpanRecorder
    var barsBySymbol: [String: [HistoricalSummaryBar]]
    var defaultBars: [HistoricalSummaryBar]
    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod, startDate: Date,
                           endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage {
        await recorder.record(endDate.timeIntervalSince(startDate))
        return HistoricalSummaryPage(bars: barsBySymbol[symbol] ?? defaultBars, nextPage: nil)
    }
}

// MARK: - Provider factory (every leg defaults to the happy path; override per test)

private func makeProvider(
    universe: [Ticker] = ["WIFI"],
    keystats: any KeystatsRatioServicing = StubKeystats(happyFields),
    fundachart: any FundachartServicing = happyFundachart,
    statements: any FinancialStatementServicing = StubStatements(statement: happyStatement),
    emitten: any EmittenServicing = StubEmitten(infoResult: happyInfo, profileResult: happyProfile),
    priceFeed: any CompanyPriceFeedServicing = happyPriceFeed,
    broker: any BrokerActivityServicing = StubBroker(records: happyBrokerRecords),
    comparison: any ComparisonRatiosServicing = StubComparison(value: happyPeers),
    seasonality: any SeasonalityServicing = StubSeasonality(value: happySeasonality),
    orderFlow: any OrderTradeFlowServicing = StubOrderFlow(distributionValue: happyDistribution,
                                                           leaderboardValue: happyLeaderboard),
    analyst: any AnalystRatingsServicing = StubAnalystRatingsService(),
    governance: any GovernanceServicing = StubGovernanceService(),
    snapshot: any RegimeSnapshotProviding = StubSnapshot(value: makeSnapshot(valuation: 0.42, rate: .hike)),
    flow: any AggregateForeignFlowServicing = StubAggFlow(value: makeFlow(net: -1_500_000_000)),
    chart: any ChartServicing = StubChart(),
    commodity: any CommodityPriceServicing = StubCommodity(value: makeCommodity(changePercent: 0.35)),
    breadth: any BreadthServicing = StubBreadth(result: BreadthReading(above: 30, measured: 40)),
    sleeper: @escaping RequestThrottle.Sleeper = { _ in }
) -> StockbitDataProvider {
    StockbitDataProvider(
        universe: universe, keystats: keystats, fundachart: fundachart, statements: statements,
        emitten: emitten, priceFeed: priceFeed, broker: broker,
        comparisonService: comparison, seasonalityService: seasonality, orderFlowService: orderFlow,
        analyst: analyst, governance: governance, snapshotProvider: snapshot,
        flowService: flow, chartService: chart, commodityService: commodity, breadthService: breadth,
        breadthConstituents: ["BBCA"], sleeper: sleeper)
}

// MARK: - universe()

@Suite struct StockbitDataProviderUniverseTests {
    @Test func universeReturnsTheInjectedCandidateList() async throws {
        let provider = makeProvider(universe: ["WIFI", "BBCA", "ASII"])
        #expect(try await provider.universe() == ["WIFI", "BBCA", "ASII"])
    }
}

// MARK: - data(for:) composition

@Suite struct StockbitDataProviderCompositionTests {

    @Test func composesEveryAdapterIntoOneSecurityData() async throws {
        let s = try await makeProvider().data(for: "WIFI")

        // Company fields + TTM (keystats → §1.1, emitten → §1.4).
        #expect(s.ticker == "WIFI")
        #expect(s.sector == "Teknologi")
        #expect(s.freeFloatPct == 0.40)
        #expect(s.ttm.currentRatio == 3.09)
        #expect(abs(s.ttm.returnOnEquity - 0.0657) < 1e-9)
        #expect(s.ttm.epsGrowthPct == -11.46)

        // Price = last (ascending) close of the daily bars.
        #expect(s.price == 120)
        #expect(s.dailyBars.count == 3)
        #expect(s.foreignNetFlow == [bil(-5), bil(3), bil(8)])

        // Multi-year annuals (§1.2), ascending, balance-sheet overlaid (§1.3) on the latest year.
        #expect(s.financials.count == 3)
        let latest = try #require(s.financials.last)
        #expect(latest.year == 2025)
        #expect(latest.revenue == bil(1659))
        #expect(latest.shareholderEquity == bil(16196) - bil(9000))
        #expect(latest.currentAssets == Decimal(DisplayNumber.parseScaledDecimal("8,688 B")!))
        #expect(latest.currentLiabilities == Decimal(DisplayNumber.parseScaledDecimal("3,981 B")!))
        #expect(latest.receivables == Decimal(DisplayNumber.parseScaledDecimal("223 B")!))

        // Shares stamped on the latest annual only (§1.4); earlier years stay 0 (NCAV reads `.last`).
        #expect(s.sharesOutstanding == expectedShares)
        #expect(latest.sharesOutstanding == expectedShares)
        #expect(s.financials.first?.sharesOutstanding == 0)

        // Broker accumulation signal (§1.6): value-weighted Σnet/Σ(buy+sell) = 10/110.
        #expect(abs(s.brokerAccumulationSignal - 10.0 / 110.0) < 1e-9)

        // Index legs present (§1.5 sector map → IDXTECHNO; market → IHSG).
        #expect(!s.sectorIndexBars.isEmpty)
        #expect(!s.marketIndexBars.isEmpty)

        // Captured-endpoint overlays carried best-effort (Slice 4).
        #expect(s.peerComparison?.symbols == ["WIFI", "INDUSTRY", "SECTOR"])
        #expect(s.seasonality == nil)   // Phase 5: the seasonality tilt was dropped, so the slow leg no longer fetches it
        #expect(s.brokerDistribution?.buyConcentration() == 1.0)   // one buyer ⇒ 100% concentrated
    }

    /// The spine of the fetch-split refactor: fetching the SLOW + FAST legs separately and composing
    /// them must reproduce, byte-for-byte, what the single `data(for:)` fan-out builds. This is what
    /// lets a later phase source the two legs from different caches and still assemble a correct name.
    @Test func splitLegsComposeToTheSameSecurityDataAsDataFor() async throws {
        let provider = makeProvider()
        let fundamentals = try await provider.fundamentals(for: "WIFI")
        let live = try await provider.liveSignals(for: "WIFI", sectorIndexSymbol: fundamentals.sectorIndexSymbol)
        let composed = StockbitDataProvider.compose("WIFI", fundamentals: fundamentals, live: live)

        let direct = try await provider.data(for: "WIFI")
        #expect(composed == direct)
    }

    /// The slow leg resolves the sector-index symbol from `/emitten/info` so the fast leg can fetch
    /// sector bars on an intraday-only pass without re-reading info.
    @Test func slowLegCarriesTheResolvedSectorIndexSymbol() async throws {
        let fundamentals = try await makeProvider().fundamentals(for: "WIFI")
        #expect(fundamentals.sectorIndexSymbol == "IDXTECHNO")   // happyInfo indexes → IDXTECHNO
    }

    @Test func cachesSecurityDataPerSymbol() async throws {
        let keystats = StubKeystats(happyFields)
        let provider = makeProvider(keystats: keystats)
        _ = try await provider.data(for: "WIFI")
        _ = try await provider.data(for: "WIFI")
        #expect(await keystats.fieldsCallCount == 1)   // second call served from cache
    }
}

// MARK: - data(for:) degradation vs. propagation

@Suite struct StockbitDataProviderDegradationTests {

    @Test func degradesBestEffortLegsWithoutAbortingTheRun() async throws {
        let provider = makeProvider(
            statements: StubStatements(statement: nil),                       // balance-sheet overlay fails
            emitten: StubEmitten(infoResult: happyInfo, profileResult: nil),  // profile (free float) fails
            priceFeed: StubPriceFeed(barsBySymbol: ["WIFI": wifiBars],
                                     defaultBars: indexBars,
                                     throwingSymbols: ["IDXTECHNO", "IHSG"]),  // index bars fail
            broker: StubBroker(records: nil),                                 // broker signal fails
            comparison: StubComparison(value: nil),                           // peer ratios fail
            seasonality: StubSeasonality(value: nil),                         // seasonality fails
            orderFlow: StubOrderFlow(distributionValue: nil, leaderboardValue: nil))  // distribution fails

        let s = try await provider.data(for: "WIFI")

        #expect(s.price == 120)                       // essential legs still produced a valuation
        #expect(s.freeFloatPct == 0)                  // unverifiable float → conservative 0
        #expect(s.brokerAccumulationSignal == 0)      // no activity → no tilt
        #expect(s.sectorIndexBars.isEmpty)
        #expect(s.marketIndexBars.isEmpty)
        #expect(s.financials.last?.currentAssets == 0)   // overlay skipped → tree fields stay 0
        // Captured-endpoint overlays degrade to nil rather than aborting the pick.
        #expect(s.peerComparison == nil)
        #expect(s.seasonality == nil)
        #expect(s.brokerDistribution == nil)
    }

    @Test func propagatesWhenAnEssentialFieldIsMissing() async throws {
        var incomplete = happyFields
        incomplete["1498"] = nil   // drop Current Ratio — an industrial-required field
        let provider = makeProvider(keystats: StubKeystats(incomplete))

        await #expect(throws: SelectionFundamentals.AdapterError.self) {
            _ = try await provider.data(for: "WIFI")
        }
    }
}

// MARK: - data(for:) archetype routing (Phase 3.6)

@Suite struct StockbitDataProviderArchetypeTests {

    /// A BBCA-shaped keystats map: per-share + ROE present, but current ratio / D-E / EPS-growth are
    /// "-" (banks don't report them). On the industrial path `ttm(fromKeystats:)` throws `missingField`
    /// *before* a `SecurityData` is built — classifying by sector first lets the provider build it as
    /// a financial instead. Anchored to the BBCA capture (EPS 471.10, BVPS 2,102.07, ROE 22.41%).
    private static let bankFields: [String: String] = [
        "13200": "471.10", "15718": "2,102.07",
        "1498": "-", "1508": "-",          // banks report "-" for current ratio / D-E
        "1461": "22.41%", "1471": "-",     // ROE present; EPS-growth "-"
        "1555": "58,075 B", "1559": "1,640,831 B", "15883": "259,132 B",
        "2916": "63.17%", "1460": "3.54%",
    ]
    private static let bankInfo = EmittenInfo(
        symbol: "BBCA", name: "Bank Central Asia", sector: "Keuangan",
        subSector: "Bank", indexes: ["IDXFINANCE", "LQ45"])

    @Test func buildsAFinancialClassifiedSecurityDataForABank() async throws {
        let provider = makeProvider(
            keystats: StubKeystats(Self.bankFields),
            emitten: StubEmitten(infoResult: Self.bankInfo, profileResult: happyProfile),
            priceFeed: StubPriceFeed(barsBySymbol: ["BBCA": wifiBars], defaultBars: indexBars))

        // The whole point of 3.6: this no longer throws `missingField` upstream.
        let s = try await provider.data(for: "BBCA")

        #expect(s.sector == "Keuangan")
        #expect(CompanyArchetype.classify(sector: s.sector) == .financial)
        // The "-" solvency/growth fields degraded to 0 (no throw); the bank's own inputs survived.
        #expect(s.ttm.currentRatio == 0)
        #expect(s.ttm.debtToEquity == 0)
        #expect(s.ttm.epsGrowthPct == 0)
        #expect(abs(s.ttm.returnOnEquity - 0.2241) < 1e-9)
        #expect(s.price == 120)   // essential price leg still produced a valuation
    }
}

// MARK: - marketContext()

@Suite struct StockbitDataProviderMarketContextTests {

    @Test func mapsTheRegimeFanOutIntoMarketContext() async throws {
        let c = try await makeProvider().marketContext()
        #expect(c.indexValuationPercentile == 0.42)
        #expect(c.biRateRising == true)
        #expect(c.marketForeignFlowNet < 0)
        #expect(c.idrWeakeningTrend == true)             // USD/IDR +0.35%
        #expect(c.breadthAbove200dma == 0.75)            // 30 / 40
        #expect(c.indexAbove200dma == false)             // chart stub throws → distance absent
        #expect(c.flowLeaders?.topBuy.first?.code == "BBCA")   // top-stock leaderboard carried (Slice 4)
    }

    @Test func degradesFlowLeadersToNilWhenTopStockFails() async throws {
        let provider = makeProvider(
            orderFlow: StubOrderFlow(distributionValue: happyDistribution, leaderboardValue: nil))
        let c = try await provider.marketContext()
        #expect(c.flowLeaders == nil)                    // best-effort leg degrades, regime still scores
        #expect(c.indexValuationPercentile == 0.42)      // the rest of the context is unaffected
    }

    @Test func throwsWhenEveryRegimeInputIsAbsent() async throws {
        let provider = makeProvider(
            snapshot: StubSnapshot(value: nil),
            flow: StubAggFlow(value: nil),
            commodity: StubCommodity(value: nil),
            breadth: StubBreadth(result: BreadthReading(above: 0, measured: 0)))   // fraction nil
        await #expect(throws: SelectionProviderError.noRegimeInputs) {
            _ = try await provider.marketContext()
        }
    }

    // The export-basket → commodityTailwind wiring (the China-channel feeding the *selection*
    // regime). Before this the provider passed `commodityChangePercent: nil`, so `commodityTailwind`
    // was always false regardless of Indonesia's terms of trade. These pin that the live fan-out now
    // reads the SAME coal/CPO/nickel basket the displayed China-channel reads (oil excluded) and
    // sets the tailwind from its mean daily move — independent of the USD/IDR leg.

    @Test func readsTheExportBasketIntoCommodityTailwind() async throws {
        let provider = makeProvider(commodity: StubCommodityBySymbol(changeBySymbol: [
            "USDIDR": -0.50,                                   // rupiah strengthening — not an FX stress
            "COAL-NEWCASTLE": 1.5, "CPO": 2.1, "NICKEL": 0.9,  // export basket rising → tailwind
        ]))
        let c = try await provider.marketContext()
        #expect(c.commodityTailwind == true)
    }

    @Test func noTailwindWhenTheExportBasketIsFalling() async throws {
        let provider = makeProvider(commodity: StubCommodityBySymbol(changeBySymbol: [
            "USDIDR": 0.50,                                       // even with FX "stress"…
            "COAL-NEWCASTLE": -1.2, "CPO": -0.4, "NICKEL": -2.0,  // …a falling basket = no tailwind
        ]))
        let c = try await provider.marketContext()
        #expect(c.commodityTailwind == false)
    }

    @Test func degradesToNoTailwindWhenNoBasketCommodityPrices() async throws {
        // Basket legs all fail to price, but the rest of the regime is present: the context still
        // builds (no phantom-regime throw) and the absent basket reads as no tailwind, not a
        // fabricated one — matching the adapter's neutral degradation policy.
        let provider = makeProvider(commodity: StubCommodityBySymbol(changeBySymbol: [:]))
        let c = try await provider.marketContext()
        #expect(c.commodityTailwind == false)
        #expect(c.indexValuationPercentile == 0.42)   // the rest of the regime is unaffected
    }
}

// MARK: - Throttle

// MARK: - Daily-bars request window

@Suite struct StockbitDataProviderRequestWindowTests {

    /// Regression for the ELSA 400: Stockbit's `company-price-feed/historical/summary` rejects a
    /// >1-year range with `INVALID_PARAMETER`. The only live-verified span is ≤ 1 year, which still
    /// over-covers the engine's longest lookback (`timing.betaLookback` = 252 trading days). The
    /// provider's daily-bars window must therefore never exceed one year.
    @Test func requestsAtMostOneYearOfDailyBars() async throws {
        let recorder = SpanRecorder()
        let provider = makeProvider(
            priceFeed: SpanSpyPriceFeed(recorder: recorder,
                                        barsBySymbol: ["WIFI": wifiBars], defaultBars: indexBars))
        _ = try await provider.data(for: "WIFI")
        let oneYear: TimeInterval = 366 * 24 * 60 * 60   // a day of leap-margin over 365
        #expect(await recorder.maxSpan <= oneYear)
    }
}

@Suite struct StockbitDataProviderThrottleTests {

    @Test func pacesThePerTickerFanOutThroughTheSharedThrottle() async throws {
        let recorder = DelayRecorder()
        let provider = makeProvider(sleeper: { await recorder.record($0) })
        _ = try await provider.data(for: "WIFI")
        // Many paced calls (keystats + 3× fundachart + info + bars + statements + profile + 2 index
        // + broker + the 3 Slice-4 overlays): the first is free, every later one sleeps — so several
        // delays were requested.
        #expect(await recorder.delays.count >= 5)
    }
}
