import Foundation
import Testing
@testable import Autoscreener

@MainActor
@Suite struct MarketDataStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("market-store-tests", isDirectory: true)
            .appendingPathComponent("cache-\(UUID().uuidString).json")
    }

    private func quote(_ symbol: String, price: Double = 100) -> CommodityQuote {
        CommodityQuote(symbol: symbol, name: "\(symbol) name", price: price, previousClose: 99,
                       change: 1, changePercent: 1.0, volume: 10, formattedPrice: "100", asOf: "now")
    }

    private func read(_ stance: RegimeStance) -> RegimeRead {
        RegimeRead(stance: stance, score: 0.1,
                   factors: [RegimeFactor(kind: .breadth, signal: .riskOn, detail: "62% above")],
                   asOf: "2026-06-11", valuationCapped: false)
    }

    @Test func applyQuotesMergesAndBumpsVersion() {
        let store = MarketDataStore(fileURL: nil, loadFromDisk: false)
        let v0 = store.version
        store.applyQuotes(["OIL": quote("OIL"), "XAU": quote("XAU")])
        store.applyQuotes(["OIL": quote("OIL", price: 105)])  // overwrite OIL, keep XAU

        #expect(store.quotes["OIL"]?.price == 105)
        #expect(store.quotes["XAU"] != nil)
        #expect(store.version == v0 + 2)
    }

    @Test func emptyApplyIsANoOp() {
        let store = MarketDataStore(fileURL: nil, loadFromDisk: false)
        store.applyQuotes(["OIL": quote("OIL")])
        let v = store.version
        store.applyQuotes([:])
        #expect(store.version == v)               // no bump
        #expect(store.quotes.count == 1)
    }

    @Test func applyRegimeReadBumpsVersion() {
        let store = MarketDataStore(fileURL: nil, loadFromDisk: false)
        let v0 = store.version
        store.apply(regimeRead: read(.neutral))
        #expect(store.regimeRead?.stance == .neutral)
        #expect(store.version == v0 + 1)
    }

    @Test func persistThenLoadRoundTripsQuotesAndRegimeReadToDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = MarketDataStore(fileURL: url, loadFromDisk: false)
        writer.applyQuotes(["IHSG": quote("IHSG", price: 7_200), "USDIDR": quote("USDIDR", price: 16_300)])
        writer.apply(regimeRead: read(.riskOff))
        writer.markSweepComplete(at: Date(timeIntervalSince1970: 5_000))

        let reader = MarketDataStore(fileURL: url, loadFromDisk: true)
        #expect(reader.quotes["IHSG"]?.price == 7_200)
        #expect(reader.quotes["USDIDR"]?.price == 16_300)
        #expect(reader.regimeRead?.stance == .riskOff)
        #expect(reader.regimeRead?.factors.first?.kind == .breadth)
        #expect(reader.lastSweepAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test func corruptFileIsIgnoredAndStoreStartsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = MarketDataStore(fileURL: url, loadFromDisk: true)
        #expect(store.quotes.isEmpty)
        #expect(store.regimeRead == nil)
    }
}
