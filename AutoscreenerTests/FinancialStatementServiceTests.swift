import Foundation
import Testing
@testable import Autoscreener

// MARK: - Endpoint wire format

@Suite struct FinancialStatementEndpointTests {
    private func query(_ ep: Endpoint) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ep.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    @Test func buildsPathAndFixedQuery() {
        let ep = FinancialStatementService.makeEndpoint(symbol: "TPIA", report: .income, basis: .annual)
        #expect(ep.method == .get)
        #expect(ep.path == "findata-view/v2/financials/TPIA")
        let q = query(ep)
        #expect(q["data_type"] == "1")
        #expect(q["is_percentage"] == "0")
        #expect(q["page"] == "1")
    }

    @Test func mapsReportTypeToQuery() {
        #expect(query(FinancialStatementService.makeEndpoint(symbol: "X", report: .income, basis: .annual))["report_type"] == "1")
        #expect(query(FinancialStatementService.makeEndpoint(symbol: "X", report: .balanceSheet, basis: .annual))["report_type"] == "2")
        #expect(query(FinancialStatementService.makeEndpoint(symbol: "X", report: .cashFlow, basis: .annual))["report_type"] == "3")
    }

    @Test func mapsPeriodBasisToStatementType() {
        #expect(query(FinancialStatementService.makeEndpoint(symbol: "X", report: .income, basis: .quarterly))["statement_type"] == "1")
        #expect(query(FinancialStatementService.makeEndpoint(symbol: "X", report: .income, basis: .annual))["statement_type"] == "2")
    }
}

// MARK: - Response parsing

@Suite struct FinancialStatementParseTests {
    // Trimmed from the live TPIA capture (income statement, annual).
    static let incomeAnnual = Data(#"""
    {
      "message": "Successfully retrieved company financial",
      "data": {
        "currency": ["IDR", "USD"],
        "default_currency": "IDR",
        "rounding_value": [1000000000, 1000000],
        "data_tables": {
          "periods": ["12M 2025", "12M 2024"],
          "accounts": [
            {"id":127,"level":1,"name":"<b>Pendapatan</b>","values":["115,672 B","28,298 B"],"accounts":[],"is_total_exist":true,"is_default_expanded":false,"max_show_level":2},
            {"id":131,"level":1,"name":"Beban Pokok Penjualan","values":["(116,372 B)","(25,807 B)"],"accounts":[],"is_total_exist":true,"is_default_expanded":false,"max_show_level":2},
            {"id":0,"level":1,"name":"","values":[],"accounts":[],"is_total_exist":true,"is_default_expanded":false,"max_show_level":2},
            {"id":137,"level":1,"name":"Beban Usaha","values":[],"is_default_expanded":false,"max_show_level":2,"accounts":[
              {"id":139,"level":2,"name":"Beban Penjualan","values":["(1,222 B)","(684 B)"],"accounts":[],"is_default_expanded":false}
            ]}
          ]
        }
      }
    }
    """#.utf8)

    // Quarterly periods + a node missing `is_default_expanded` (tolerance check).
    static let incomeQuarterly = Data(#"""
    {"data":{"default_currency":"IDR","data_tables":{
      "periods":["Q1 2026","Q4 2025"],
      "accounts":[{"id":127,"level":1,"name":"Pendapatan","values":["100","200"],"accounts":[]}]
    }}}
    """#.utf8)

    @Test func parsesCurrencyAndPeriods() throws {
        let s = try FinancialStatementService.parse(Self.incomeAnnual)
        #expect(s.currency == "IDR")
        #expect(s.periods == ["12M 2025", "12M 2024"])
    }

    @Test func parsesQuarterlyPeriods() throws {
        let s = try FinancialStatementService.parse(Self.incomeQuarterly)
        #expect(s.periods == ["Q1 2026", "Q4 2025"])
        #expect(s.accounts.first?.defaultExpanded == false) // absent key tolerated
    }

    @Test func stripsBoldTagsAndFlagsEmphasis() throws {
        let s = try FinancialStatementService.parse(Self.incomeAnnual)
        let pendapatan = s.accounts[0]
        #expect(pendapatan.name == "Pendapatan")        // <b>…</b> stripped
        #expect(pendapatan.isEmphasized == true)
        #expect(pendapatan.accountID == 127)
        #expect(pendapatan.values == ["115,672 B", "28,298 B"])

        let cogs = s.accounts[1]
        #expect(cogs.name == "Beban Pokok Penjualan")
        #expect(cogs.isEmphasized == false)             // no bold tags
    }

    @Test func preservesNegativeDisplayStrings() throws {
        let s = try FinancialStatementService.parse(Self.incomeAnnual)
        #expect(s.accounts[1].values.first == "(116,372 B)")
    }

    @Test func assignsPositionalPathIDsAndNestsChildren() throws {
        let s = try FinancialStatementService.parse(Self.incomeAnnual)
        #expect(s.accounts.map(\.id) == ["0", "1", "2", "3"])
        let bebanUsaha = s.accounts[3]
        #expect(bebanUsaha.name == "Beban Usaha")
        #expect(bebanUsaha.children.count == 1)
        #expect(bebanUsaha.children[0].id == "3.0")
        #expect(bebanUsaha.children[0].name == "Beban Penjualan")
        #expect(bebanUsaha.children[0].level == 2)
    }

    @Test func keepsSpacerRowsAsEmpty() throws {
        let s = try FinancialStatementService.parse(Self.incomeAnnual)
        let spacer = s.accounts[2]
        #expect(spacer.name == "")
        #expect(spacer.values.isEmpty)
        #expect(spacer.children.isEmpty)
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try FinancialStatementService.parse(Data("not json".utf8))
        }
    }
}

// MARK: - Service error mapping (real APIClient + stubbed transport)

@Suite struct FinancialStatementServiceErrorMappingTests {
    @Test func mapsUnauthorizedWhenNoToken() async {
        let store = InMemoryTokenStore()
        let client = APIClient(session: StubSession([]), tokens: store)
        let svc = FinancialStatementService(apiClient: client)

        await #expect(throws: FinancialStatementError.unauthorized) {
            _ = try await svc.load(symbol: "TPIA", report: .income, basis: .annual)
        }
    }

    @Test func mapsPaywallFromHttp403() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 403, body: Data())]), tokens: store)
        let svc = FinancialStatementService(apiClient: client)

        await #expect(throws: FinancialStatementError.paywall) {
            _ = try await svc.load(symbol: "TPIA", report: .income, basis: .annual)
        }
    }

    @Test func mapsMalformedFromBadBody() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let client = APIClient(session: StubSession([.init(status: 200, body: Data("garbage".utf8))]), tokens: store)
        let svc = FinancialStatementService(apiClient: client)

        await #expect(throws: FinancialStatementError.malformedResponse) {
            _ = try await svc.load(symbol: "TPIA", report: .income, basis: .annual)
        }
    }
}
