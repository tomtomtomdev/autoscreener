import Foundation
import Testing
@testable import Autoscreener

// The dynamic index-membership source the regime breadth factor needs. Stockbit models
// IDX indices as subsectors of sector 88 ("Indeks"); the company list under an index
// subsector is that index's live constituent set — one call, no per-stock fan-out, no
// hand-maintained rebalance config. Verified against the KOMPAS100 capture (2026-06-20):
// `GET /emitten/v3/sector/88/subsector/555/company` → 100 symbols, all `type_company:"Saham"`.

/// Trimmed verbatim from the capture (first rows of subsector/555/company), with the row
/// fields the parser must tolerate around the one it reads (`symbol`).
private let kompasSliceJSON = Data(#"""
{"data":[{"company_id":"54","symbol":"BBCA","symbol_2":"BBCA","name":"Bank Central Asia Tbk.","last":"6300","type_company":"Saham"},{"company_id":"59","symbol":"BBRI","symbol_2":"BBRI","name":"Bank Rakyat Indonesia (Persero) Tbk.","last":"2930","type_company":"Saham"},{"company_id":"301","symbol":"GOTO","symbol_2":"GOTO","name":"GoTo Gojek Tokopedia Tbk.","last":"82","type_company":"Saham"}]}
"""#.utf8)

// MARK: - Index catalog + endpoint wire format

@Suite struct IndexConstituentsEndpointTests {
    @Test func kompas100MapsToSector88Subsector555() {
        #expect(IDXIndex.kompas100.subsectorId == "555")
        #expect(IDXIndex.lq45.subsectorId == "550")     // capture: subsectors of sector 88
        #expect(IDXIndex.idx30.subsectorId == "559")
    }

    @Test func buildsTheSectorSubsectorCompanyPath() {
        let ep = IndexConstituentsService.endpoint(subsectorId: "555")
        #expect(ep.method == .get)
        #expect(ep.path == "emitten/v3/sector/88/subsector/555/company")
        #expect(ep.requiresAuth)
        #expect(ep.query.isEmpty)
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct IndexConstituentsParseTests {
    @Test func parsesSymbolsInOrder() throws {
        #expect(try IndexConstituentsService.parse(kompasSliceJSON) == ["BBCA", "BBRI", "GOTO"])
    }

    @Test func toleratesMissingOrEmptyDataAsAnEmptyList() throws {
        // A schema drift that drops `data` degrades to [] (the breadth factor then drops,
        // graceful, rather than a thrown malformed error) — mirrors EmittenService.
        #expect(try IndexConstituentsService.parse(Data(#"{"message":"x"}"#.utf8)) == [])
        #expect(try IndexConstituentsService.parse(Data(#"{"data":[]}"#.utf8)) == [])
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try IndexConstituentsService.parse(Data("not json".utf8)) }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct IndexConstituentsServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func happyPathReturnsTheMemberSymbols() async throws {
        let svc = IndexConstituentsService(apiClient: signedInClient([.init(status: 200, body: kompasSliceJSON)]))
        let members = try await svc.constituents(of: .kompas100)
        #expect(members == ["BBCA", "BBRI", "GOTO"])
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = IndexConstituentsService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: IndexConstituentsError.unauthorized) { _ = try await svc.constituents(of: .kompas100) }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = IndexConstituentsService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: IndexConstituentsError.paywall) { _ = try await svc.constituents(of: .kompas100) }
    }

    @Test func mapsMalformedFromBadBody() async {
        let svc = IndexConstituentsService(apiClient: signedInClient([.init(status: 200, body: Data("garbage".utf8))]))
        await #expect(throws: IndexConstituentsError.malformedResponse) { _ = try await svc.constituents(of: .kompas100) }
    }
}
