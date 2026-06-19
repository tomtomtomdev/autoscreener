import Foundation

/// Derives an index's market-breadth reading from the `.above200MA` screener snapshot
/// the sweep already collects, instead of fanning out one daily-chart request per
/// constituent (`BreadthService`). That screener returns every IDX name whose price
/// is at or above its 200-day MA, so breadth is just the share of the index's
/// constituents present in that set — zero extra network calls. Used for both the
/// LQ45 leaders and the broader KOMPAS100 (the divergence breadth factor).
///
/// Denominator is the full constituent list passed in: for LQ45 these are the most
/// liquid large-caps and effectively always have 200 days of history, so a fixed count
/// is a more honest base than the variable "names that happened to load" the chart
/// fan-out produced. The same holds, slightly more loosely, for KOMPAS100.
///
/// > ⚠️ Coverage depends on the `.above200MA` snapshot containing every qualifying
/// > constituent. The sweep pages that screener up to its safety cap; the template is
/// > ordered so liquid mega-caps rank near the top and sit well within range, but the
/// > broader KOMPAS100 reaches into smaller names — if the universe above its 200dma
/// > ever exceeds the cap, verify constituents aren't truncated off the tail.
nonisolated enum IndexBreadth {
    /// `nil` when there's no screener snapshot yet (so the regime read drops the
    /// breadth factor and degrades gracefully, rather than reading a false 0%) or when
    /// the constituent list is empty (an index whose membership hasn't loaded).
    static func reading(aboveSnapshot: ScreenerSnapshot?,
                        constituents: [String]) -> BreadthReading? {
        guard let snapshot = aboveSnapshot, !constituents.isEmpty else { return nil }
        let aboveSet = Set(snapshot.rows.map(\.symbol))
        let above = constituents.filter(aboveSet.contains).count
        return BreadthReading(above: above, measured: constituents.count)
    }
}
