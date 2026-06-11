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
        #expect(MarketCatalog.grouped().map(\.0) == [.global, .composite, .index, .sector, .commodity, .currency])
    }

    @Test func coversAllGlobalIndices() {
        let expected: Set<String> = [
            "SP500", "DOW30", "NASDAQ", "FTSE", "DAX", "CAC40",
            "NIKKEI", "HANGSENG", "KOSPI", "SHANGHAI", "STI",
        ]
        let global = Set(MarketCatalog.all.filter { $0.group == .global }.map(\.symbol))
        #expect(global == expected)
    }

    @Test func globalIndicesAreChartable() {
        #expect(MarketGroup.global.hasChart)
    }

    @Test func includesAllCommodityAndCurrencySymbols() {
        let commoditiesAndFX = Set(
            MarketCatalog.all
                .filter { $0.group == .commodity || $0.group == .currency }
                .map(\.symbol))
        let expected: Set<String> = [
            "OIL", "BRENT", "GAS", "COAL-NEWCASTLE", "CPO", "XAU", "SILVER",
            "NICKEL", "COPPER", "ALUMINIUM", "TIN", "ZINC-COMMODITIES", "RUBBER",
            "USDIDR",
        ]
        #expect(commoditiesAndFX == expected)
    }

    @Test func usdIdrIsTheOnlyCurrency() {
        let currencies = MarketCatalog.all.filter { $0.group == .currency }.map(\.symbol)
        #expect(currencies == ["USDIDR"])
    }
}
