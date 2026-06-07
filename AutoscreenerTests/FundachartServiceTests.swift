import Foundation
import Testing
@testable import Autoscreener

// Fixtures are the verbatim WIFI fundachart bodies from the 2026-06-06 capture
// (GET fundachart/v2/WIFI/financials?data_type={1,2,3}&report=2 — annual). y_axis carries raw
// JSON numbers; x_axis is fiscal years, newest-first.

private let incomeJSON = Data(#"""
{"message":"Financial chart data retrieved","data":{"x_axis":["2025","2024","2023","2022","2021"],"chart_data":[{"legend":"Net Margin","color":"#6FE7DD","currency_scale":"%","chart_type":"CHART_TYPE_LINE_CHART","label":["24.62","34.41","13.33","12.68","6.6"],"y_axis":[24.62,34.41,13.33,12.68,6.6]},{"legend":"Revenue","color":"#6639A6","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["1.7T","0.7T","439.3B","461.2B","391B"],"y_axis":[1659396000000,671854000000,439326380000,461252700000,390957100000]},{"legend":"Net Income","color":"#3490DE","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["408.5B","231.2B","58.5B","58.5B","25.8B"],"y_axis":[408551230000,231186780000,58543330000,58489836000,25819298000]}]}}
"""#.utf8)

private let balanceJSON = Data(#"""
{"message":"Financial chart data retrieved","data":{"x_axis":["2025","2024","2023","2022","2021"],"chart_data":[{"legend":"Debt Equity Ratio","color":"#6FE7DD","currency_scale":"","chart_type":"CHART_TYPE_LINE_CHART","label":["0.48","0.85","0.45","0.63","0.3"],"y_axis":[0.48,0.85,0.45,0.63,0.3]},{"legend":"Total Assets","color":"#6639A6","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["15.2T","2.9T","1.6T","1.4T","0.9T"],"y_axis":[15169662000000,2907415800000,1564229600000,1407734400000,896309460000]},{"legend":"Total Liabilities","color":"#3490DE","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["6.7T","1.9T","0.8T","0.8T","380.4B"],"y_axis":[6651717400000,1937572400000,821583600000,795007400000,380354040000]}]}}
"""#.utf8)

private let cashFlowJSON = Data(#"""
{"message":"Financial chart data retrieved","data":{"x_axis":["2025","2024","2023","2022","2021"],"chart_data":[{"legend":"Operating","color":"#6639A6","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["-0.8T","418.8B","224.8B","55.3B","108B"],"y_axis":[-814048350000,418779800000,224815350000,55297950000,107984910000]},{"legend":"Investing","color":"#3490DE","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["-3.9T","-1.5T","-204.8B","-329.3B","-291.4B"],"y_axis":[-3944132400000,-1477352000000,-204797970000,-329276850000,-291389640000]},{"legend":"Financing","color":"#DB3D6D","currency_scale":"T","chart_type":"CHART_TYPE_BAR_CHART","label":["10.9T","1T","-0.9B","284.3B","167.8B"],"y_axis":[10909103000000,1039495660000,-873611800,284342200000,167757710000]}]}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct FundachartEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQueryForAnnualIncome() {
        let ep = FundachartService.makeEndpoint(symbol: "WIFI", dataset: .incomeStatement, report: .annual)
        #expect(ep.method == .get)
        #expect(ep.path == "fundachart/v2/WIFI/financials")
        #expect(ep.requiresAuth)
        let q = query(ep)
        #expect(q["data_type"] == "1")
        #expect(q["report"] == "2")
    }

    @Test func datasetAndReportMapToRawQueryValues() {
        #expect(query(FundachartService.makeEndpoint(symbol: "X", dataset: .balanceSheet, report: .annual))["data_type"] == "2")
        #expect(query(FundachartService.makeEndpoint(symbol: "X", dataset: .cashFlow, report: .annual))["data_type"] == "3")
        #expect(query(FundachartService.makeEndpoint(symbol: "X", dataset: .incomeStatement, report: .quarterly))["report"] == "1")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct FundachartParseTests {
    @Test func parsesPeriodsNewestFirstAndRawYAxis() throws {
        let f = try FundachartService.parse(incomeJSON)
        #expect(f.periods == ["2025", "2024", "2023", "2022", "2021"])
        #expect(f.series.map(\.legend) == ["Net Margin", "Revenue", "Net Income"])
        // y_axis are raw numbers (no display parsing): Revenue 2025 = 1,659,396,000,000.
        #expect(f.value(legend: "Revenue", period: "2025") == Decimal(1_659_396_000_000))
        #expect(f.value(legend: "Net Income", period: "2021") == Decimal(25_819_298_000))
    }

    @Test func valueLookupIsCaseInsensitiveAndPeriodKeyed() throws {
        let f = try FundachartService.parse(balanceJSON)
        #expect(f.value(legend: "total assets", period: "2024") == Decimal(2_907_415_800_000))
        #expect(f.value(legend: "Total Liabilities", period: "2021") == Decimal(380_354_040_000))
        #expect(f.value(legend: "Nonexistent", period: "2025") == nil)
        #expect(f.value(legend: "Total Assets", period: "1999") == nil)
    }

    @Test func parsesNegativeCashFlowValues() throws {
        let f = try FundachartService.parse(cashFlowJSON)
        #expect(f.value(legend: "Operating", period: "2025") == Decimal(-814_048_350_000))
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try FundachartService.parse(Data("not json".utf8)) }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct FundachartServiceErrorMappingTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = FundachartService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: FundachartError.unauthorized) {
            _ = try await svc.financials(symbol: "WIFI", dataset: .incomeStatement, report: .annual)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = FundachartService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: FundachartError.paywall) {
            _ = try await svc.financials(symbol: "WIFI", dataset: .incomeStatement, report: .annual)
        }
    }

    @Test func happyPathParsesAnnualIncome() async throws {
        let svc = FundachartService(apiClient: signedInClient([.init(status: 200, body: incomeJSON)]))
        let f = try await svc.financials(symbol: "WIFI", dataset: .incomeStatement, report: .annual)
        #expect(f.periods.count == 5)
        #expect(f.value(legend: "Revenue", period: "2025") == Decimal(1_659_396_000_000))
    }
}

// MARK: - fundachart → [AnnualFinancials] (Phase 1.2 adapter)

@Suite struct FundachartAnnualFinancialsAdapterTests {
    private func wifiAnnuals() throws -> [AnnualFinancials] {
        SelectionFundamentals.annualFinancials(
            income: try FundachartService.parse(incomeJSON),
            balance: try FundachartService.parse(balanceJSON),
            cashFlow: try FundachartService.parse(cashFlowJSON))
    }

    @Test func joinsFiveYearsAscendingOldestToNewest() throws {
        let years = try wifiAnnuals().map(\.year)
        #expect(years == [2021, 2022, 2023, 2024, 2025])
    }

    @Test func mapsTheCoreFieldsForTheLatestYear() throws {
        let latest = try #require(try wifiAnnuals().last)   // 2025
        #expect(latest.year == 2025)
        #expect(latest.revenue == Decimal(1_659_396_000_000))
        #expect(latest.netIncome == Decimal(408_551_230_000))
        #expect(latest.totalAssets == Decimal(15_169_662_000_000))
        #expect(latest.totalLiabilities == Decimal(6_651_717_400_000))
        #expect(latest.operatingCashFlow == Decimal(-814_048_350_000))
        // shareholderEquity = assets − liabilities (the §1.2 identity).
        #expect(latest.shareholderEquity == Decimal(15_169_662_000_000 - 6_651_717_400_000))
    }

    @Test func leavesDeferredTreeAndShareFieldsAtZero() throws {
        // currentAssets/currentLiabilities/receivables (§1.3) and sharesOutstanding (§1.4) are not
        // charted — left 0 so the engine's guarded consumers simply skip them.
        for f in try wifiAnnuals() {
            #expect(f.currentAssets == 0)
            #expect(f.currentLiabilities == 0)
            #expect(f.receivables == 0)
            #expect(f.sharesOutstanding == 0)
        }
    }

    @Test func skipsPeriodsThatAreNotPlainFiscalYears() {
        // A quarterly x_axis ("Q1 2026") or a year missing a core figure is dropped, not emitted partial.
        let income = FundachartFinancials(periods: ["Q1 2026", "2024"], series: [
            FundachartSeries(legend: "Revenue", values: [100, 200]),
            FundachartSeries(legend: "Net Income", values: [10, 20]),
        ])
        let balance = FundachartFinancials(periods: ["Q1 2026", "2024"], series: [
            FundachartSeries(legend: "Total Assets", values: [1000, 2000]),
            FundachartSeries(legend: "Total Liabilities", values: [400, 800]),
        ])
        let cashFlow = FundachartFinancials(periods: ["Q1 2026", "2024"], series: [
            FundachartSeries(legend: "Operating", values: [5, 50]),
        ])
        let annuals = SelectionFundamentals.annualFinancials(income: income, balance: balance, cashFlow: cashFlow)
        #expect(annuals.map(\.year) == [2024])
        #expect(annuals.first?.shareholderEquity == Decimal(1200))   // 2000 − 800
    }
}
