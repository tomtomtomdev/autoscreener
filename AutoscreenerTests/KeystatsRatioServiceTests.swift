import Foundation
import Testing
@testable import Autoscreener

// MARK: - Endpoint wire format

@Suite struct KeystatsRatioEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    @Test func buildsPathAndYearLimit() {
        let ep = KeystatsRatioService.makeEndpoint(symbol: "TPIA", yearLimit: 10)
        #expect(ep.method == .get)
        #expect(ep.path == "keystats/ratio/v1/TPIA")
        #expect(query(ep)["year_limit"] == "10")
    }

    @Test func defaultsToTenYears() {
        #expect(query(KeystatsRatioService.makeEndpoint(symbol: "BBCA"))["year_limit"] == "10")
    }
}

// MARK: - Graham Number

@Suite struct GrahamNumberTests {
    @Test func computesSquareRootOfTwentyTwoPointFiveEpsBvps() {
        // 22.5 · 100 · 1000 = 2,250,000 → √ = 1500.
        #expect(GrahamNumber.value(eps: 100, bookValuePerShare: 1000) == 1500)
    }

    @Test func nilForLossMaker() {
        #expect(GrahamNumber.value(eps: -5, bookValuePerShare: 1000) == nil)
    }

    @Test func nilForNonPositiveBookValue() {
        #expect(GrahamNumber.value(eps: 100, bookValuePerShare: 0) == nil)
        #expect(GrahamNumber.value(eps: 100, bookValuePerShare: -50) == nil)
    }

    @Test func nilWhenInputsMissing() {
        #expect(GrahamNumber.value(eps: nil, bookValuePerShare: 1000) == nil)
        #expect(GrahamNumber.value(eps: 100, bookValuePerShare: nil) == nil)
    }

    @Test func marginOfSafetyPositiveWhenBelowFairValue() {
        // Graham = 1500; buying at 1200 → 20% discount.
        let mos = GrahamNumber.marginOfSafety(price: 1200, eps: 100, bookValuePerShare: 1000)
        #expect(mos != nil)
        #expect(abs(mos! - 0.2) < 1e-9)
    }

    @Test func marginOfSafetyNegativeWhenAtPremium() {
        // Graham = 1500; buying at 1800 → −20% (premium).
        let mos = GrahamNumber.marginOfSafety(price: 1800, eps: 100, bookValuePerShare: 1000)
        #expect(mos != nil)
        #expect(abs(mos! + 0.2) < 1e-9)
    }

    @Test func marginOfSafetyNilWithoutGrahamNumber() {
        #expect(GrahamNumber.marginOfSafety(price: 1000, eps: -5, bookValuePerShare: 1000) == nil)
    }

    @Test func valuationRatiosExposesGrahamHelpers() {
        let r = ValuationRatios.fixture(eps: 100, bookValuePerShare: 1000)
        #expect(r.grahamNumber == 1500)
        #expect(abs(r.marginOfSafety(atPrice: 1200)! - 0.2) < 1e-9)
        #expect(ValuationRatios.fixture(eps: -5, bookValuePerShare: 1000).grahamNumber == nil)
    }
}

// MARK: - Response parsing

