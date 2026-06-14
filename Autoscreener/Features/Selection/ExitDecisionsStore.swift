import Foundation
import Observation

/// A small in-memory cache of the most-recent Gate-5 exit verdicts, keyed by ticker. It is the seam
/// that lets the paper-trading allocator (`AllocationEngine`) act on the sell-side discipline *without*
/// re-running the holdings review on every rebalance: the `PositionReviewer` fan-out is expensive
/// (per-name re-valuation + a regime read), so its verdicts are cached here and the allocator reads the
/// cheap `byTicker` map.
///
/// `PositionReviewViewModel` is the only writer — it calls `update(_:)` on every successful load. The
/// paper-trading flow reads `byTicker` when it builds a plan. A name absent here (never reviewed, or
/// reviewed before this process started) carries no constraint, so the allocator sizes it on conviction +
/// regime alone — the byte-for-byte pre-Gate-5 behaviour. Mirrors `RecommendationsStore`.
@MainActor
@Observable
final class ExitDecisionsStore {
    /// The latest hold/trim/exit verdicts, keyed by ticker for O(1) lookup at plan time. Only the
    /// `action` is kept — the audit/reason is surfaced on the Positions to Review screen, not here.
    private(set) var byTicker: [Ticker: ExitAction] = [:]

    /// Replace the cache with the latest review (last write wins per ticker). A fresh review fully
    /// supersedes the previous one, so a name that drops out of the review also drops its constraint.
    func update(_ decisions: [ExitDecision]) {
        byTicker = Dictionary(decisions.map { ($0.ticker, $0.action) }, uniquingKeysWith: { first, _ in first })
    }
}
