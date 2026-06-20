import Foundation

/// One regime input assembled from the sweep's already-priced market quotes: Indonesia's
/// commodity **export** terms of trade — the "China channel". China is the dominant buyer of
/// Indonesia's coal, palm oil and nickel, so the daily move in that export basket is the
/// cleanest on-device proxy for external (China) demand pressure on IDX earnings, the current
/// account and the rupiah. CNY/IDR rides along as corroborating context.
///
/// Oil is deliberately **excluded** from the basket: Indonesia is a net oil importer, so a
/// higher oil price is an import-cost / current-account *drag* — wrong-signed as a terms-of-trade
/// input. Only the export legs (coal/CPO/nickel) carry the signal.
nonisolated struct CommodityChannelReading: Sendable, Equatable {
    /// Mean daily % change across the export-basket commodities that priced this sweep
    /// (e.g. `+1.8` for +1.8%). The factor's vote is the sign of this, dead-banded.
    let basketChangePercent: Double
    /// Display names of the commodities that actually contributed, in basket order
    /// (e.g. `["coal", "CPO"]` when only those two priced) — so the detail never overstates.
    let contributors: [String]
    /// CNY/IDR daily % change when priced; `nil` otherwise. **Context only, never a vote**: the
    /// yuan-vs-rupiah cross conflates yuan strength with rupiah-specific weakness, so scoring it
    /// would risk a wrong-signed leg. Surfaced in the detail to corroborate the basket read.
    let cnyChangePercent: Double?
}

/// Builds a [`CommodityChannelReading`] from the market-quote cache, mirroring how `IndexBreadth`
/// derives the breadth reading from the screener snapshot — pure and I/O-free so the basket
/// selection (incl. the oil exclusion) and CNY context are unit-testable without a network.
nonisolated enum CommodityChannel {
    /// The export basket in detail order: `(quote symbol, display label)`. Oil is absent on
    /// purpose (see `CommodityChannelReading`).
    static let basket: [(symbol: String, label: String)] = [
        ("COAL-NEWCASTLE", "coal"),
        ("CPO", "CPO"),
        ("NICKEL", "nickel"),
    ]
    static let cnySymbol = "CNYIDR"

    /// Assembles the reading from the sweep's quotes. Averages the basket commodities that priced
    /// with a non-nil `changePercent`, and picks up CNY/IDR as context. Returns `nil` when no
    /// basket commodity priced this sweep — the factor then drops, exactly like any other absent
    /// regime leg (CNY alone is not enough: the vote needs the basket).
    static func reading(quotes: [String: CommodityQuote]) -> CommodityChannelReading? {
        var changes: [Double] = []
        var contributors: [String] = []
        for item in basket {
            if let change = quotes[item.symbol]?.changePercent {
                changes.append(change)
                contributors.append(item.label)
            }
        }
        guard !changes.isEmpty else { return nil }
        let mean = changes.reduce(0, +) / Double(changes.count)
        return CommodityChannelReading(
            basketChangePercent: mean,
            contributors: contributors,
            cnyChangePercent: quotes[cnySymbol]?.changePercent)
    }
}
