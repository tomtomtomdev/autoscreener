import Foundation
import Testing
@testable import Autoscreener

// Fixtures: the verified `analyst-ratings/BBCA` shapes from the covered-large-cap re-capture
// (2026-06-12). The original 2026-06-11 capture returned data:null / [] for every symbol (no
// coverage), so BBCA is the first populated payload — consensus trimmed to 2 series × 2 items.
private let coverageBBCAJSON = Data(#"""
{"message":"Successfully retrieved analyst ratings data","data":{
 "price_target":{"best_target":8827,"best_low_target":5500,"best_high_target":10900,"current_price":5925},
 "recommendation":"Buy","total_buy":35,"total_sell":0,"total_hold":2,"total_analyst":37,
 "last_updated":"11 Jun 26"}}
"""#.utf8)

private let consensusBBCAJSON = Data(#"""
{"message":"Successfully retrieved analyst consensus data","data":[
 {"name":"Revenue","items":[
   {"year":2025,"is_estimate":false,"value":"118,573 B","raw_value":0},
   {"year":2026,"is_estimate":true,"value":"118,236 B","raw_value":0}]},
 {"name":"EPS","items":[
   {"year":2025,"is_estimate":false,"value":"466.74","raw_value":0},
   {"year":2026,"is_estimate":true,"value":"490.46","raw_value":0}]}]}
"""#.utf8)

// The verified "no coverage" replies (verbatim from the 2026-06-11 capture).
private let coverageNullJSON = Data(#"{"message":"Successfully retrieved analyst ratings data","data":null}"#.utf8)
private let consensusEmptyJSON = Data(#"{"message":"Successfully retrieved analyst consensus data","data":[]}"#.utf8)

// MARK: - Endpoint wire format

@Suite struct AnalystRatingsEndpointTests {
    @Test func coverageBuildsPath() {
        let ep = AnalystRatingsService.makeCoverageEndpoint(symbol: "BBCA")
        #expect(ep.method == .get)
        #expect(ep.path == "analyst-ratings/BBCA")
        #expect(ep.requiresAuth)
        #expect(ep.query.isEmpty)
    }

    @Test func consensusBuildsPath() {
        let ep = AnalystRatingsService.makeConsensusEndpoint(symbol: "BBCA")
        #expect(ep.method == .get)
        #expect(ep.path == "analyst-ratings/BBCA/consensus")
        #expect(ep.requiresAuth)
    }
}

// MARK: - Parsing the verified populated shapes

@Suite struct AnalystRatingsParseTests {
    @Test func decodesCoverageBlock() throws {
        let c = try #require(try AnalystRatingsService.parseCoverage(coverageBBCAJSON))
        #expect(c.priceTarget.best == 8827)
        #expect(c.priceTarget.low == 5500)
        #expect(c.priceTarget.high == 10900)
        #expect(c.priceTarget.current == 5925)
        #expect(c.recommendation == "Buy")
        #expect(c.totalBuy == 35)
        #expect(c.totalHold == 2)
        #expect(c.totalSell == 0)
        #expect(c.totalAnalyst == 37)
        #expect(c.lastUpdated == "11 Jun 26")
    }

    @Test func computesTargetUpsideFromBestVsCurrent() throws {
        let c = try #require(try AnalystRatingsService.parseCoverage(coverageBBCAJSON))
        // (8827 − 5925) / 5925 ≈ +49%
        let upside = try #require(c.targetUpsidePct)
        #expect(abs(upside - 0.4897) < 0.001)
    }

    @Test func decodesConsensusEstimateSeries() throws {
        let series = try AnalystRatingsService.parseConsensus(consensusBBCAJSON)
        #expect(series.map(\.name) == ["Revenue", "EPS"])

        let revenue = try #require(series.first { $0.name == "Revenue" })
        let revenue2025 = try #require(revenue.items.first { $0.year == 2025 })
        #expect(revenue2025.isEstimate == false)          // reported actual
        #expect(revenue2025.value == 118_573e9)           // "118,573 B" scaled

        let eps = try #require(series.first { $0.name == "EPS" })
        let eps2026 = try #require(eps.items.first { $0.year == 2026 })
        #expect(eps2026.isEstimate == true)               // forward estimate
        #expect(eps2026.value == 490.46)                  // bare decimal, unscaled
    }
}

// MARK: - Envelope degradation ("no coverage")

@Suite struct AnalystRatingsDegradationTests {
    @Test func nullDataDegradesToNoCoverage() throws {
        #expect(try AnalystRatingsService.parseCoverage(coverageNullJSON) == nil)
    }

    @Test func emptyConsensusDegradesToEmptyArray() throws {
        #expect(try AnalystRatingsService.parseConsensus(consensusEmptyJSON).isEmpty)
    }

    @Test func nullConsensusDegradesToEmptyArray() throws {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(try AnalystRatingsService.parseConsensus(nullData).isEmpty)
    }
}

// MARK: - Service through APIClient (error mapping + happy path)

@Suite struct AnalystRatingsServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = AnalystRatingsService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: AnalystRatingsError.unauthorized) {
            _ = try await svc.coverage(symbol: "BBCA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: AnalystRatingsError.paywall) {
            _ = try await svc.consensus(symbol: "BBCA")
        }
    }

    @Test func coverageHappyPathReturnsBlock() async throws {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 200, body: coverageBBCAJSON)]))
        let c = try await svc.coverage(symbol: "BBCA")
        #expect(c?.recommendation == "Buy")
        #expect(c?.totalAnalyst == 37)
    }

    @Test func consensusHappyPathReturnsSeries() async throws {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 200, body: consensusBBCAJSON)]))
        let series = try await svc.consensus(symbol: "BBCA")
        #expect(series.count == 2)
        #expect(series.first?.name == "Revenue")
    }

    @Test func coverageReturnsNilForUncoveredName() async throws {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 200, body: coverageNullJSON)]))
        #expect(try await svc.coverage(symbol: "TPIA") == nil)
    }
}
