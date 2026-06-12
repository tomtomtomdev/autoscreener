import Foundation
import Testing
@testable import Autoscreener

@Suite struct FREDMacroServiceTests {
    func csv(_ id: String, _ rows: String) -> Data {
        Data("observation_date,\(id)\n\(rows)".utf8)
    }

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
