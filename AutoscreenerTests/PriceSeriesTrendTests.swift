import Foundation
import Testing
@testable import Autoscreener

/// `PriceSeries.isUp` — the whole-window direction that colors the line + gradient fill
/// (green up / red down). Pure model logic, independent of SwiftUI.
@Suite struct PriceSeriesTrendTests {
    private func candle(_ close: Double, at offset: TimeInterval = 0) -> PriceCandle {
        PriceCandle(date: Date(timeIntervalSince1970: 1_748_000_000 + offset),
                    open: close, high: close, low: close, close: close, volume: 1)
    }

    private func series(previousClose: Double?, closes: [Double]) -> PriceSeries {
        PriceSeries(
            symbol: "TEST", timeframe: .oneYear, previousClose: previousClose,
            candles: closes.enumerated().map { candle($0.element, at: Double($0.offset) * 86_400) })
    }

    @Test func upWhenLatestCloseIsAbovePreviousClose() {
        #expect(series(previousClose: 1_000, closes: [1_005, 1_010]).isUp == true)
    }

    @Test func downWhenLatestCloseIsBelowPreviousClose() {
        #expect(series(previousClose: 1_000, closes: [995, 990]).isUp == false)
    }

    @Test func flatCountsAsUp() {
        #expect(series(previousClose: 1_000, closes: [1_000]).isUp == true)  // >= is up
    }

    @Test func fallsBackToFirstBarWhenNoPreviousClose() {
        #expect(series(previousClose: nil, closes: [1_000, 1_010]).isUp == true)
        #expect(series(previousClose: nil, closes: [1_010, 1_000]).isUp == false)
    }

    @Test func singleBarWithoutPreviousCloseIsUp() {
        // baseline == the only close → flat → up.
        #expect(series(previousClose: nil, closes: [1_000]).isUp == true)
    }

    @Test func emptySeriesDefaultsToUp() {
        // Nothing is drawn for an empty series; the color is irrelevant, so default green.
        #expect(series(previousClose: 1_000, closes: []).isUp == true)
    }
}
