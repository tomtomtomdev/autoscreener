import Foundation

extension ProcessInfo {
    /// True when launched by the XCUITest suite with canned, offline data. Lets the
    /// app render the signed-in screener + stock-detail flow deterministically —
    /// no Keychain, no auth, no network. Distinct from `-UITesting`, which freezes
    /// the app on the "Checking session…" splash.
    var isUITestFixtures: Bool { arguments.contains("-UITestFixtures") }
}

// MARK: - Canned services used only under -UITestFixtures

nonisolated struct StubPaywallService: PaywallServicing {
    func check(_ feature: PaywallFeature) async -> PaywallEligibility {
        PaywallEligibility(eligible: true, message: nil)
    }
    func increment(_ feature: PaywallFeature) async {}
}

nonisolated struct StubScreenerTemplateService: ScreenerTemplateServicing {
    func load(templateID: String) async throws -> ScreenerInitialResult {
        // The intraday-liquidity veto gate (6676320) deliberately omits GOTO, so the
        // composite Watchlist excludes it (fails a veto gate) while the per-screener
        // tabs still list all three. Every other screener returns all three rows.
        let rows = templateID == "6676320"
            ? UITestFixtures.screenerRows.filter { $0.symbol != "GOTO" }
            : UITestFixtures.screenerRows
        return ScreenerInitialResult(
            config: ScreenerConfig(),
            page: ScreenerPage(rows: rows, total: rows.count, page: 1))
    }
}

nonisolated struct StubScreenerService: ScreenerServicing {
    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
        // Page 1 arrives via the template service; signal "no more pages".
        ScreenerPage(rows: [], total: UITestFixtures.screenerRows.count, page: page)
    }
}

