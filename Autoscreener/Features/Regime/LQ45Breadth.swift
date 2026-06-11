import Foundation

/// Derives the LQ45 market-breadth reading from the `.above200MA` screener snapshot
/// the sweep already collects, instead of fanning out one daily-chart request per
/// constituent (`BreadthService`). That screener returns every IDX name whose price
/// is at or above its 200-day MA, so breadth is just the share of LQ45 constituents
/// present in that set — zero extra network calls.
///
/// Denominator is the full committed LQ45 list: these are the most liquid large-caps
/// on the exchange and effectively always have 200 days of history, so a fixed 45 is
/// a more honest base than the variable "names that happened to load" the chart
/// fan-out produced.
///
/// > ⚠️ Coverage depends on the `.above200MA` snapshot containing every qualifying
/// > LQ45 name. The sweep pages that screener up to its safety cap; the template is
/// > ordered so liquid mega-caps rank near the top and sit well within range, but if
/// > the universe above its 200dma ever exceeds the cap, verify LQ45 names aren't
/// > truncated off the tail.
nonisolated enum LQ45Breadth {
    /// `nil` when there's no screener snapshot yet (so the regime read drops the
    /// breadth factor and degrades gracefully, rather than reading a false 0%).
    static func reading(aboveSnapshot: ScreenerSnapshot?,
                        constituents: [String] = LQ45Constituents.symbols) -> BreadthReading? {
        guard let snapshot = aboveSnapshot, !constituents.isEmpty else { return nil }
        let aboveSet = Set(snapshot.rows.map(\.symbol))
        let above = constituents.filter(aboveSet.contains).count
        return BreadthReading(above: above, measured: constituents.count)
    }
}
