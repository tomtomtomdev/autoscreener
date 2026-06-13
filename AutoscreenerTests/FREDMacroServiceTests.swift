import Foundation
import Testing
@testable import Autoscreener

@Suite struct FREDMacroServiceTests {
    func csv(_ id: String, _ rows: String) -> Data {
        Data("observation_date,\(id)\n\(rows)".utf8)
    }

    /// A `series/observations` JSON body — `value` is a string, `"."` = missing, exactly
    /// as the FRED API renders it.
    func json(_ rows: [(date: String, value: String)]) -> Data {
        let obs = rows.map { #"{"date":"\#($0.date)","value":"\#($0.value)"}"# }.joined(separator: ",")
        return Data(#"{"observations":[\#(obs)]}"#.utf8)
    }

    // MARK: - Keyed JSON API (primary path)

    @Test func usesKeyedJSONAPIWhenKeyConfigured() async {
        // Same three series the CSV test uses, now served as API JSON in DFF/DGS10/DTWEXBGS order.
        let session = StubSession([
            .init(status: 200, body: json([("2026-06-01", "4.50"), ("2026-06-03", "4.33")])),   // falling
            .init(status: 200, body: json([("2026-06-01", "4.00"), ("2026-06-03", "4.10")])),   // rising
            .init(status: 200, body: json([("2026-06-01", "119.0"), ("2026-06-03", "119.0")])), // flat, >50
        ])
        let svc = FREDMacroService(session: session, apiKey: "test-key")
        let block = await svc.macro()
        #expect(block?.usFedFunds?.value == 4.33)
        #expect(block?.usFedFunds?.trend == .down)
        #expect(block?.us10y?.value == 4.10)
        #expect(block?.us10y?.trend == .up)
        #expect(block?.broadDollar?.value == 119.0)
        #expect(block?.broadDollar?.trend == .flat)

        // It hit the keyed API endpoint with the key, not the CSV graph endpoint.
        let first = session.received.first?.url?.absoluteString ?? ""
        #expect(first.contains("api.stlouisfed.org/fred/series/observations"))
        #expect(first.contains("series_id=DFF"))
        #expect(first.contains("api_key=test-key"))
        #expect(first.contains("file_type=json"))
    }

    @Test func dropsMissingDotsInJSON() async {
        let session = StubSession([
            // A "." (missing) row between two real ones — dropped, latest is 4.10 rising.
            .init(status: 200, body: json([("2026-06-01", "4.00"), ("2026-06-02", "."), ("2026-06-03", "4.10")])),
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
        ])
        let svc = FREDMacroService(session: session, apiKey: "test-key")
        let block = await svc.macro()
        #expect(block?.usFedFunds?.value == 4.10)
        #expect(block?.usFedFunds?.trend == .up)
    }

    @Test func omitsSeriesWhenAPIReturnsErrorBody() async {
        // A bad/absent key makes FRED return an error JSON (HTTP 200, no `observations`):
        // the series parses empty and is omitted, like any failed fetch.
        let session = StubSession([
            .init(status: 200, body: Data(#"{"error_code":400,"error_message":"Bad Request."}"#.utf8)),
            .init(status: 200, body: json([("2026-06-01", "4.00"), ("2026-06-03", "4.10")])),
            .init(status: 200, body: json([("2026-06-01", "118.0"), ("2026-06-03", "119.0")])),
        ])
        let svc = FREDMacroService(session: session, apiKey: "test-key")
        let block = await svc.macro()
        #expect(block?.usFedFunds == nil)            // error body → omitted
        #expect(block?.us10y?.trend == .up)
        #expect(block?.broadDollar?.trend == .up)
    }

    // MARK: - Keyless CSV (fallback when no key)

    @Test func fallsBackToCSVEndpointWhenNoKey() async {
        let session = StubSession([
            .init(status: 200, body: csv("DFF", "2026-06-01,4.50\n2026-06-03,4.33\n")),
            .init(status: 200, body: csv("DGS10", "2026-06-01,4.00\n2026-06-03,4.10\n")),
            .init(status: 200, body: csv("DTWEXBGS", "2026-06-01,119.0\n2026-06-03,119.0\n")),
        ])
        let svc = FREDMacroService(session: session)   // no key → CSV path
        let block = await svc.macro()
        #expect(block?.usFedFunds?.value == 4.33)
        #expect(session.received.first?.url?.absoluteString.contains("fredgraph.csv") == true)
    }

    // MARK: - Series assembly (CSV fallback path)

    @Test func assemblesAllThreeSeriesInOrder() async {
        // Service GETs DFF, DGS10, DTWEXBGS in that order — StubSession serves in order.
        let svc = FREDMacroService(session: StubSession([
            .init(status: 200, body: csv("DFF", "2026-06-01,4.50\n2026-06-03,4.33\n")),       // falling
            .init(status: 200, body: csv("DGS10", "2026-06-01,4.00\n2026-06-03,4.10\n")),      // rising
            .init(status: 200, body: csv("DTWEXBGS", "2026-06-01,119.0\n2026-06-03,119.0\n")), // flat, >50
        ]))
        let block = await svc.macro()
        #expect(block?.usFedFunds?.value == 4.33)
        #expect(block?.usFedFunds?.trend == .down)
        #expect(block?.us10y?.value == 4.10)
        #expect(block?.us10y?.trend == .up)
        #expect(block?.broadDollar?.value == 119.0)   // magnitude-agnostic parse, not rejected
        #expect(block?.broadDollar?.trend == .flat)
    }

    @Test func omitsAFailedSeriesButKeepsTheRest() async {
        let svc = FREDMacroService(session: StubSession([
            .init(status: 200, body: csv("DFF", "2026-06-01,4.33\n2026-06-03,4.33\n")),
            .init(status: 500, body: Data()),                                          // DGS10 fails
            .init(status: 200, body: csv("DTWEXBGS", "2026-06-01,118.0\n2026-06-03,119.0\n")),
        ]))
        let block = await svc.macro()
        #expect(block?.usFedFunds != nil)
        #expect(block?.us10y == nil)                  // omitted, not fatal
        #expect(block?.broadDollar?.trend == .up)
    }

    @Test func returnsNilWhenAllSeriesFail() async {
        let svc = FREDMacroService(session: StubSession([
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
            .init(status: 500, body: Data()),
        ]))
        let block = await svc.macro()
        #expect(block == nil)
    }
}
