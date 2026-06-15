import Foundation
import Testing
@testable import Autoscreener

// MARK: - Endpoint wire format

@Suite struct ChartEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    @Test func buildsPathAndFixedQuery() {
        let ep = ChartService.makeEndpoint(symbol: "CUAN", timeframe: .oneYear, chartType: .candle)
        #expect(ep.method == .get)
        #expect(ep.path == "charts/CUAN/daily")
        let q = query(ep)
        #expect(q["is_include_previous_historical"] == "1")
        #expect(q["timeframe"] == "1y")
        #expect(q["chart_type"] == "PRICE_CHART_TYPE_CANDLE")
    }

    @Test func mapsChartTypeToQuery() {
        #expect(query(ChartService.makeEndpoint(symbol: "X", timeframe: .today, chartType: .candle))["chart_type"] == "PRICE_CHART_TYPE_CANDLE")
        #expect(query(ChartService.makeEndpoint(symbol: "X", timeframe: .today, chartType: .line))["chart_type"] == "PRICE_CHART_TYPE_LINE")
    }

    @Test func mapsEveryTimeframeToWireValue() {
        let expected: [ChartTimeframe: String] = [
            .today: "today", .oneWeek: "1w", .oneMonth: "1m", .threeMonth: "3m",
            .yearToDate: "ytd", .oneYear: "1y", .threeYear: "3y", .fiveYear: "5y",
        ]
        for tf in ChartTimeframe.allCases {
            #expect(query(ChartService.makeEndpoint(symbol: "X", timeframe: tf, chartType: .candle))["timeframe"] == expected[tf])
        }
    }

    @Test func flagsIntradayWindows() {
        #expect(ChartTimeframe.today.isIntraday)
        #expect(ChartTimeframe.oneWeek.isIntraday)
        #expect(!ChartTimeframe.oneMonth.isIntraday)
        #expect(!ChartTimeframe.oneYear.isIntraday)
    }
}

// MARK: - Response parsing (trimmed from live CUAN + IHSG captures, 2026-06-04)

@Suite struct ChartParseTests {
    // Stock, daily bars: integer `previous`, integer volume strings.
    static let stockDaily = Data(#"""
    {"message":"Successfully retrieved company daily chart","data":{
      "previous":1200,"chart_type":"PRICE_CHART_TYPE_CANDLE","timeframe":"1m",
      "prices":[
        {"date":"1777827600000","formatted_date":"2026-05-04","xlabel":"","value":"1160","percentage":"-3.33","change":-40,"open":"1210","high":"1245","low":"1155","volume":"5003149"},
        {"date":"1780506000000","formatted_date":"2026-06-04","xlabel":"","value":"745","percentage":"-37.92","change":-455,"open":"720","high":"770","low":"640","volume":"6724756"}
      ]}}
    """#.utf8)

    // Index, daily bars: float `previous`, decimal volume strings, float `change`.
    static let indexDaily = Data(#"""
    {"data":{"previous":7044.822,"timeframe":"1y","prices":[
      {"date":"1748970000000","formatted_date":"2025-06-04","xlabel":"","value":"7069.04","percentage":"0.34","change":24.215,"open":"7083.24","high":"7094.45","low":"7052.91","volume":"237454240.00"}
    ]}}
    """#.utf8)

    @Test func parsesStockOHLCV() throws {
        let s = try ChartService.parse(Self.stockDaily, symbol: "CUAN", timeframe: .oneMonth)
        #expect(s.symbol == "CUAN")
        #expect(s.timeframe == .oneMonth)
        #expect(s.previousClose == 1200)
        #expect(s.candles.count == 2)

        let first = s.candles[0]
        #expect(first.date == Date(timeIntervalSince1970: 1_777_827_600))
        #expect(first.open == 1210)
        #expect(first.high == 1245)
        #expect(first.low == 1155)
        #expect(first.close == 1160)         // `value` maps to close
        #expect(first.volume == 5_003_149)
    }

    @Test func parsesIndexWithDecimalVolumeAndFloatPrevious() throws {
        let s = try ChartService.parse(Self.indexDaily, symbol: "IHSG", timeframe: .oneYear)
        #expect(s.previousClose == 7044.822)
        let c = s.candles[0]
        #expect(c.close == 7069.04)
        #expect(c.high == 7094.45)
        #expect(c.volume == 237_454_240)     // "237454240.00" → Double
    }

    @Test func toleratesMissingPreviousAndEmptyPrices() throws {
        let data = Data(#"{"data":{"prices":[]}}"#.utf8)
        let s = try ChartService.parse(data, symbol: "X", timeframe: .today)
        #expect(s.previousClose == nil)
        #expect(s.candles.isEmpty)
    }

    @Test func throwsOnNonNumericPoint() {
        let data = Data(#"""
        {"data":{"prices":[{"date":"1748970000000","value":"n/a","open":"1","high":"1","low":"1","volume":"1"}]}}
        """#.utf8)
        #expect(throws: (any Error).self) {
            _ = try ChartService.parse(data, symbol: "X", timeframe: .oneYear)
        }
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try ChartService.parse(Data("not json".utf8), symbol: "X", timeframe: .oneYear)
        }
    }
}

// MARK: - Service error mapping (real APIClient + stubbed transport)

@Suite struct ChartServiceErrorMappingTests {
    @Test func mapsUnauthorizedWhenNoToken() async {
        let client = APIClient(session: StubSession([]), tokens: InMemoryTokenStore())
        let svc = ChartService(apiClient: client)
        await #expect(throws: ChartError.unauthorized) {
            _ = try await svc.candles(symbol: "CUAN", timeframe: .oneYear)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 403, body: Data())]), tokens: store)
        let svc = ChartService(apiClient: client)
        await #expect(throws: ChartError.paywall) {
            _ = try await svc.candles(symbol: "CUAN", timeframe: .oneYear)
        }
    }

    @Test func mapsMalformedFromBadBody() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 200, body: Data("garbage".utf8))]), tokens: store)
        let svc = ChartService(apiClient: client)
        await #expect(throws: ChartError.malformedResponse) {
            _ = try await svc.candles(symbol: "CUAN", timeframe: .oneYear)
        }
    }

    @Test func parsesHappyPathThroughClient() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 200, body: ChartParseTests.stockDaily)]), tokens: store)
        let svc = ChartService(apiClient: client)
        let series = try await svc.candles(symbol: "CUAN", timeframe: .oneMonth)
        #expect(series.candles.count == 2)
        #expect(series.candles.last?.close == 745)
    }
}
