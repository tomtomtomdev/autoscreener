import Foundation
import Testing
@testable import Autoscreener

@Suite struct BIRateServiceTests {
    static let fredCSV = Data("observation_date,IRSTCB01IDM156N\n2025-12-01,5.00\n2026-01-01,4.75\n".utf8)
    static let htmlNoRows = Data("<html><body><p>maintenance</p></body></html>".utf8)

    @Test func parsesBIRateFromHTMLPrimarySource() async {
        let html = Data(MacroParsingTests.biRateHTML.utf8)
        let svc = BIRateService(session: StubSession([.init(status: 200, body: html)]))
        let bi = await svc.biRate()
        #expect(bi?.value == 5.25)
        #expect(bi?.direction == .hike)
        #expect(bi?.asOf == "2026-05-20")
    }

    @Test func fallsBackToFREDWhenHTMLHasNoTable() async {
        let svc = BIRateService(session: StubSession([
            .init(status: 200, body: Self.htmlNoRows),  // primary parses to nothing
            .init(status: 200, body: Self.fredCSV),      // → fallback
        ]))
        let bi = await svc.biRate()
        #expect(bi?.value == 4.75)
        #expect(bi?.direction == .cut)
        #expect(bi?.asOf == "2026-01-01")
    }

    @Test func fallsBackToFREDWhenHTMLRequestErrors() async {
        let svc = BIRateService(session: StubSession([
            .init(status: 503, body: Data()),            // primary HTTP error
            .init(status: 200, body: Self.fredCSV),
        ]))
        let bi = await svc.biRate()
        #expect(bi?.value == 4.75)
    }

    @Test func returnsNilWhenBothSourcesFail() async {
        let svc = BIRateService(session: StubSession([
            .init(status: 503, body: Data()),
            .init(status: 500, body: Data()),
        ]))
        let bi = await svc.biRate()
        #expect(bi == nil)
    }
}
