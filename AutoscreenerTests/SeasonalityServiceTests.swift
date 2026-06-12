import Foundation
import Testing
@testable import Autoscreener

// Fixture: real columns from the TPIA `seasonality/TPIA?year=2026&back_year=0` capture (2026-06-11),
// trimmed to Jan–Apr + the "Year" aggregate. Every "value" is a display string; `avg` carries
// negatives ("-3.00") and the UI-only hex `color`s plus the per-year `price_change` grid are present
// in the payload but must be ignored by the decoder.
private let seasonalityJSON = Data(#"""
{"message":"Successfully retrieved seasonality data","data":{
 "price_change":[{"row":2026,"columns":[{"name":"Year","value":"-74.86","color":"#E24D4D"},{"name":"Jan","value":"-7.86","color":"#E24D4D"}]}],
 "up":{"columns":[
   {"name":"Jan","value":"5","color":"#FFFFFF"},{"name":"Feb","value":"3","color":"#FFFFFF"},
   {"name":"Mar","value":"7","color":"#FFFFFF"},{"name":"Apr","value":"6","color":"#FFFFFF"},
   {"name":"Year","value":"5","color":"#FFFFFF"}]},
 "down":{"columns":[
   {"name":"Jan","value":"5","color":"#FFFFFF"},{"name":"Feb","value":"6","color":"#FFFFFF"},
   {"name":"Mar","value":"3","color":"#FFFFFF"},{"name":"Apr","value":"4","color":"#FFFFFF"},
   {"name":"Year","value":"5","color":"#FFFFFF"}]},
 "total_months":{"columns":[
   {"name":"Jan","value":"10","color":"#FFFFFF"},{"name":"Feb","value":"10","color":"#FFFFFF"},
   {"name":"Mar","value":"10","color":"#FFFFFF"},{"name":"Apr","value":"10","color":"#FFFFFF"},
   {"name":"Year","value":"10","color":"#FFFFFF"}]},
 "avg":{"columns":[
   {"name":"Jan","value":"1.20","color":"#007746"},{"name":"Feb","value":"-3.00","color":"#A52121"},
   {"name":"Mar","value":"0.05","color":"#007746"},{"name":"Apr","value":"11.08","color":"#29A85B"},
   {"name":"Year","value":"19.86","color":"#3DC165"}]},
 "prob":{"columns":[
   {"name":"Jan","value":"50","color":"#149050"},{"name":"Feb","value":"30","color":"#A52121"},
   {"name":"Mar","value":"70","color":"#149050"},{"name":"Apr","value":"60","color":"#149050"},
   {"name":"Year","value":"50","color":"#149050"}]},
 "default_last_year":10}}
"""#.utf8)

// MARK: - Endpoint wire format

@Suite struct SeasonalityEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in item.value.map { (item.name, $0) } })
    }

    @Test func buildsPathAndQuery() {
        let ep = SeasonalityService.makeEndpoint(symbol: "TPIA", year: 2026, backYear: 0)
        #expect(ep.method == .get)
        #expect(ep.path == "seasonality/TPIA")
        #expect(ep.requiresAuth)
        #expect(query(ep)["year"] == "2026")
        #expect(query(ep)["back_year"] == "0")
    }
}

// MARK: - Parsing the verified wire shape

@Suite struct SeasonalityParseTests {
    @Test func zipsParallelColumnsByMonth() throws {
        let s = try SeasonalityService.parse(seasonalityJSON, symbol: "TPIA")
        #expect(s.symbol == "TPIA")
        // Jan–Apr + the "Year" aggregate, in calendar order off the `up` spine.
        #expect(s.months.map(\.name) == ["Jan", "Feb", "Mar", "Apr", "Year"])

        let apr = try #require(s.month("Apr"))
        #expect(apr.upCount == 6)
        #expect(apr.downCount == 4)
        #expect(apr.totalYears == 10)
        #expect(apr.avgReturnPct == 11.08)
        #expect(apr.probabilityUpPct == 60)
    }

    @Test func parsesNegativeAverageReturn() throws {
        let s = try SeasonalityService.parse(seasonalityJSON, symbol: "TPIA")
        let feb = try #require(s.month("Feb"))
        #expect(feb.avgReturnPct == -3.00)
        #expect(feb.upCount == 3)
        #expect(feb.downCount == 6)
    }

    @Test func exposesYearAggregate() throws {
        let s = try SeasonalityService.parse(seasonalityJSON, symbol: "TPIA")
        let year = try #require(s.month("Year"))
        #expect(year.avgReturnPct == 19.86)
        #expect(year.totalYears == 10)
    }

    @Test func missingDataThrows() {
        let nullData = Data(#"{"message":"x","data":null}"#.utf8)
        #expect(throws: (any Error).self) { _ = try SeasonalityService.parse(nullData, symbol: "TPIA") }
    }
}

// MARK: - Service through APIClient (error mapping)

@Suite struct SeasonalityServiceTests {
    private func signedInClient(_ stubs: [StubSession.Stub]) -> APIClient {
        APIClient(session: StubSession(stubs),
                  tokens: InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func mapsUnauthorizedWhenNoToken() async {
        let svc = SeasonalityService(apiClient: APIClient(session: StubSession([]), tokens: InMemoryTokenStore()))
        await #expect(throws: SeasonalityError.unauthorized) {
            _ = try await svc.seasonality(symbol: "TPIA", year: 2026)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let svc = SeasonalityService(apiClient: signedInClient([.init(status: 403, body: Data())]))
        await #expect(throws: SeasonalityError.paywall) {
            _ = try await svc.seasonality(symbol: "TPIA", year: 2026)
        }
    }

    @Test func happyPathReturnsSeasonality() async throws {
        let svc = SeasonalityService(apiClient: signedInClient([.init(status: 200, body: seasonalityJSON)]))
        let s = try await svc.seasonality(symbol: "TPIA", year: 2026)
        #expect(s.months.count == 5)
        #expect(s.month("Apr")?.probabilityUpPct == 60)
    }
}
