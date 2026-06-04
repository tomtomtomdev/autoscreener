import Foundation
import Testing
@testable import Autoscreener

// MARK: - Endpoint wire format

@Suite struct CommodityEndpointTests {
    @Test func buildsEmittenInfoPath() {
        let ep = CommodityPriceService.makeEndpoint(symbol: "OIL")
        #expect(ep.method == .get)
        #expect(ep.path == "emitten/OIL/info")
        #expect(ep.query.isEmpty)
        #expect(ep.requiresAuth)
    }
}

// MARK: - Response parsing (trimmed from live OIL/XAU/CPO captures, 2026-06-04)

@Suite struct CommodityParseTests {
    // Commodity, float-precision price string, signed negative change, "NA" value/average.
    static let oil = Data(#"""
    {"data":{"symbol":"OIL","name":"Crude Oil","change":"-0.98","percentage":-1.02,
      "previous":"96.02","price":"95.04000091552734","formatted_price":"95",
      "value":"NA","average":"NA","volume":"18211","time":"Thu 14:22",
      "sector":"Commodities","type_company":"commodities"},
     "message":"Successfully retrieved company data"}
    """#.utf8)

    // Commodity, comma-grouped formatted price, signed positive change.
    static let gold = Data(#"""
    {"data":{"symbol":"XAU","name":"Gold","change":"+26.44","percentage":0.59,
      "previous":"4466.9","price":"4493.33984375","formatted_price":"4,493",
      "value":"NA","average":"NA","volume":"26747","time":"Thu 14:22"}}
    """#.utf8)

    // Commodity, integer-as-string price.
    static let palmOil = Data(#"""
    {"data":{"symbol":"CPO","name":"Palm Oil","change":"+145.00","percentage":3.2,
      "previous":"4535","price":"4680","formatted_price":"4,680","volume":"41464"}}
    """#.utf8)

    @Test func parsesCommodityWithFloatPriceAndNegativeChange() throws {
        let q = try CommodityPriceService.parse(Self.oil)
        #expect(q.symbol == "OIL")
        #expect(q.name == "Crude Oil")
        #expect(q.price == 95.04000091552734)
        #expect(q.previousClose == 96.02)
        #expect(q.change == -0.98)
        #expect(q.changePercent == -1.02)
        #expect(q.volume == 18211)
        #expect(q.formattedPrice == "95")
        #expect(q.asOf == "Thu 14:22")
        #expect(q.isUp == false)
    }

    @Test func parsesSignedPositiveChangeAndKeepsCommaFormattedPrice() throws {
        let q = try CommodityPriceService.parse(Self.gold)
        #expect(q.change == 26.44)             // leading "+" tolerated
        #expect(q.changePercent == 0.59)
        #expect(q.formattedPrice == "4,493")   // commas preserved, not parsed
        #expect(q.price == 4493.33984375)
        #expect(q.isUp)
    }

    @Test func parsesIntegerStringPrice() throws {
        let q = try CommodityPriceService.parse(Self.palmOil)
        #expect(q.price == 4680)
        #expect(q.change == 145)
        #expect(q.previousClose == 4535)
    }

    @Test func toleratesNAValueAndAverageFields() throws {
        // The "NA" strings in `value`/`average` must not break the decode.
        let q = try CommodityPriceService.parse(Self.oil)
        #expect(q.price == 95.04000091552734)
    }

    @Test func throwsOnNonNumericPrice() {
        let data = Data(#"{"data":{"symbol":"X","name":"X","price":"NA"}}"#.utf8)
        #expect(throws: CommodityDecodeError.malformedQuote) {
            _ = try CommodityPriceService.parse(data)
        }
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try CommodityPriceService.parse(Data("not json".utf8))
        }
    }
}

// MARK: - Service error mapping (real APIClient + stubbed transport)

@Suite struct CommodityPriceServiceErrorMappingTests {
    @Test func mapsUnauthorizedWhenNoToken() async {
        let client = APIClient(session: StubSession([]), tokens: InMemoryTokenStore())
        let svc = CommodityPriceService(apiClient: client)
        await #expect(throws: CommodityPriceError.unauthorized) {
            _ = try await svc.quote(symbol: "OIL")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 403, body: Data())]), tokens: store)
        let svc = CommodityPriceService(apiClient: client)
        await #expect(throws: CommodityPriceError.paywall) {
            _ = try await svc.quote(symbol: "OIL")
        }
    }

    @Test func mapsMalformedFromBadBody() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 200, body: Data("garbage".utf8))]), tokens: store)
        let svc = CommodityPriceService(apiClient: client)
        await #expect(throws: CommodityPriceError.malformedResponse) {
            _ = try await svc.quote(symbol: "OIL")
        }
    }

    @Test func parsesHappyPathThroughClient() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 200, body: CommodityParseTests.gold)]), tokens: store)
        let svc = CommodityPriceService(apiClient: client)
        let q = try await svc.quote(symbol: "XAU")
        #expect(q.symbol == "XAU")
        #expect(q.price == 4493.33984375)
    }
}
