import Foundation

// Integration glue between the app's networking domain and the vendored StockSelectionEngine.
// Lives in the Selection feature (not in the price-feed service) so the service stays free of any
// engine type dependency — the engine integration depends on the service's domain, never the reverse.
//
// Phase 0.2 (§8): HistoricalSummaryBar → engine OHLCV. The historical-summary feed returns bars
// newest-first; the engine expects ascending (oldest→newest), so the sequence adapters sort
// defensively. The same bar also yields the per-day foreign-flow series the engine consumes (§1.6).

extension HistoricalSummaryBar {
    /// This bar as the engine's input type. `value` carries the true traded rupiah (ADV input).
    var ohlcv: OHLCV {
        OHLCV(date: date, open: open, high: high, low: low, close: close, volume: volume, value: value)
    }
}

extension Sequence where Element == HistoricalSummaryBar {
    /// Engine-ready OHLCV bars, ascending by date (oldest→newest).
    var ohlcvSeries: [OHLCV] {
        sorted { $0.date < $1.date }.map(\.ohlcv)
    }
    /// Per-day net foreign flow, ascending by date — the engine's `foreignNetFlow` window input (§1.6).
    var foreignNetFlowSeries: [Rupiah] {
        sorted { $0.date < $1.date }.map(\.netForeign)
    }
}
