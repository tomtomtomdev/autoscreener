import Foundation
import Testing
@testable import Autoscreener

// MARK: - broker/distribution — per-ticker bandar concentration
//
// Fixture: real legs from the TPIA `order-trade/broker/distribution` capture (2026-06-11), trimmed
// to the top 3 brokers per side; the huge per-broker `distribute_to` fan-out (70+ counterparties) is
// kept on one leg only, to prove the decoder ignores it. `amount` is a JSON Int (rupiah), not a
// display string — distinct from top-stock's `{raw,formatted}`.
private let distributionJSON = Data(#"""
{"message":"Successfully loaded Broker Distribution data","data":{
 "date_info":"2026-06-11",
 "by_value":{
  "top_broker_buy":[
   {"detail":{"code":"XL","type":"Lokal","amount":455039317500},"distribute_to":[{"code":"XL","type":"Lokal","amount":73513344000}]},
   {"detail":{"code":"AK","type":"Asing","amount":280337319500},"distribute_to":[]},
   {"detail":{"code":"CC","type":"Pemerintah","amount":266774755500},"distribute_to":[]}
  ],
  "top_broker_sell":[
   {"detail":{"code":"XL","type":"Lokal","amount":441110754500},"distribute_to":[]},
   {"detail":{"code":"MG","type":"Lokal","amount":340496525000},"distribute_to":[]},
   {"detail":{"code":"CC","type":"Pemerintah","amount":307872219500},"distribute_to":[]}
  ]
 },
 "by_volume":{"top_broker_buy":[],"top_broker_sell":[]},
 "start_date":"2026-06-11","end_date":"2026-06-11"
}}
"""#.utf8)

@Suite struct BrokerDistributionEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQuery() {
        let ep = OrderTradeFlowService.distributionEndpoint(symbol: "TPIA")
        #expect(ep.method == .get)
        #expect(ep.path == "order-trade/broker/distribution")
        #expect(ep.requiresAuth)
        let q = query(ep)
        #expect(q["symbol"] == "TPIA")
        #expect(q["data_type"] == "BROKER_DISTRIBUTION_DATA_TYPE_VALUE")
        #expect(q["period"] == "TB_PERIOD_LAST_1_DAY")
        #expect(q["investor_type"] == "INVESTOR_TYPE_ALL")
        #expect(q["market_board"] == "MARKET_TYPE_REGULER")
    }
}

@Suite struct BrokerDistributionParseTests {
    @Test func parsesDateBuyersAndSellers() throws {
        let d = try OrderTradeFlowService.parseDistribution(distributionJSON, symbol: "TPIA")
        #expect(d.symbol == "TPIA")
        #expect(d.date == "2026-06-11")
        #expect(d.topBuyers.count == 3)
        #expect(d.topSellers.count == 3)

        let lead = try #require(d.topBuyers.first)
        #expect(lead.code == "XL")
        #expect(lead.type == "Lokal")
        #expect(lead.amount == 455_039_317_500)
        // the per-broker distribute_to fan-out is ignored (we model the `detail` leg only)
        #expect(d.topSellers.first?.code == "XL")
        #expect(d.topSellers.first?.amount == 441_110_754_500)
    }

    @Test func computesBuyConcentration() throws {
        let d = try OrderTradeFlowService.parseDistribution(distributionJSON, symbol: "TPIA")
        // sum of the three verbatim buy legs
        #expect(d.totalBuyValue == 1_002_151_392_500)
        // all three brokers ⇒ the whole book
        #expect(d.buyConcentration(topN: 3) == 1.0)
        // lead broker's share of total buy value
        let lead = try #require(d.buyConcentration(topN: 1))
        #expect(abs(lead - 455_039_317_500 / 1_002_151_392_500) < 1e-9)
    }

    @Test func emptyBookHasNilConcentration() throws {
        let empty = Data(#"""
        {"message":"x","data":{"date_info":"2026-06-11","by_value":{"top_broker_buy":[],"top_broker_sell":[]},"by_volume":{"top_broker_buy":[],"top_broker_sell":[]}}}
        """#.utf8)
        let d = try OrderTradeFlowService.parseDistribution(empty, symbol: "TPIA")
        #expect(d.topBuyers.isEmpty)
        #expect(d.buyConcentration(topN: 3) == nil)
    }

    @Test func missingDataThrows() {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try OrderTradeFlowService.parseDistribution(nullData, symbol: "TPIA")
        }
    }
}

@Suite struct OrderTradeFlowServiceErrorTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = OrderTradeFlowService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: OrderTradeFlowError.unauthorized) {
            _ = try await svc.distribution(symbol: "TPIA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = OrderTradeFlowService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: OrderTradeFlowError.paywall) {
            _ = try await svc.distribution(symbol: "TPIA")
        }
    }

    @Test func distributionHappyPath() async throws {
        let svc = OrderTradeFlowService(apiClient: signedInClient([.init(status: 200, body: distributionJSON)]))
        let d = try await svc.distribution(symbol: "TPIA")
        #expect(d.topBuyers.first?.code == "XL")
    }

    @Test func topStocksHappyPath() async throws {
        let svc = OrderTradeFlowService(apiClient: signedInClient([.init(status: 200, body: topStockJSON)]))
        let board = try await svc.topStocks(valueType: .net)
        #expect(board.topBuy.first?.code == "ITMG")
    }
}

// MARK: - top-stock — market-wide net buy/sell leaders
//
// Fixture: real rows from the `order-trade/top-stock?value_type=VALUE_TYPE_NET` capture (2026-06-11),
// trimmed to the top 2 names per side. Every metric is a `{raw,formatted}` StockbitValue whose `raw`
// is a numeric String (signed on the sell side / for net foreign outflow).
private let topStockJSON = Data(#"""
{"message":"Successfully loaded top stock data","data":{
 "top_buy":[
  {"rank":1,"code":"ITMG","value":{"raw":"41185802500","formatted":"41.2B"},"lot":{"raw":"18401","formatted":"18.4K"},"foreign_value":{"raw":"-23592060000","formatted":"-23.6B"}},
  {"rank":2,"code":"BBNI","value":{"raw":"37339301000","formatted":"37.3B"},"lot":{"raw":"105939","formatted":"105.9K"},"foreign_value":{"raw":"7124806000","formatted":"7.1B"}}
 ],
 "top_sell":[
  {"rank":1,"code":"TPIA","value":{"raw":"-180225058500","formatted":"-180.2B"},"lot":{"raw":"-1077323","formatted":"-1.1M"},"foreign_value":{"raw":"97180690500","formatted":"97.2B"}},
  {"rank":2,"code":"DSSA","value":{"raw":"-159904511000","formatted":"-159.9B"},"lot":{"raw":"-2200716","formatted":"-2.2M"},"foreign_value":{"raw":"-166978166000","formatted":"-167.0B"}}
 ],
 "total":[],
 "response_info":{"page":1,"limit":100,"value_type":"VALUE_TYPE_NET"}
}}
"""#.utf8)

@Suite struct TopStockEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQuery() {
        let ep = OrderTradeFlowService.topStockEndpoint(valueType: .net, page: 1)
        #expect(ep.method == .get)
        #expect(ep.path == "order-trade/top-stock")
        #expect(ep.requiresAuth)
        let q = query(ep)
        #expect(q["value_type"] == "VALUE_TYPE_NET")
        #expect(q["market_type"] == "MARKET_TYPE_REGULER")
        #expect(q["investor_type"] == "INVESTOR_TYPE_ALL")
        #expect(q["period"] == "TOP_STOCK_PERIOD_LATEST")
        #expect(q["page"] == "1")
    }

    @Test func valueTypeSelectsTheQueryValue() {
        let q = Dictionary(uniqueKeysWithValues: OrderTradeFlowService
            .topStockEndpoint(valueType: .gross, page: 2).query
            .compactMap { item in item.value.map { (item.name, $0) } })
        #expect(q["value_type"] == "VALUE_TYPE_GROSS")
        #expect(q["page"] == "2")
    }
}

@Suite struct TopStockParseTests {
    @Test func parsesBuyAndSellLeaders() throws {
        let board = try OrderTradeFlowService.parseTopStocks(topStockJSON)
        #expect(board.topBuy.count == 2)
        #expect(board.topSell.count == 2)

        let lead = try #require(board.topBuy.first)
        #expect(lead.rank == 1)
        #expect(lead.code == "ITMG")
        #expect(lead.value.raw == 41_185_802_500)
        #expect(lead.value.formatted == "41.2B")
        // net foreign outflow stays negative through the numeric-String decode
        #expect(lead.foreignValue.raw == -23_592_060_000)

        let topSeller = try #require(board.topSell.first)
        #expect(topSeller.code == "TPIA")
        #expect(topSeller.value.raw == -180_225_058_500)
    }

    @Test func missingDataThrows() {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(throws: (any Error).self) { _ = try OrderTradeFlowService.parseTopStocks(nullData) }
    }
}
