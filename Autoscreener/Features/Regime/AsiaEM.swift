import Foundation

/// One regime input assembled from the Asia-EM equity tape: the regional risk-appetite leg,
/// a live stand-in for the EEM "EM-vs-developed-markets" read the IDX trades inside. Indonesia
/// is bought and sold as part of the Asia-EM complex, so when that complex is leading the
/// developed-market tape it signals genuine appetite for the EM periphery (where IDX foreign
/// flow originates); when it lags a rising DM tape, that's a developed-market-only advance that
/// isn't reaching IDX.
///
/// **The vote is the *relative* read — Asia-EM's 200-day-MA position minus the S&P 500's** — not
/// the absolute regional trend. That's deliberate: the US 10y, broad dollar and S&P legs already
/// vote on the one global financial cycle, and an absolute Asia-EM equity trend would mostly echo
/// them (Asia opens to the overnight US tape), over-counting that cycle. The EM-vs-DM *spread* is
/// the non-redundant datum — it isolates regional appetite from global beta. When the S&P leg is
/// unavailable the factor falls back to voting on the absolute regional trend.
///
/// Japan (NIKKEI) is deliberately **excluded** from the basket: it's a developed market, so it
/// belongs to the DM side of the comparison, not the EM-appetite read this leg measures.
nonisolated struct AsiaEMReading: Sendable, Equatable {
    /// Mean fractional distance of the basket members from their own 200-day average
    /// (e.g. `+0.05` for +5% above), across the members that had enough history. The absolute
    /// regional risk-cycle position — surfaced in the detail, and the vote's fallback.
    let regionalDistance: Double
    /// Display names of the basket members that actually contributed (had a computable 200dma),
    /// in basket order (e.g. `["Hang Seng", "KOSPI"]`) — so the detail never overstates coverage.
    let contributors: [String]
    /// `regionalDistance − the S&P 500's own 200dma distance`, when the DM benchmark is available.
    /// **This is the vote**: positive = Asia-EM leading the developed-market tape = genuine EM risk
    /// appetite (the non-redundant datum); negative = lagging = a DM-only advance not reaching the
    /// EM periphery. `nil` when the S&P leg is unavailable → the factor votes on `regionalDistance`.
    let relativeToSP: Double?

    /// The figure the factor's vote is classified on: the EM-vs-DM spread when the benchmark is
    /// present, otherwise the absolute regional trend.
    var voteStrength: Double { relativeToSP ?? regionalDistance }
}

/// Builds an [`AsiaEMReading`] from the basket's price series, mirroring how `IndexBreadth` and
/// `CommodityChannel` derive their readings — pure and I/O-free so the basket selection (incl. the
/// Japan exclusion) and the EM-vs-DM relative read are unit-testable without a network.
nonisolated enum AsiaEM {
    /// The Asia-EM equity basket in detail order: `(chart symbol, display label)`. Japan is absent
    /// on purpose (see `AsiaEMReading`). These are the liquid Asia-EM index proxies for EEM.
    static let basket: [(symbol: String, label: String)] = [
        ("HANGSENG", "Hang Seng"),
        ("SHANGHAI", "Shanghai"),
        ("KOSPI", "KOSPI"),
    ]

    /// Assembles the reading from the basket's 1-year series. Averages the 200-day-MA distance of
    /// the members that priced with enough history, and (when the S&P 500's own 200dma distance is
    /// supplied) computes the EM-vs-DM spread that drives the vote. Returns `nil` when no basket
    /// member had a computable 200dma this sweep — the factor then drops, like any absent leg.
    static func reading(series: [String: PriceSeries], sp500Distance: Double?) -> AsiaEMReading? {
        var distances: [Double] = []
        var contributors: [String] = []
        for item in basket {
            if let s = series[item.symbol],
               let distance = MovingAverage.distanceFromSMA(s, period: 200) {
                distances.append(distance)
                contributors.append(item.label)
            }
        }
        guard !distances.isEmpty else { return nil }
        let regional = distances.reduce(0, +) / Double(distances.count)
        return AsiaEMReading(
            regionalDistance: regional,
            contributors: contributors,
            relativeToSP: sp500Distance.map { regional - $0 })
    }
}
