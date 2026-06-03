import Foundation
import Testing
@testable import Autoscreener

@Suite struct SymbolSearchTests {
    private func rows() -> [ScreenerRow] {
        [
            ScreenerRow(symbol: "BBCA", name: "Bank Central Asia", values: [], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "BBRI", name: "Bank Rakyat Indonesia", values: [], lastPrice: nil, pctChange: nil),
            ScreenerRow(symbol: "TLKM", name: "Telkom Indonesia", values: [], lastPrice: nil, pctChange: nil),
        ]
    }

    @Test func blankQueryReturnsAllRows() {
        #expect(rows().filteredBySymbol("").count == 3)
        #expect(rows().filteredBySymbol("   ").count == 3)
    }

    @Test func matchIsCaseInsensitive() {
        let result = rows().filteredBySymbol("bbca")
        #expect(result.map(\.symbol) == ["BBCA"])
    }

    @Test func matchesSubstringOfSymbol() {
        // "BB" is a substring of both BBCA and BBRI, not TLKM.
        let result = rows().filteredBySymbol("BB")
        #expect(Set(result.map(\.symbol)) == ["BBCA", "BBRI"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(rows().filteredBySymbol("XXXX").isEmpty)
    }

    @Test func matchesSymbolOnlyNotCompanyName() {
        // "Telkom" appears in a company name but in no symbol → no matches.
        #expect(rows().filteredBySymbol("Telkom").isEmpty)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let result = rows().filteredBySymbol("  tlkm  ")
        #expect(result.map(\.symbol) == ["TLKM"])
    }
}
