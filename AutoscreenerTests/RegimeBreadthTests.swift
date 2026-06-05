import Foundation
import Testing
@testable import Autoscreener

// MARK: - Helpers

private func series(_ closes: [Double], symbol: String = "X") -> PriceSeries {
    let day: TimeInterval = 86_400
    let candles = closes.enumerated().map { i, c in
        PriceCandle(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * day),
                    open: c, high: c, low: c, close: c, volume: 1_000)
    }
    return PriceSeries(symbol: symbol, timeframe: .oneYear, previousClose: nil, candles: candles)
}

/// Chart service backed by a fixed symbol→series map; an unmapped symbol throws
/// (so the breadth count must skip it rather than fail the whole read).
private final class MapChartService: ChartServicing, @unchecked Sendable {
    let map: [String: PriceSeries]
    init(_ map: [String: PriceSeries]) { self.map = map }
    func candles(symbol: String, timeframe: ChartTimeframe, chartType: ChartType) async throws -> PriceSeries {
        guard let s = map[symbol] else { throw ChartError.network("missing \(symbol)") }
        return s
    }
}

// MARK: - MovingAverage

@Suite struct MovingAverageTests {
    @Test func smaAveragesTheMostRecentPeriodCloses() {
        let candles = series([100, 110, 120, 130]).candles
        #expect(MovingAverage.sma(candles, period: 4) == 115)   // (100+110+120+130)/4
        #expect(MovingAverage.sma(candles, period: 2) == 125)   // (120+130)/2
    }

    @Test func smaNilWhenFewerThanPeriod() {
        #expect(MovingAverage.sma(series([100, 110]).candles, period: 200) == nil)
        #expect(MovingAverage.sma([], period: 1) == nil)
    }

    @Test func distanceIsFractionalGapFromTheAverage() {
        // closes 90/100/110 → 3-day MA 100, latest 110 → +10%.
        let d = MovingAverage.distanceFromSMA(series([90, 100, 110]), period: 3)
        #expect(d != nil)
        #expect(abs(d! - 0.1) < 1e-9)
    }

    @Test func distanceIsOrderIndependent() {
        let ordered = series([90, 100, 110])
        let scrambled = PriceSeries(symbol: "X", timeframe: .oneYear, previousClose: nil,
                                    candles: ordered.candles.reversed())
        #expect(MovingAverage.distanceFromSMA(ordered, period: 3)
                == MovingAverage.distanceFromSMA(scrambled, period: 3))
    }

    @Test func isAboveReportsSideOrNilWhenShort() {
        #expect(MovingAverage.isAboveSMA(series([90, 100, 110]), period: 3) == true)
        #expect(MovingAverage.isAboveSMA(series([110, 100, 90]), period: 3) == false)
        #expect(MovingAverage.isAboveSMA(series([100, 110]), period: 200) == nil)
    }
}

// MARK: - BreadthService

@Suite struct BreadthServiceTests {
    private func upDownFixtures() -> MapChartService {
        let up = series((0..<200).map { 100 + Double($0) })      // latest >> MA → above
        let down = series((0..<200).map { 300 - Double($0) })    // latest << MA → below
        let short = series((0..<20).map { _ in 100 })            // < 200 days → not measurable
        return MapChartService(["UP1": up, "UP2": up, "DOWN1": down, "SHORT": short])
    }

    @Test func countsOnlyMeasurableNamesAndTheShareAboveTheirMA() async {
        let svc = BreadthService(chartService: upDownFixtures())
        // MISSING isn't in the map → throws → excluded. SHORT has < 200 days → excluded.
        let reading = await svc.reading(symbols: ["UP1", "UP2", "DOWN1", "SHORT", "MISSING"], period: 200)
        #expect(reading.measured == 3)   // UP1, UP2, DOWN1
        #expect(reading.above == 2)       // the two UPs
        #expect(abs(reading.fraction! - 2.0 / 3.0) < 1e-9)
    }

    @Test func fractionNilWhenNothingMeasurable() async {
        let svc = BreadthService(chartService: MapChartService([:]))
        let reading = await svc.reading(symbols: ["A", "B"], period: 200)
        #expect(reading.measured == 0)
        #expect(reading.fraction == nil)
    }
}
