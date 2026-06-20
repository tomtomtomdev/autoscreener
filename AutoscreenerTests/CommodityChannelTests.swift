import Foundation
import Testing
@testable import Autoscreener

/// The "China channel" reading — Indonesia's commodity export terms of trade, assembled from the
/// sweep's already-priced market quotes (so the factor costs no extra network). Verifies the basket
/// selection (incl. the deliberate oil exclusion), the CNY context, and graceful degradation.
@Suite struct CommodityChannelTests {
    private func quote(_ symbol: String, _ changePercent: Double?) -> CommodityQuote {
        CommodityQuote(symbol: symbol, name: symbol, price: 100, previousClose: 100,
                       change: nil, changePercent: changePercent, volume: nil,
                       formattedPrice: "100", asOf: "")
    }

    @Test func averagesThePresentExportBasket() {
        // coal +3, CPO −1, nickel +1 → mean +1.
        let reading = CommodityChannel.reading(quotes: [
            "COAL-NEWCASTLE": quote("COAL-NEWCASTLE", 3),
            "CPO": quote("CPO", -1),
            "NICKEL": quote("NICKEL", 1),
        ])
        #expect(reading?.basketChangePercent == 1)
        #expect(reading?.contributors == ["coal", "CPO", "nickel"])
    }

    @Test func excludesOilBecauseIndonesiaIsANetImporter() {
        // Oil is priced but must NOT enter the basket: a higher oil price is an import-cost drag
        // for Indonesia, so it's wrong-signed as a terms-of-trade input. Only nickel counts.
        let reading = CommodityChannel.reading(quotes: [
            "OIL": quote("OIL", 10),
            "NICKEL": quote("NICKEL", 2),
        ])
        #expect(reading?.basketChangePercent == 2)        // oil ignored
        #expect(reading?.contributors == ["nickel"])
    }

    @Test func picksUpCnyAsContextWhenPriced() {
        let reading = CommodityChannel.reading(quotes: [
            "NICKEL": quote("NICKEL", 2),
            "CNYIDR": quote("CNYIDR", 0.4),
        ])
        #expect(reading?.cnyChangePercent == 0.4)
    }

    @Test func cnyAbsentWhenNotPriced() {
        let reading = CommodityChannel.reading(quotes: ["NICKEL": quote("NICKEL", 2)])
        #expect(reading?.cnyChangePercent == nil)
    }

    @Test func nilWhenNoBasketCommodityPriced() {
        // CNY alone (no basket commodity) is not enough — the vote needs the basket, so the
        // factor drops, like any other absent regime leg.
        let reading = CommodityChannel.reading(quotes: ["CNYIDR": quote("CNYIDR", 0.4)])
        #expect(reading == nil)
    }

    @Test func skipsACommodityWithNoChangePercent() {
        // A coal quote priced but with a nil changePercent contributes nothing and isn't listed.
        let reading = CommodityChannel.reading(quotes: [
            "COAL-NEWCASTLE": quote("COAL-NEWCASTLE", nil),
            "NICKEL": quote("NICKEL", 2),
        ])
        #expect(reading?.basketChangePercent == 2)
        #expect(reading?.contributors == ["nickel"])
    }
}