@Suite struct KeystatsRatioParseTests {
    // Trimmed from the live TPIA capture (keystats/ratio/v1/TPIA?year_limit=10):
    // the Valuation, Per Share, and Solvency groups we map. Values are verbatim.
    static let tpia = Data(#"""
    {"data":{"closure_fin_items_results":[
      {"keystats_name":"Valuation","fin_name_results":[
        {"fitem":{"id":"12148","name":"Current PE Ratio (Annualised)","value":"12.07"}},
        {"fitem":{"id":"2891","name":"Current PE Ratio (TTM)","value":"5.68"}},
        {"fitem":{"id":"16577","name":"Forward PE Ratio","value":"-"}},
        {"fitem":{"id":"2893","name":"Current Price to Sales (TTM)","value":"0.81"}},
        {"fitem":{"id":"2896","name":"Current Price to Book Value","value":"1.81"}},
        {"fitem":{"id":"16533","name":"Current Price To Cashflow (TTM)","value":"15.09"}},
        {"fitem":{"id":"15881","name":"Current Price To Free Cashflow (TTM)","value":"-22.24"}},
        {"fitem":{"id":"21457","name":"EV to EBITDA (TTM)","value":"31.66"}}
      ]},
      {"keystats_name":"Per Share","fin_name_results":[
        {"fitem":{"id":"13200","name":"Current EPS (TTM)","value":"242.08"}},
        {"fitem":{"id":"12988","name":"Current EPS (Annualised)","value":"113.90"}},
        {"fitem":{"id":"15880","name":"Revenue Per Share (TTM)","value":"1,688.51"}},
        {"fitem":{"id":"15879","name":"Cash Per Share (Quarter)","value":"555.47"}},
        {"fitem":{"id":"15718","name":"Current Book Value Per Share","value":"759.60"}},
        {"fitem":{"id":"15882","name":"Free Cashflow Per Share (TTM)","value":"-61.83"}}
      ]},
      {"keystats_name":"Solvency","fin_name_results":[
        {"fitem":{"id":"1498","name":"Current Ratio (Quarter)","value":"3.09"}},
        {"fitem":{"id":"1500","name":"Quick Ratio (Quarter)","value":"2.45"}},
        {"fitem":{"id":"1508","name":"Debt to Equity Ratio (Quarter)","value":"1.38"}}
      ]}
    ]}}
    """#.utf8)

    @Test func mapsValuationGroup() throws {
        let r = try KeystatsRatioService.parse(Self.tpia, symbol: "TPIA")
        #expect(r.symbol == "TPIA")
        #expect(r.pe == 12.07)
        #expect(r.peTTM == 5.68)
        #expect(r.priceToSales == 0.81)
        #expect(r.priceToBook == 1.81)
        #expect(r.priceToCashFlow == 15.09)
        #expect(r.priceToFreeCashFlow == -22.24)
        #expect(r.evToEBITDA == 31.66)
    }

    @Test func mapsPerShareAndSolvency() throws {
        let r = try KeystatsRatioService.parse(Self.tpia, symbol: "TPIA")
        #expect(r.eps == 242.08)                 // TTM
        #expect(r.bookValuePerShare == 759.60)
        #expect(r.cashPerShare == 555.47)
        #expect(r.freeCashFlowPerShare == -61.83)
        // Solvency — matches the figures recorded in idx-regime-data-research.md §2.
        #expect(r.currentRatio == 3.09)
        #expect(r.quickRatio == 2.45)
        #expect(r.debtToEquity == 1.38)
    }

    @Test func grahamNumberFromLiveInputs() throws {
        let r = try KeystatsRatioService.parse(Self.tpia, symbol: "TPIA")
        // √(22.5 · 242.08 · 759.60) ≈ 2034.06
        #expect(abs(r.grahamNumber! - 2034.06) < 0.5)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try KeystatsRatioService.parse(Data("not json".utf8), symbol: "X")
        }
    }
}

// MARK: - Display-string parsing

@Suite struct KeystatsDecimalParsingTests {
    @Test func parsesPlainAndSignedDecimals() {
        #expect(KeystatsRatioService.parseDisplayDecimal("12.07") == 12.07)
        #expect(KeystatsRatioService.parseDisplayDecimal("-22.24") == -22.24)
    }

    @Test func stripsThousandsSeparators() {
        #expect(KeystatsRatioService.parseDisplayDecimal("1,688.51") == 1688.51)
    }

    @Test func treatsDashAndEmptyAsMissing() {
        #expect(KeystatsRatioService.parseDisplayDecimal("-") == nil)
        #expect(KeystatsRatioService.parseDisplayDecimal("") == nil)
        #expect(KeystatsRatioService.parseDisplayDecimal("  ") == nil)
    }

    @Test func handlesPercentAndParenthesisedNegatives() {
        #expect(KeystatsRatioService.parseDisplayDecimal("31.87%") == 31.87)
        #expect(KeystatsRatioService.parseDisplayDecimal("(5,349)") == -5349)
    }
}

// MARK: - Service error mapping (real APIClient + stubbed transport)

@Suite struct KeystatsRatioServiceErrorMappingTests {
    @Test func mapsUnauthorizedWhenNoToken() async {
        let client = APIClient(session: StubSession([]), tokens: InMemoryTokenStore())
        let svc = KeystatsRatioService(apiClient: client)

        await #expect(throws: KeystatsRatioError.unauthorized) {
            _ = try await svc.ratios(symbol: "TPIA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 403, body: Data())]), tokens: store)
        let svc = KeystatsRatioService(apiClient: client)

        await #expect(throws: KeystatsRatioError.paywall) {
            _ = try await svc.ratios(symbol: "TPIA")
        }
    }
}

// MARK: - Test helpers

private extension ValuationRatios {
    /// Builds a snapshot with only the Graham inputs set — everything else nil.
    static func fixture(eps: Double?, bookValuePerShare: Double?) -> ValuationRatios {
        ValuationRatios(
            symbol: "TEST",
            pe: nil, peTTM: nil, priceToSales: nil, priceToBook: nil,
            priceToCashFlow: nil, priceToFreeCashFlow: nil, evToEBITDA: nil,
            eps: eps, bookValuePerShare: bookValuePerShare, cashPerShare: nil,
            freeCashFlowPerShare: nil, currentRatio: nil, quickRatio: nil, debtToEquity: nil
        )
    }
}