nonisolated struct StubFinancialStatementService: FinancialStatementServicing {
    func load(symbol: String,
              report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement {
        UITestFixtures.statement(report: report, basis: basis)
    }
}

nonisolated struct StubKeystatsRatioService: KeystatsRatioServicing {
    func ratios(symbol: String, yearLimit: Int) async throws -> ValuationRatios {
        ValuationRatios(
            symbol: symbol,
            pe: 12.07, peTTM: 5.68, priceToSales: 0.81, priceToBook: 1.81,
            priceToCashFlow: 15.09, priceToFreeCashFlow: -22.24, evToEBITDA: 31.66,
            eps: 242.08, bookValuePerShare: 759.60, cashPerShare: 555.47,
            freeCashFlowPerShare: -61.83, currentRatio: 3.09, quickRatio: 2.45, debtToEquity: 1.38
        )
    }
    // Not exercised under UI fixtures — no screen consumes the selection engine yet.
    func fields(symbol: String, yearLimit: Int) async throws -> [String: String] { [:] }
}

nonisolated struct StubBrokerSummaryService: BrokerSummaryServicing {
    func summary(symbol: String,
                 period: BrokerSummaryPeriod,
                 limit: Int) async throws -> BrokerSummary {
        UITestFixtures.brokerSummary(symbol: symbol)
    }
}

nonisolated struct StubForeignFlowService: ForeignFlowServicing {
    func flow(symbol: String,
              period: ForeignFlowPeriod,
              marketType: ForeignFlowMarketType) async throws -> ForeignFlow {
        UITestFixtures.foreignFlow(symbol: symbol)
    }
}

nonisolated struct StubChartService: ChartServicing {
    func candles(symbol: String,
                 timeframe: ChartTimeframe,
                 chartType: ChartType) async throws -> PriceSeries {
        UITestFixtures.priceSeries(symbol: symbol, timeframe: timeframe)
    }
}

nonisolated struct StubCommodityPriceService: CommodityPriceServicing {
    func quote(symbol: String) async throws -> CommodityQuote {
        UITestFixtures.commodityQuote(symbol: symbol)
    }
}

nonisolated struct StubRegimeSnapshotService: RegimeSnapshotProviding {
    func snapshot() async throws -> RegimeSnapshot { UITestFixtures.regimeSnapshot }
}

nonisolated struct StubBreadthService: BreadthServicing {
    func reading(symbols: [String], period: Int) async -> BreadthReading {
        // 28 of 45 LQ45 above their 200-day average → 62% → broad (risk-on).
        BreadthReading(above: 28, measured: 45)
    }
}

// The four services the headless selection engine consumes. No screen drives the engine under UI
// fixtures yet, so these return benign empties rather than canned data — they exist only to keep
// AppDependencies' "every leaf service stubbed under fixtures" invariant (no accidental network).

nonisolated struct StubFundachartService: FundachartServicing {
    func financials(symbol: String, dataset: FundachartDataset,
                    report: FundachartReport) async throws -> FundachartFinancials {
        FundachartFinancials(periods: [], series: [])
    }
}

nonisolated struct StubEmittenService: EmittenServicing {
    func info(symbol: String) async throws -> EmittenInfo {
        EmittenInfo(symbol: symbol, name: symbol, sector: "", subSector: "", indexes: [])
    }
    func profile(symbol: String) async throws -> EmittenProfile {
        EmittenProfile(freeFloatDisplay: "", sharesDisplay: "")
    }
}

nonisolated struct StubCompanyPriceFeedService: CompanyPriceFeedServicing {
    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod, startDate: Date,
                           endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage {
        HistoricalSummaryPage(bars: [], nextPage: nil)
    }
}

nonisolated struct StubBrokerActivityService: BrokerActivityServicing {
    func dailyActivity(symbol: String, period: BrokerActivityPeriod, brokerCodes: [String],
                       limit: Int, page: Int) async throws -> [BrokerActivityRecord] { [] }
}

enum UITestFixtures {
    static let screenerRows: [ScreenerRow] = [
        ScreenerRow(symbol: "BBCA", name: "Bank Central Asia Tbk.", values: [9_876.0, 8_000.0], lastPrice: nil, pctChange: nil),
        ScreenerRow(symbol: "TLKM", name: "Telkom Indonesia Tbk.", values: [4_321.0, 3_900.0], lastPrice: nil, pctChange: nil),
        ScreenerRow(symbol: "GOTO", name: "GoTo Gojek Tokopedia Tbk.", values: [1_234.0, 1_000.0], lastPrice: nil, pctChange: nil),
    ]

    static func statement(report: FinancialReportType, basis: FinancialPeriodBasis) -> FinancialStatement {
        let periods = basis == .annual ? ["12M 2025", "12M 2024"] : ["Q1 2026", "Q4 2025"]
        let accounts: [FinancialAccount]
        switch report {
        case .income:
            accounts = [
                leaf("0", 127, "Pendapatan", ["115,672 B", "28,298 B"], emphasized: true),
                leaf("1", 131, "Beban Pokok Penjualan", ["(116,372 B)", "(25,807 B)"]),
                leaf("2", 134, "Laba Kotor", ["(700 B)", "2,491 B"], emphasized: true),
            ]
        case .balanceSheet:
            accounts = [
                leaf("0", 1, "Aset", ["206,036 B", "91,507 B"], emphasized: true),
                leaf("1", 41, "Liabilitas Dan Ekuitas", ["206,036 B", "91,507 B"], emphasized: true),
            ]
        case .cashFlow:
            accounts = [
                leaf("0", 200, "Arus Kas Dari Aktivitas Operasi", ["12,345 B", "6,789 B"], emphasized: true),
                leaf("1", 210, "Arus Kas Dari Aktivitas Investasi", ["(3,210 B)", "(1,500 B)"]),
            ]
        }
        return FinancialStatement(currency: "IDR", periods: periods, accounts: accounts)
    }

    private static func leaf(_ id: String, _ accountID: Int, _ name: String, _ values: [String], emphasized: Bool = false) -> FinancialAccount {
        FinancialAccount(id: id, accountID: accountID, name: name, level: 1,
                         values: values, isEmphasized: emphasized, defaultExpanded: false, children: [])
    }

    static func brokerSummary(symbol: String) -> BrokerSummary {
        func bucket(_ accdist: String, _ amount: Double, _ percent: Double) -> BandarBucket {
            BandarBucket(accdist: accdist, amount: amount, percent: percent, volume: amount / 1700)
        }
        func leg(_ code: String, _ value: Double, _ avg: Double, _ cat: InvestorCategory) -> BrokerLeg {
            BrokerLeg(brokerCode: code, averagePrice: avg, lot: value / avg / 100,
                      lotGross: value / avg / 100, value: value, valueGross: Swift.abs(value),
                      frequency: 1_000, category: cat, date: "20260603")
        }
        let detector = BandarDetector(
            accdist: "Dist", averagePrice: 1_702, numberBrokerBuySell: 52,
            totalBuyer: 65, totalSeller: 13, totalValue: 1_243_143_300_000, totalVolume: 7_302_767,
            avg: bucket("Dist", -24_000_000_000, -2.0), avg5: bucket("Dist", -120_000_000_000, -10.0),
            top1: bucket("Big Dist", -100_000_000_000, -8.0), top3: bucket("Big Dist", -240_000_000_000, -19.0),
            top5: bucket("Big Dist", -322_021_520_000, -25.9), top10: bucket("Big Dist", -360_000_000_000, -29.0))
        return BrokerSummary(
            symbol: symbol, from: "2026-06-03", to: "2026-06-03",
            buyers: [leg("ZP", 568_662_750_500, 1_666, .foreign),
                     leg("BK", 120_000_000_000, 1_690, .foreign),
                     leg("CC", 64_000_000_000, 1_695, .domestic)],
            sellers: [leg("YU", -1_023_119_740_500, 1_697, .foreign),
                      leg("AK", -210_000_000_000, 1_705, .domestic),
                      leg("DR", -80_000_000_000, 1_701, .domestic)],
            detector: detector)
    }

    /// Deterministic, offline OHLCV series for the chart view under UI tests.
    /// 20 daily bars walking up from 1000 with alternating up/down candles.
    static func priceSeries(symbol: String, timeframe: ChartTimeframe) -> PriceSeries {
        let day: TimeInterval = 86_400
        let start: TimeInterval = 1_748_000_000   // fixed epoch, no Date.now()
        let candles: [PriceCandle] = (0..<20).map { i in
            let base = 1_000.0 + Double(i) * 10
            let up = i % 2 == 0
            let open = base
            let close = up ? base + 8 : base - 8
            return PriceCandle(
                date: Date(timeIntervalSince1970: start + Double(i) * day),
                open: open,
                high: Swift.max(open, close) + 5,
                low: Swift.min(open, close) - 5,
                close: close,
                volume: 1_000_000 + Double(i) * 50_000)
        }
        return PriceSeries(symbol: symbol, timeframe: timeframe, previousClose: 1_000, candles: candles)
    }

    /// Deterministic commodity/FX quote for the Markets list under UI tests.
    /// A couple of symbols are seeded as "down" so the red styling is exercised.
    static func commodityQuote(symbol: String) -> CommodityQuote {
        let down = symbol == "OIL" || symbol == "GAS"
        return CommodityQuote(
            symbol: symbol,
            name: symbol,
            price: 100,
            previousClose: down ? 102 : 98,
            change: down ? -2 : 2,
            changePercent: down ? -1.96 : 2.04,
            volume: 12_345,
            formattedPrice: "100",
            asOf: "Thu 14:22")
    }

    /// Deterministic regime snapshot for the Market Regime screen under UI tests:
    /// composite valuation mid-range (P/E·P/B ≈ 49th pctile → neutral) with the BI
    /// rate tightening (a hike → risk-off), mirroring the live BI 7-day reverse repo
    /// rate of 5.50% (last move 9 Jun 2026, a hike from 5.25%).
    static let regimeSnapshot = RegimeSnapshot(
        asOf: "2026-01-31",
        biRate: RegimeSnapshot.BIRate(value: 5.50, direction: .hike, asOf: "2026-06-09"),
        macro: RegimeSnapshot.MacroBlock(
            usFedFunds: RegimeSnapshot.MacroSeries(value: 4.33, trend: .down, asOf: "2026-01-31"),
            us10y: RegimeSnapshot.MacroSeries(value: 4.10, trend: .down, asOf: "2026-01-31"),
            broadDollar: RegimeSnapshot.MacroSeries(value: 119.0, trend: .flat, asOf: "2026-01-31")),
        indices: [
            "COMPOSITE": RegimeSnapshot.IndexValuation(pe: 13.2, pb: 2.1, pePctile: 0.42, pbPctile: 0.55),
            "LQ45": RegimeSnapshot.IndexValuation(pe: 12.1, pb: 1.9, pePctile: 0.38, pbPctile: 0.49),
        ])

    static func foreignFlow(symbol: String) -> ForeignFlow {
        func m(_ raw: Double, _ f: String) -> FlowMetric { FlowMetric(raw: raw, formatted: f) }
        let value = ForeignFlowBreakdown(
            label: "Value (IDR)", total: m(2_594_529_577_500, "2.59 T"),
            foreignTotal: m(2_645_694_406_000, "2.65 T"), foreignPercentage: 50.99,
            domesticTotal: m(2_543_364_749_000, "2.54 T"), domesticPercentage: 49.01)
        let volume = ForeignFlowBreakdown(
            label: "Volume", total: m(7_302_767, "7.30 M"),
            foreignTotal: m(3_700_000, "3.70 M"), foreignPercentage: 50.7,
            domesticTotal: m(3_602_767, "3.60 M"), domesticPercentage: 49.3)
        let frequency = ForeignFlowBreakdown(
            label: "Frequency", total: m(120_000, "120.00 K"),
            foreignTotal: m(58_000, "58.00 K"), foreignPercentage: 48.3,
            domesticTotal: m(62_000, "62.00 K"), domesticPercentage: 51.7)
        return ForeignFlow(
            symbol: symbol, dateRange: "3 Jun 2026", from: "2026-06-03", to: "2026-06-03",
            lastUpdated: "3 Jun 2026",
            foreignBuy: m(1_142_496_692_500, "1.14 T"),
            foreignSell: m(1_503_197_713_500, "1.50 T"),
            netForeign: m(-360_701_021_000, "-360.70 B"),
            domesticBuy: m(1_452_032_885_000, "1.45 T"),
            domesticSell: m(1_091_331_864_000, "1.09 T"),
            netDomestic: m(360_701_021_000, "360.70 B"),
            value: value, volume: volume, frequency: frequency)
    }

    /// Canned Tier-A recommendations for the "Today's Picks" screen under UI tests. Two ranked picks
    /// — an industrial (Graham path) and a bank (justified-P/B path) — each carrying an audit trail
    /// shaped like the engine's real output, so the screen's rows and expandable rationale render
    /// deterministically offline. No engine fan-out runs under fixtures (the per-ticker leaf services
    /// are empty stubs); this is the stand-in the screen reads via `AppDependencies.todaysPicks`.
    static let recommendations: [Recommendation] = [
        Recommendation(
            ticker: "WIFI", compositeScore: 0.74, intrinsicValue: 6_364,
            marginOfSafety: 0.31, conviction: 0.74, suggestedWeight: 0.089,
            audit: [
                "regime=Neutral",
                "✓ DataIntegrity",
                "✓ Solvency",
                "✓ Liquidity",
                "MoS 31% vs req 25%",
                "value 0.81 — Graham discount",
                "quality 0.66 — ROE 18%",
                "flow +0.020 [foreign accumulating]",
                "timing +0.010 [measured β 1.10/0.30]",
                "→ conviction 0.74 weight 9%",
            ]),
        Recommendation(
            ticker: "BBNI", compositeScore: 0.58, intrinsicValue: 5_980,
            marginOfSafety: 0.27, conviction: 0.58, suggestedWeight: 0.058,
            audit: [
                "regime=Neutral",
                "✓ DataIntegrity",
                "✓ Liquidity",
                "✓ CapitalStrength (proxy: equity/assets)",
                "MoS 27% vs req 25%",
                "bankValue 0.62 — P/B below ROE-justified",
                "bankQuality 0.55 — ROE 14%, ROA 2%",
                "→ conviction 0.58 weight 6%",
            ]),
    ]
}
