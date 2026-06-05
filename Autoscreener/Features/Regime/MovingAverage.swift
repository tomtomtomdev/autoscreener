import Foundation

/// Pure moving-average helpers over an OHLCV `PriceSeries`. Used by the regime read
/// for the IHSG 200-day trend signal and by `BreadthService` for the LQ45 breadth
/// count (`idx-investing-research.md` §3). Order-independent: candles are sorted by
/// date, so it doesn't matter whether the feed returns them oldest- or newest-first.
nonisolated enum MovingAverage {
    /// Simple moving average of the `period` most-recent closes by date. `nil` when
    /// fewer than `period` candles are available (e.g. a name with < 200 days of history).
    static func sma(_ candles: [PriceCandle], period: Int) -> Double? {
        guard period > 0, candles.count >= period else { return nil }
        let recent = candles.sorted { $0.date < $1.date }.suffix(period)
        return recent.reduce(0) { $0 + $1.close } / Double(period)
    }

    /// Fractional gap of the latest close from its `period`-day SMA: `(close − ma) / ma`.
    /// `nil` when there isn't enough history or the average is non-positive.
    static func distanceFromSMA(_ series: PriceSeries, period: Int) -> Double? {
        guard let latest = series.candles.max(by: { $0.date < $1.date })?.close,
              let ma = sma(series.candles, period: period), ma > 0 else { return nil }
        return (latest - ma) / ma
    }

    /// Whether the latest close sits above its `period`-day SMA. `nil` = insufficient data.
    static func isAboveSMA(_ series: PriceSeries, period: Int) -> Bool? {
        guard let distance = distanceFromSMA(series, period: period) else { return nil }
        return distance > 0
    }
}
