import Foundation
import Testing
@testable import Autoscreener

// Phase 1.6 (§6 / §11): the daily broker-activity series → the engine's `brokerAccumulationSignal`.
// Fixture is a trimmed-verbatim slice of the WIFI capture (2026-06-06): records are newest-first and
// every monetary value is a JSON number. The first record carries the full real shape (foreign/lot
// blocks the adapter ignores); the next two are minimal to prove only net/buy/sell are required.

private let brokerJSON = Data(#"""
{"message":"Successfully loaded broker activity historical data","data":{"date_from":"2025-06-05","date_to":"2026-06-05","symbols":["WIFI"],"broker_codes":["XL"],"records":[
{"date":"2026-06-05","broker_code":"","trade_activity":{"net_summary":{"avg_price":1559.65,"freq":2072,"lot":1495,"value":-534779000},"buy_summary":{"avg_price":1496.27,"freq":3946,"lot":121163,"value":18129299000},"sell_summary":{"avg_price":1559.65,"freq":2072,"lot":119668,"value":18664078000},"foreign_summary":{"foreign_buy":0,"foreign_sell":0,"net_foreign":0},"total_buy_lot":{"amount":121163,"pct":50.31},"total_sell_lot":{"amount":119668,"pct":49.69}},"price_activity":{"close_price":"1445"}},
{"date":"2026-06-04","broker_code":"","trade_activity":{"net_summary":{"value":12323969500},"buy_summary":{"value":26203446500},"sell_summary":{"value":13879477000}}},
{"date":"2026-06-03","broker_code":"","trade_activity":{"net_summary":{"value":-37324000},"buy_summary":{"value":6906049500},"sell_summary":{"value":6943373500}}}
]}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct BrokerActivityEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { i in i.value.map { (i.name, $0) } })
    }

    @Test func buildsPathAndPinnedQuery() {
        let ep = BrokerActivityService.makeEndpoint(symbol: "WIFI", period: .lastYear,
                                                    brokerCodes: [], limit: 100, page: 1)
        #expect(ep.method == .get)
        #expect(ep.path == "order-trade/broker/activity/historical")
        #expect(ep.requiresAuth)
        let q = query(ep)
        #expect(q["symbols"] == "WIFI")
        #expect(q["interval"] == "INTERVAL_DAILY")
        #expect(q["investor_type"] == "INVESTOR_TYPE_ALL")
        #expect(q["market_board"] == "BOARD_TYPE_REGULAR")
        #expect(q["transaction_type"] == "TRANSACTION_TYPE_NET")
        #expect(q["period"] == "RT_PERIOD_LAST_1_YEAR")
        #expect(q["pagination.limit"] == "100")
        #expect(q["pagination.page"] == "1")
        #expect(q["broker_codes"] == nil)   // omitted when empty (all-brokers default view)
    }

    @Test func includesBrokerCodesCsvWhenProvided() {
        let ep = BrokerActivityService.makeEndpoint(symbol: "WIFI", period: .lastMonth,
                                                    brokerCodes: ["XL", "YP"], limit: 50, page: 2)
        let q = query(ep)
        #expect(q["broker_codes"] == "XL,YP")
        #expect(q["period"] == "RT_PERIOD_LAST_1_MONTH")
        #expect(q["pagination.page"] == "2")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct BrokerActivityParseTests {
    @Test func parsesRecordsNewestFirstWithExactDecimals() throws {
        let recs = try BrokerActivityService.parse(brokerJSON)
        #expect(recs.count == 3)
        let first = try #require(recs.first)
        #expect(first.netValue == Decimal(-534_779_000))
        #expect(first.buyValue == Decimal(18_129_299_000))
        #expect(first.sellValue == Decimal(18_664_078_000))
        // Wire sanity: net_summary.value == buy − sell.
        #expect(first.netValue == first.buyValue - first.sellValue)
    }

    @Test func parsesDatesAsUtcMidnight() throws {
        let recs = try BrokerActivityService.parse(brokerJSON)
        #expect(recs.first?.date == BrokerActivityService.parseDay("2026-06-05"))
        #expect(recs.last?.date == BrokerActivityService.parseDay("2026-06-03"))
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try BrokerActivityService.parse(Data("not json".utf8)) }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct BrokerActivityServiceErrorMappingTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = BrokerActivityService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: BrokerActivityError.unauthorized) { _ = try await svc.dailyActivity(symbol: "WIFI") }
    }

    @Test func mapsPaywallFromHttp402() async {
        let svc = BrokerActivityService(apiClient: signedInClient([.init(status: 402, body: Data())]))
        await #expect(throws: BrokerActivityError.paywall) { _ = try await svc.dailyActivity(symbol: "WIFI") }
    }

    @Test func happyPathParsesRecords() async throws {
        let svc = BrokerActivityService(apiClient: signedInClient([.init(status: 200, body: brokerJSON)]))
        let recs = try await svc.dailyActivity(symbol: "WIFI")
        #expect(recs.count == 3)
        #expect(recs.first?.netValue == Decimal(-534_779_000))
    }

    @Test func mapsMalformedFromBadBody() async {
        let svc = BrokerActivityService(apiClient: signedInClient([.init(status: 200, body: Data("garbage".utf8))]))
        await #expect(throws: BrokerActivityError.malformedResponse) { _ = try await svc.dailyActivity(symbol: "WIFI") }
    }
}

