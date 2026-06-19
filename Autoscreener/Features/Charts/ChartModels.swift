import Foundation

// MARK: - Domain

/// One OHLCV bar. `date` is the bar's opening instant, parsed from Stockbit's
/// epoch-millis string. Prices are in the symbol's quote unit (IDR for stocks,
/// index points for `IHSG`); `volume` is shares for stocks, an index figure for `IHSG`.
nonisolated struct PriceCandle: Sendable, Equatable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

/// An OHLCV series for one symbol over one timeframe. The same shape backs both
/// the market index (e.g. `IHSG`) and an individual stock (e.g. `CUAN`).
nonisolated struct PriceSeries: Sendable, Equatable {
    let symbol: String
    let timeframe: ChartTimeframe
    /// Reference close the API anchors the series to (prior session / prior window). `nil` if absent.
    let previousClose: Double?
    let candles: [PriceCandle]

    /// Whole-window direction for the line/area-fill color: up (green) when the latest close is at or
    /// above the reference — the `previousClose` the API anchors to, falling back to the first bar's
    /// close. Defaults to `true` for an empty series (nothing is drawn, so the colour is moot).
    var isUp: Bool {
        guard let last = candles.last?.close else { return true }
        let baseline = previousClose ?? candles.first?.close ?? last
        return last >= baseline
    }
}

// MARK: - Request parameters

/// Candlestick (O/H/L/C) vs. line (close only). The endpoint advertises both in
/// `allowed_chart_type`; we model exactly those two.
nonisolated enum ChartType: String, Sendable {
    case candle = "PRICE_CHART_TYPE_CANDLE"
    case line = "PRICE_CHART_TYPE_LINE"
}

/// Timeframe windows accepted by `charts/{symbol}/daily`, verified live against
/// CUAN + IHSG on 2026-06-04:
/// - `today` / `oneWeek` → intraday bars (minute-level)
/// - `oneMonth` / `threeMonth` / `yearToDate` / `oneYear` → daily bars
/// - `threeYear` / `fiveYear` → down-sampled (≈weekly) bars
///
/// Values like `1d`, `6m`, `10y`, `all`, `max` are *rejected* by the API — it
/// answers HTTP 200 with an empty `prices` array — so they are intentionally omitted.
nonisolated enum ChartTimeframe: String, Sendable, CaseIterable {
    case today = "today"
    case oneWeek = "1w"
    case oneMonth = "1m"
    case threeMonth = "3m"
    case yearToDate = "ytd"
    case oneYear = "1y"
    case threeYear = "3y"
    case fiveYear = "5y"

    /// `true` for windows that return minute-level bars rather than one bar per day.
    var isIntraday: Bool { self == .today || self == .oneWeek }
}

// MARK: - DTOs (`GET charts/{symbol}/daily`)

nonisolated struct ChartResponseDTO: Decodable, Sendable {
    let message: String?
    let data: DataDTO

    nonisolated struct DataDTO: Decodable, Sendable {
        /// JSON number (int for stocks, float for the index) → tolerated as `Double?`.
        let previous: Double?
        let prices: [PointDTO]
    }

    /// Every numeric field arrives as a *string*; `date` is epoch-millis as a string.
    /// `change` / `percentage` / `xlabel` are presentation-only and intentionally not decoded.
    /// `open`/`high`/`low`/`volume` are optional: a line series (e.g. SP500 and other global
    /// indices, which advertise only `PRICE_CHART_TYPE_LINE`) carries the close (`value`) alone.
    nonisolated struct PointDTO: Decodable, Sendable {
        let date: String
        let value: String   // close
        let open: String?
        let high: String?
        let low: String?
        let volume: String?
    }
}

// MARK: - DTO → Domain

nonisolated enum ChartDecodeError: Error, Equatable { case malformedPoint }

extension ChartResponseDTO {
    func toDomain(symbol: String, timeframe: ChartTimeframe) throws -> PriceSeries {
        PriceSeries(
            symbol: symbol,
            timeframe: timeframe,
            previousClose: data.previous,
            candles: try data.prices.map { try $0.toCandle() }
        )
    }
}

private extension ChartResponseDTO.PointDTO {
    func toCandle() throws -> PriceCandle {
        guard let millis = Double(date), let close = Double(value) else {
            throw ChartDecodeError.malformedPoint
        }
        // A line point omits OHLC/volume — anchor the flat candle to the close so a
        // close-driven read (e.g. the regime's 200dma) is correct; volume defaults to 0.
        return PriceCandle(
            date: Date(timeIntervalSince1970: millis / 1000),
            open: open.flatMap(Double.init) ?? close,
            high: high.flatMap(Double.init) ?? close,
            low: low.flatMap(Double.init) ?? close,
            close: close,
            volume: volume.flatMap(Double.init) ?? 0
        )
    }
}
