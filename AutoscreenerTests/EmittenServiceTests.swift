import Foundation
import Testing
@testable import Autoscreener

// Phase 1.4 (§8/§11): the company-level fields the engine needs from `/emitten/{SYM}/info` (sector)
// and `/emitten/{SYM}/profile` (free float). Fixtures are trimmed verbatim from the WIFI capture.

private let wifiInfoJSON = Data(#"""
{"message":"Company info retrieved","data":{"symbol":"WIFI","name":"Solusi Sinergi Digital Tbk","sector":"Teknologi","sub_sector":"Perangkat Lunak & Jasa TI","indexes":["IDXTECHNO","IDX80","LQ45","ISSI","IHSG"]}}
"""#.utf8)

private let wifiProfileJSON = Data(#"""
{"message":"Company profile retrieved","data":{"history":{"shares":"156,558,200","free_float":"40.00%"},"listing_information":{"foreign_percentage":{"raw":0,"formatted":""},"local_percentage":{"raw":0,"formatted":""},"total_shares":0}}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct EmittenEndpointTests {
    @Test func buildsInfoPath() {
        let ep = EmittenService.infoEndpoint(symbol: "WIFI")
        #expect(ep.method == .get)
        #expect(ep.path == "emitten/WIFI/info")
        #expect(ep.requiresAuth)
        #expect(ep.query.isEmpty)
    }

    @Test func buildsProfilePath() {
        let ep = EmittenService.profileEndpoint(symbol: "WIFI")
        #expect(ep.path == "emitten/WIFI/profile")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct EmittenParseTests {
    @Test func parsesInfoSectorAndIndexes() throws {
        let info = try EmittenService.parseInfo(wifiInfoJSON)
        #expect(info.symbol == "WIFI")
        #expect(info.name == "Solusi Sinergi Digital Tbk")
        #expect(info.sector == "Teknologi")
        #expect(info.subSector == "Perangkat Lunak & Jasa TI")
        #expect(info.indexes.contains("IDXTECHNO"))
        #expect(info.indexes.contains("LQ45"))
    }

    @Test func parsesProfileFreeFloatAndShares() throws {
        let profile = try EmittenService.parseProfile(wifiProfileJSON)
        #expect(profile.freeFloatDisplay == "40.00%")
        #expect(profile.sharesDisplay == "156,558,200")
    }

    @Test func toleratesMissingOptionalFields() throws {
        // A `data` envelope with no `history` block parses to nils, not a thrown error.
        let info = try EmittenService.parseInfo(Data(#"{"data":{"symbol":"AAA","name":"A"}}"#.utf8))
        #expect(info.sector == "")          // absent → blank, not malformed
        #expect(info.indexes.isEmpty)
        let profile = try EmittenService.parseProfile(Data(#"{"data":{}}"#.utf8))
        #expect(profile.freeFloatDisplay == nil)
        #expect(profile.sharesDisplay == nil)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { _ = try EmittenService.parseInfo(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { _ = try EmittenService.parseProfile(Data("not json".utf8)) }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct EmittenServiceErrorMappingTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = EmittenService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: EmittenError.unauthorized) { _ = try await svc.info(symbol: "WIFI") }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = EmittenService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: EmittenError.paywall) { _ = try await svc.profile(symbol: "WIFI") }
    }

    @Test func happyPathParsesInfo() async throws {
        let svc = EmittenService(apiClient: signedInClient([.init(status: 200, body: wifiInfoJSON)]))
        let info = try await svc.info(symbol: "WIFI")
        #expect(info.sector == "Teknologi")
    }

    @Test func mapsMalformedFromBadBody() async {
        let svc = EmittenService(apiClient: signedInClient([.init(status: 200, body: Data("garbage".utf8))]))
        await #expect(throws: EmittenError.malformedResponse) { _ = try await svc.profile(symbol: "WIFI") }
    }
}

// MARK: - Company-field adapters (SelectionFundamentals, Phase 1.4)

@Suite struct CompanyFieldAdapterTests {
    /// Verbatim WIFI keystats slice (from the capture) for the shares derivation.
    private let wifiKeystats: [String: String] = [
        "1555": "490 B",       // Net Income (TTM)
        "13200": "92.39",      // Current EPS (TTM)
        "15883": "7,464 B",    // Common Equity
        "15718": "1,406.02",   // Book Value Per Share
    ]

    @Test func freeFloatPercentBecomesRatio() throws {
        let profile = EmittenProfile(freeFloatDisplay: "40.00%", sharesDisplay: nil)
        let ff = try #require(SelectionFundamentals.freeFloat(fromProfile: profile))
        #expect(abs(ff - 0.40) < 1e-9)
    }

    @Test func freeFloatIsNilWhenAbsent() {
        #expect(SelectionFundamentals.freeFloat(fromProfile: EmittenProfile(freeFloatDisplay: nil, sharesDisplay: nil)) == nil)
        #expect(SelectionFundamentals.freeFloat(fromProfile: EmittenProfile(freeFloatDisplay: "-", sharesDisplay: nil)) == nil)
    }

    @Test func sharesOutstandingFromNetIncomeOverEps() throws {
        // 490e9 / 92.39 ≈ 5.30 B (matches Common Equity ÷ BVPS, ~5.31 B — the §11 cross-check).
        let shares = try #require(SelectionFundamentals.sharesOutstanding(fromKeystats: wifiKeystats))
        let count = NSDecimalNumber(decimal: shares).doubleValue
        #expect(count > 5_290_000_000 && count < 5_320_000_000)
    }

    @Test func sharesOutstandingFallsBackToEquityOverBvpsForLossMakers() throws {
        // Loss-maker: negative EPS makes NI÷EPS meaningless → fall back to Common Equity ÷ BVPS.
        var lossMaker = wifiKeystats
        lossMaker["1555"] = "(120 B)"   // negative net income
        lossMaker["13200"] = "-5.00"    // negative EPS → primary basis rejected
        let shares = try #require(SelectionFundamentals.sharesOutstanding(fromKeystats: lossMaker))
        let count = NSDecimalNumber(decimal: shares).doubleValue
        #expect(count > 5_300_000_000 && count < 5_320_000_000)   // 7,464e9 / 1,406.02
    }

    @Test func sharesOutstandingIsNilWhenNoBasisAvailable() {
        // EPS ≤ 0 and no equity/BVPS → cannot derive a share count.
        #expect(SelectionFundamentals.sharesOutstanding(fromKeystats: ["13200": "-1.0"]) == nil)
        #expect(SelectionFundamentals.sharesOutstanding(fromKeystats: [:]) == nil)
    }

    @Test func assigningSharesStampsLatestAnnualOnly() {
        func annual(_ year: Int) -> AnnualFinancials {
            AnnualFinancials(year: year, revenue: 1, netIncome: 1, operatingCashFlow: 1,
                             totalAssets: 1, totalLiabilities: 1, currentAssets: 1, currentLiabilities: 1,
                             shareholderEquity: 1, receivables: 1, sharesOutstanding: 0)
        }
        let stamped = SelectionFundamentals.assigning(sharesOutstanding: Decimal(5_300_000_000),
                                                      toLatestOf: [annual(2024), annual(2025)])
        #expect(stamped.first?.sharesOutstanding == 0)              // 2024 untouched
        #expect(stamped.last?.sharesOutstanding == Decimal(5_300_000_000))  // 2025 stamped
        #expect(SelectionFundamentals.assigning(sharesOutstanding: 1, toLatestOf: []).isEmpty)
    }
}