// MARK: - Broker accumulation signal adapter (SelectionFundamentals, Phase 1.6)

@Suite struct BrokerAccumulationSignalTests {
    private func rec(net: Decimal, buy: Decimal, sell: Decimal) -> BrokerActivityRecord {
        BrokerActivityRecord(date: BrokerActivityService.parseDay("2026-06-05")!,
                             netValue: net, buyValue: buy, sellValue: sell)
    }

    @Test func valueWeightedNetRatioOverWindow() throws {
        let recs = try BrokerActivityService.parse(brokerJSON)
        let signal = SelectionFundamentals.brokerAccumulationSignal(from: recs, window: 10)
        let net = -534_779_000.0 + 12_323_969_500.0 - 37_324_000.0
        let gross = (18_129_299_000.0 + 18_664_078_000.0)
                  + (26_203_446_500.0 + 13_879_477_000.0)
                  + (6_906_049_500.0 + 6_943_373_500.0)
        #expect(abs(signal - net / gross) < 1e-9)
        #expect(signal > 0)   // net accumulation over the three days
    }

    @Test func positiveWhenNetBuying() {
        let s = SelectionFundamentals.brokerAccumulationSignal(from: [rec(net: 100, buy: 600, sell: 500)])
        #expect(s > 0 && s <= 1)
        #expect(abs(s - 100.0 / 1100.0) < 1e-9)
    }

    @Test func negativeWhenNetSelling() {
        let s = SelectionFundamentals.brokerAccumulationSignal(from: [rec(net: -100, buy: 500, sell: 600)])
        #expect(s < 0 && s >= -1)
        #expect(abs(s - (-100.0 / 1100.0)) < 1e-9)
    }

    @Test func windowTakesMostRecentRecordsOnly() {
        // Records are newest-first; a huge accumulation OUTSIDE the window must not count.
        let recs = [rec(net: 0, buy: 50, sell: 50),                 // newest — in window
                    rec(net: 1_000_000, buy: 1_000_000, sell: 0)]   // older — outside window=1
        #expect(SelectionFundamentals.brokerAccumulationSignal(from: recs, window: 1) == 0)
    }

    @Test func zeroWhenNoRecordsOrNoTradedValue() {
        #expect(SelectionFundamentals.brokerAccumulationSignal(from: []) == 0)
        #expect(SelectionFundamentals.brokerAccumulationSignal(from: [rec(net: 0, buy: 0, sell: 0)]) == 0)
    }

    @Test func boundedToUnitRange() {
        // Fully one-sided buying → +1 (defensive clamp).
        #expect(SelectionFundamentals.brokerAccumulationSignal(from: [rec(net: 1000, buy: 1000, sell: 0)]) == 1.0)
        // Fully one-sided selling → −1.
        #expect(SelectionFundamentals.brokerAccumulationSignal(from: [rec(net: -1000, buy: 0, sell: 1000)]) == -1.0)
    }
}
