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
        ScreenerInitialResult(
            config: ScreenerConfig(),
            page: ScreenerPage(rows: UITestFixtures.screenerRows, total: UITestFixtures.screenerRows.count, page: 1))
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
}
