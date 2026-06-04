import Foundation
import Testing
@testable import Autoscreener

@Suite struct MarketCatalogTests {
    @Test func includesCompositeIHSG() {
        let ihsg = MarketCatalog.all.first { $0.symbol == "IHSG" }
        #expect(ihsg?.group == .composite)
    }

    @Test func everyGroupIsNonEmpty() {
        for (group, symbols) in MarketCatalog.grouped() {
            #expect(!symbols.isEmpty, "\(group.rawValue) should have at least one symbol")
        }
    }

    @Test func symbolsAreUnique() {
        let symbols = MarketCatalog.all.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test func coversAllElevenIDXICSectors() {
        let expected: Set<String> = [
            "IDXENERGY", "IDXBASIC", "IDXINDUST", "IDXNONCYC", "IDXCYCLIC",
            "IDXHEALTH", "IDXFINANCE", "IDXPROPERT", "IDXTECHNO", "IDXINFRA", "IDXTRANS",
        ]
        let sectors = Set(MarketCatalog.all.filter { $0.group == .sector }.map(\.symbol))
        #expect(sectors == expected)
    }

    @Test func groupedPreservesDeclarationOrder() {
        #expect(MarketCatalog.grouped().map(\.0) == [.composite, .index, .sector])
    }
}
