import Foundation
import Testing
@testable import Autoscreener

// Fixtures are real rows from the WIFI historical-summary capture (2026-06-06), trimmed to a
// couple of rows per page. Every field is a JSON number; rows are newest-first; page 1 advertises
// next_page="2", page 2 has next_page:null.

private func ymd(_ y: Int, _ m: Int, _ d: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                   year: y, month: m, day: d).date!
}

private let page1JSON = Data(#"""
{"message":"Successfully get the historical summary","data":{"paginate":{"next_page":"2"},"result":[
 {"date":"2026-06-05","close":1445,"change":-255,"value":124135377500,"volume":823021,"frequency":12462,"foreign_buy":38959876500,"foreign_sell":17600335000,"net_foreign":21359541500,"open":1690,"high":1695,"low":1445,"average":1508,"change_percentage":-15},
 {"date":"2026-06-04","close":1700,"change":-245,"value":190396233500,"volume":1112115,"frequency":11964,"foreign_buy":26528272000,"foreign_sell":24314273500,"net_foreign":2213998500,"open":1890,"high":1920,"low":1655,"average":1712,"change_percentage":-12.6}
]}}
"""#.utf8)

private let page2JSON = Data(#"""
{"message":"ok","data":{"paginate":{"next_page":null},"result":[
 {"date":"2026-06-03","close":1945,"change":0,"value":100000000000,"volume":500000,"frequency":9000,"foreign_buy":1,"foreign_sell":2,"net_foreign":-50000000,"open":1950,"high":1960,"low":1900,"average":1930,"change_percentage":0}
]}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct CompanyPriceFeedEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQuery() {
        let ep = CompanyPriceFeedService.makeEndpoint(
            symbol: "WIFI", period: .daily,
            startDate: "2025-06-06", endDate: "2026-06-06", limit: 50, page: 1)
        #expect(ep.method == .get)
        #expect(ep.path == "company-price-feed/historical/summary/WIFI")
        #expect(ep.requiresAuth)
        let q = query(ep)
        #expect(q["period"] == "HS_PERIOD_DAILY")
        #expect(q["start_date"] == "2025-06-06")
        #expect(q["end_date"] == "2026-06-06")
        #expect(q["limit"] == "50")   // server caps `limit` at 50 (see dailyBarsRequestsAServerLegalPageLimit)
        #expect(q["page"] == "1")
    }

    @Test func formatsDatesAsYYYYMMDDInUTC() {
        #expect(CompanyPriceFeedService.day(ymd(2025, 6, 6)) == "2025-06-06")
        #expect(CompanyPriceFeedService.day(ymd(2026, 1, 27)) == "2026-01-27")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct CompanyPriceFeedParseTests {
    @Test func parsesRowsNumericFieldsAndPagination() throws {
        let page = try CompanyPriceFeedService.parse(page1JSON)
        #expect(page.bars.count == 2)
        #expect(page.nextPage == 2)

        let newest = page.bars[0]   // rows arrive newest-first
        #expect(newest.date == ymd(2026, 6, 5))
        #expect(newest.open == 1690)
        #expect(newest.high == 1695)
        #expect(newest.low == 1445)
        #expect(newest.close == 1445)
        #expect(newest.volume == 823021)
        #expect(newest.value == Decimal(124135377500))
        #expect(newest.netForeign == Decimal(21359541500))
    }

    @Test func lastPageReportsNoNextPage() throws {
        let page = try CompanyPriceFeedService.parse(page2JSON)
        #expect(page.bars.count == 1)
        #expect(page.nextPage == nil)
    }

    @Test func malformedDateRowThrows() {
        let bad = Data(#"{"data":{"result":[{"date":"not-a-date","open":1,"high":1,"low":1,"close":1,"volume":1,"value":1,"net_foreign":0}]}}"#.utf8)
        #expect(throws: (any Error).self) { _ = try CompanyPriceFeedService.parse(bad) }
    }
}

// MARK: - OHLCV / foreign-flow adapter (Phase 0.2 deliverable)

@Suite struct HistoricalSummaryAdapterTests {
    @Test func ohlcvSeriesIsSortedAscendingWithTrueValue() throws {
        let bars = try CompanyPriceFeedService.parse(page1JSON).bars   // newest-first
        let series = bars.ohlcvSeries
        #expect(series.count == 2)
        #expect(series.first?.date == ymd(2026, 6, 4))   // oldest first after the adapter
        #expect(series.last?.date == ymd(2026, 6, 5))
        // value (traded rupiah) is carried through verbatim onto OHLCV.value
        #expect(series.last?.value == Decimal(124135377500))
        #expect(series.last?.close == 1445)
    }

    @Test func foreignNetFlowSeriesIsSortedAscending() throws {
        let bars = try CompanyPriceFeedService.parse(page1JSON).bars
        let flow = bars.foreignNetFlowSeries
        #expect(flow == [Decimal(2213998500), Decimal(21359541500)])   // 06-04 then 06-05
    }
}

// MARK: - Service through APIClient (error mapping + pagination)

// Regression: a propagated price-feed error reaching the Recommendations screen must read as a
// sentence, not Swift's default "…CompanyPriceFeedError error 0" enum-index formatting (the bug:
// an expired/un-entitled Stockbit session surfaced the literal text "CompanyPriceFeedError error 0").
@Suite struct CompanyPriceFeedErrorMessageTests {
    private let allCases: [CompanyPriceFeedError] = [
        .unauthorized, .paywall, .network("timed out"), .malformedResponse,
    ]

    @Test func unauthorizedDoesNotRenderAsErrorZero() {
        #expect(!CompanyPriceFeedError.unauthorized.localizedDescription.contains("error 0"))
    }

    @Test func everyCaseHasAReadableSentence() {
        for error in allCases {
            let message = error.localizedDescription
            #expect(!message.isEmpty)
            #expect(!message.contains("CompanyPriceFeedError"))
            #expect(!message.contains("error 0"))
        }
    }

    @Test func networkCaseIncludesUnderlyingDetail() {
        #expect(CompanyPriceFeedError.network("timed out").localizedDescription.contains("timed out"))
    }
}

// Records the page `limit` that `dailyBars` requests, returning a single empty page (next_page:nil)
// so the pagination loop stops after one call — lets a test assert the limit `dailyBars` chooses.
private actor PageLimitSpy: CompanyPriceFeedServicing {
    private(set) var requestedLimits: [Int] = []
    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod,
                           startDate: Date, endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage {
        requestedLimits.append(limit)
        return HistoricalSummaryPage(bars: [], nextPage: nil)
    }
}

@Suite struct CompanyPriceFeedServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = CompanyPriceFeedService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: CompanyPriceFeedError.unauthorized) {
            _ = try await svc.historicalSummary(symbol: "WIFI", period: .daily,
                                                startDate: ymd(2025, 6, 6), endDate: ymd(2026, 6, 6), limit: 13, page: 1)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = CompanyPriceFeedService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: CompanyPriceFeedError.paywall) {
            _ = try await svc.historicalSummary(symbol: "WIFI", period: .daily,
                                                startDate: ymd(2025, 6, 6), endDate: ymd(2026, 6, 6), limit: 13, page: 1)
        }
    }

    @Test func happyPathParsesOnePage() async throws {
        let svc = CompanyPriceFeedService(apiClient: signedInClient([.init(status: 200, body: page1JSON)]))
        let page = try await svc.historicalSummary(symbol: "WIFI", period: .daily,
                                                   startDate: ymd(2025, 6, 6), endDate: ymd(2026, 6, 6), limit: 13, page: 1)
        #expect(page.bars.count == 2)
        #expect(page.nextPage == 2)
    }

    @Test func dailyBarsFollowsPaginationAndReturnsAscending() async throws {
        let svc = CompanyPriceFeedService(apiClient: signedInClient([
            .init(status: 200, body: page1JSON),   // next_page = 2
            .init(status: 200, body: page2JSON),    // next_page = null → stop
        ]))
        let bars = try await svc.dailyBars(symbol: "WIFI", from: ymd(2025, 6, 6), to: ymd(2026, 6, 6))
        #expect(bars.count == 3)
        #expect(bars.map(\.date) == [ymd(2026, 6, 3), ymd(2026, 6, 4), ymd(2026, 6, 5)])
    }

    // Regression: Stockbit caps this endpoint's `limit` at 50 — a request for more returns
    // 400 INVALID_PARAMETER and (since that's neither AdapterError nor noPriceData) aborts the whole
    // selection run. `dailyBars` defaulted to pageLimit 1000, so EVERY live universe run failed on the
    // first ticker. Live-verified vs stockbitbbca.com.har (limit=12 → 200) + a variant probe (50 OK,
    // 60 → 400). `dailyBars` must request a server-legal page size; pagination covers the lookback.
    @Test func dailyBarsRequestsAServerLegalPageLimit() async throws {
        let spy = PageLimitSpy()
        _ = try await spy.dailyBars(symbol: "BBCA", from: ymd(2025, 6, 16), to: ymd(2026, 6, 16))
        let limits = await spy.requestedLimits
        #expect(!limits.isEmpty)
        #expect(limits.allSatisfy { $0 <= 50 })
    }
}
