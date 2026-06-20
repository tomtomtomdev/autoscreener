import Foundation
import Testing
@testable import Autoscreener

/// The Asia-EM equity-appetite reading — the regional EEM proxy assembled from the basket's price
/// series. Verifies the 200dma averaging, the EM-vs-developed-market relative read, the deliberate
/// Japan exclusion, and graceful degradation. The distance maths itself is `MovingAverage`'s tested
/// job, so the expectations are derived from it rather than hard-coded.
@Suite struct AsiaEMTests {
    /// A series whose closes are the given values on consecutive days (oldest first).
    private func series(_ closes: [Double]) -> PriceSeries {
        let base = Date(timeIntervalSince1970: 0)
        let candles = closes.enumerated().map { index, close in
            PriceCandle(date: base.addingTimeInterval(Double(index) * 86_400),
                        open: close, high: close, low: close, close: close, volume: 0)
        }
        return PriceSeries(symbol: "X", timeframe: .oneYear, previousClose: nil, candles: candles)
    }

    /// A 200-candle series flat at `base` for 199 days then closing at `latest` — enough history
    /// for a 200-day average, with the latest close off the mean so the distance is non-zero.
    private func trended(latest: Double, flatAt base: Double = 100) -> PriceSeries {
        series(Array(repeating: base, count: 199) + [latest])
    }

    @Test func averagesTheBasketDistancesAndComputesTheRelativeToTheSP() {
        let hangSeng = trended(latest: 110)   // above its 200dma
        let kospi = trended(latest: 105)
        let hDist = MovingAverage.distanceFromSMA(hangSeng, period: 200)!
        let kDist = MovingAverage.distanceFromSMA(kospi, period: 200)!
        let expectedRegional = (hDist + kDist) / 2

        let reading = AsiaEM.reading(
            series: ["HANGSENG": hangSeng, "KOSPI": kospi], sp500Distance: 0.03)

        #expect(abs(reading!.regionalDistance - expectedRegional) < 1e-12)
        #expect(abs(reading!.relativeToSP! - (expectedRegional - 0.03)) < 1e-12)
        #expect(reading?.contributors == ["Hang Seng", "KOSPI"])   // basket order, Shanghai absent
    }

    @Test func excludesJapanBecauseItIsADevelopedMarket() {
        // A NIKKEI series is priced but must NOT enter the EM basket — Japan is the DM side of the
        // comparison. Only Hang Seng contributes, so the regional read equals its lone distance.
        let hangSeng = trended(latest: 108)
        let nikkei = trended(latest: 130)
        let reading = AsiaEM.reading(
            series: ["HANGSENG": hangSeng, "NIKKEI": nikkei], sp500Distance: nil)

        #expect(reading?.contributors == ["Hang Seng"])
        #expect(reading?.regionalDistance == MovingAverage.distanceFromSMA(hangSeng, period: 200))
    }

    @Test func relativeIsNilAndVoteFallsBackToTheRegionalTrendWithoutABenchmark() {
        let reading = AsiaEM.reading(
            series: ["SHANGHAI": trended(latest: 112)], sp500Distance: nil)
        #expect(reading?.relativeToSP == nil)
        #expect(reading?.voteStrength == reading?.regionalDistance)   // absolute fallback
    }

    @Test func voteStrengthIsTheRelativeSpreadWhenTheBenchmarkIsPresent() {
        let reading = AsiaEMReading(regionalDistance: 0.05, contributors: ["Hang Seng"], relativeToSP: 0.02)
        #expect(reading.voteStrength == 0.02)
    }

    @Test func skipsAMemberWithTooLittleHistory() {
        // Hang Seng has only 50 candles → no computable 200dma → excluded. Shanghai carries it.
        let reading = AsiaEM.reading(
            series: ["HANGSENG": series(Array(repeating: 100, count: 50)),
                     "SHANGHAI": trended(latest: 115)], sp500Distance: 0.0)
        #expect(reading?.contributors == ["Shanghai"])
    }

    @Test func nilWhenNoBasketMemberHasEnoughHistory() {
        // Only Japan priced (excluded) and a too-short Shanghai → nothing to average → factor drops.
        let reading = AsiaEM.reading(
            series: ["NIKKEI": trended(latest: 120),
                     "SHANGHAI": series(Array(repeating: 100, count: 10))], sp500Distance: 0.0)
        #expect(reading == nil)
    }
}
