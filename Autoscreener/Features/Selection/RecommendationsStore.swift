import Foundation
import Observation

/// A small in-memory cache of the most-recent ranked `Recommendation`s, keyed by ticker. It is the
/// cheap seam Gate-5 Phase 3 uses to capture an `EntryThesis` on a paper buy *without* re-running the
/// engine: the buy universe is the same composite Watchlist the selection engine ranks, so the IV /
/// margin-of-safety the engine already computed for a name are reused verbatim (zero extra fetch).
///
/// `TodaysPicksViewModel` is the only writer — it calls `update(_:)` on every successful load. The
/// paper-trading flow reads `byTicker` at fill time. A name absent here (never ranked, or ranked before
/// this process started) simply yields no thesis, and Gate-5 reviews it on current data alone (Phase-1).
@MainActor
@Observable
final class RecommendationsStore {
    /// The latest ranked recommendations, keyed by ticker for O(1) fill-time lookup.
    private(set) var byTicker: [Ticker: Recommendation] = [:]

    /// Replace the cache with the latest ranked set (last write wins per ticker). A fresh load fully
    /// supersedes the previous one, so a name that drops out of the ranking also drops out of the cache.
    func update(_ recommendations: [Recommendation]) {
        byTicker = Dictionary(recommendations.map { ($0.ticker, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
