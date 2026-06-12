import Foundation
import Testing
@testable import Autoscreener

// Fixture: real cells from the TPIA `comparison/v2/ratios` capture (2026-06-11), trimmed to two
// groups. Stockbit returns the subject first, then the INDUSTRY and SECTOR aggregate benchmarks;
// every "value" is a display string ("154,423 B", "15.67", "-").
private let comparisonJSON = Data(#"""
{"message":"Successfully Get Company Ratios","data":{"symbols":["TPIA","INDUSTRY","SECTOR"],"metric_groups":[
 {"metric_group_name":"Valuation","metric":[
   {"fitem_id":2892,"fitem_name":"Market Cap","ratios":[{"symbol":"TPIA","value":"154,423 B"},{"symbol":"INDUSTRY","value":"24,682 B"},{"symbol":"SECTOR","value":"24,682 B"}]},
   {"fitem_id":12148,"fitem_name":"Current PE Ratio (Annualised)","ratios":[{"symbol":"TPIA","value":"15.67"},{"symbol":"INDUSTRY","value":"10.72"},{"symbol":"SECTOR","value":"10.72"}]}
 ]},
 {"metric_group_name":"Per Share","metric":[
   {"fitem_id":13200,"fitem_name":"Current EPS (TTM)","ratios":[{"symbol":"TPIA","value":"242.08"},{"symbol":"INDUSTRY","value":"86.62"},{"symbol":"SECTOR","value":"86.62"}]}
 ]}
]}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct ComparisonRatiosEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQuery() {
        let ep = ComparisonRatiosService.makeEndpoint(symbol: "TPIA")
        #expect(ep.method == .get)
        #expect(ep.path == "comparison/v2/ratios")
        #expect(ep.requiresAuth)
        #expect(query(ep)["symbol"] == "TPIA")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct ComparisonRatiosParseTests {
    @Test func parsesSymbolsGroupsAndMetrics() throws {
        let c = try ComparisonRatiosService.parse(comparisonJSON)
        #expect(c.symbols == ["TPIA", "INDUSTRY", "SECTOR"])
        #expect(c.groups.map(\.name) == ["Valuation", "Per Share"])

        let marketCap = try #require(c.metric(named: "Market Cap"))
        #expect(marketCap.id == 2892)
        #expect(marketCap.raw["TPIA"] == "154,423 B")
    }

    @Test func parsesScaledAndPlainNumbers() throws {
        let c = try ComparisonRatiosService.parse(comparisonJSON)
        // "154,423 B" → 154,423 × 10⁹
        #expect(c.subjectValue(forMetric: "Market Cap") == 154_423e9)
        // plain ratio, no magnitude suffix
        #expect(c.subjectValue(forMetric: "Current PE Ratio (Annualised)") == 15.67)
        // a benchmark column parses too
        #expect(c.metric(named: "Current EPS (TTM)")?.numeric["INDUSTRY"] == 86.62)
    }

    @Test func missingDataThrows() {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(throws: (any Error).self) { _ = try ComparisonRatiosService.parse(nullData) }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct ComparisonRatiosServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = ComparisonRatiosService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: ComparisonRatiosError.unauthorized) {
            _ = try await svc.comparison(symbol: "TPIA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = ComparisonRatiosService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: ComparisonRatiosError.paywall) {
            _ = try await svc.comparison(symbol: "TPIA")
        }
    }

    @Test func happyPathReturnsComparison() async throws {
        let svc = ComparisonRatiosService(apiClient: signedInClient([.init(status: 200, body: comparisonJSON)]))
        let c = try await svc.comparison(symbol: "TPIA")
        #expect(c.symbols.count == 3)
        #expect(c.subjectValue(forMetric: "Market Cap") == 154_423e9)
    }
}
