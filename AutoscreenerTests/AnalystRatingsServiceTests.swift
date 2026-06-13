import Foundation
import Testing
@testable import Autoscreener

// Fixtures: the verbatim `analyst-ratings/{SYM}` and `…/consensus` bodies from the 2026-06-11 capture.
// Both came back empty for every captured symbol (TPIA, IHSG carry no sell-side coverage), so the
// "no coverage" payloads below are the only verified shapes — the populated DTOs stay unmodelled
// until a covered-large-cap re-capture (CAPTURED-ENDPOINTS-SPEC.md §6).
private let coverageNullJSON = Data(#"""
{"message":"Successfully retrieved analyst ratings data","data":null}
"""#.utf8)

private let consensusEmptyJSON = Data(#"""
{"message":"Successfully retrieved analyst consensus data","data":[]}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct AnalystRatingsEndpointTests {
    @Test func coverageBuildsPath() {
        let ep = AnalystRatingsService.makeCoverageEndpoint(symbol: "TPIA")
        #expect(ep.method == .get)
        #expect(ep.path == "analyst-ratings/TPIA")
        #expect(ep.requiresAuth)
        #expect(ep.query.isEmpty)
    }

    @Test func consensusBuildsPath() {
        let ep = AnalystRatingsService.makeConsensusEndpoint(symbol: "TPIA")
        #expect(ep.method == .get)
        #expect(ep.path == "analyst-ratings/TPIA/consensus")
        #expect(ep.requiresAuth)
    }
}

// MARK: - Envelope degradation (the only verified behavior)

@Suite struct AnalystRatingsParseTests {
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

// MARK: - Service through APIClient (error mapping + degradation)

@Suite struct AnalystRatingsServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = AnalystRatingsService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: AnalystRatingsError.unauthorized) {
            _ = try await svc.coverage(symbol: "TPIA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: AnalystRatingsError.paywall) {
            _ = try await svc.consensus(symbol: "TPIA")
        }
    }

    @Test func coverageReturnsNilForUncoveredName() async throws {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 200, body: coverageNullJSON)]))
        let coverage = try await svc.coverage(symbol: "TPIA")
        #expect(coverage == nil)
    }

    @Test func consensusReturnsEmptyForUncoveredName() async throws {
        let svc = AnalystRatingsService(apiClient: signedInClient([.init(status: 200, body: consensusEmptyJSON)]))
        let rows = try await svc.consensus(symbol: "TPIA")
        #expect(rows.isEmpty)
    }
}
