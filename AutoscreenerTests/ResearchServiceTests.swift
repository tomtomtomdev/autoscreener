import Foundation
import Testing
@testable import Autoscreener

// Fixture: the verbatim `research/company/TPIA` body from the 2026-06-11 capture — the shape is
// verified `{ id, symbol, content, masks }` but `content` was empty (no coverage / paywalled).
private let researchEmptyJSON = Data(#"""
{"message":"Successfully retrieved research","data":{"id":0,"symbol":"","content":"","masks":{}}}
"""#.utf8)

// A populated note exercises the (verified) field mapping the capture couldn't: same shape, real
// `content`. `masks` is present and must be ignored by the decoder.
private let researchPopulatedJSON = Data(#"""
{"message":"Successfully retrieved research","data":{"id":42,"symbol":"BBCA","content":"<p>Strong quarter.</p>","masks":{"foo":1}}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct ResearchEndpointTests {
    @Test func buildsPath() {
        let ep = ResearchService.makeEndpoint(symbol: "TPIA")
        #expect(ep.method == .get)
        #expect(ep.path == "research/company/TPIA")
        #expect(ep.requiresAuth)
        #expect(ep.query.isEmpty)
    }
}

// MARK: - Parsing

@Suite struct ResearchParseTests {
    @Test func emptyContentDegradesToNoResearch() throws {
        #expect(try ResearchService.parse(researchEmptyJSON) == nil)
    }

    @Test func mapsPopulatedNoteAndIgnoresMasks() throws {
        let note = try #require(try ResearchService.parse(researchPopulatedJSON))
        #expect(note.id == 42)
        #expect(note.symbol == "BBCA")
        #expect(note.content == "<p>Strong quarter.</p>")
    }

    @Test func nullDataDegradesToNoResearch() throws {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(try ResearchService.parse(nullData) == nil)
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct ResearchServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = ResearchService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: ResearchError.unauthorized) {
            _ = try await svc.research(symbol: "TPIA")
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = ResearchService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: ResearchError.paywall) {
            _ = try await svc.research(symbol: "TPIA")
        }
    }

    @Test func returnsNilForUncoveredName() async throws {
        let svc = ResearchService(apiClient: signedInClient([.init(status: 200, body: researchEmptyJSON)]))
        #expect(try await svc.research(symbol: "TPIA") == nil)
    }

    @Test func returnsNoteForCoveredName() async throws {
        let svc = ResearchService(apiClient: signedInClient([.init(status: 200, body: researchPopulatedJSON)]))
        let note = try await svc.research(symbol: "BBCA")
        #expect(note?.content == "<p>Strong quarter.</p>")
    }
}
