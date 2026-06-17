import Foundation
import Observation

/// Drives the "Positions to Review" screen — the user-facing surface over the Gate-5 exit discipline
/// (`PositionReviewer`). It loads hold/trim/exit verdicts (each with the same audited reasoning style as
/// a buy `Recommendation`) from an injected async source (the live reviewer, wired by
/// `AppDependencies.reviewPositions`) and exposes the loading / loaded / empty / error states.
///
/// The holdings fan-out, regime read, and per-name re-valuation all live below the source closure
/// (`PositionReviewer` + `StockbitDataProvider`); this type only owns presentation. An empty result is a
/// *successful* "nothing to review" state (no open positions, or everything holds), not an error. A
/// failed load is left uncached so the next appearance retries (mirrors `TodaysPicksViewModel`).
@MainActor
@Observable
final class PositionReviewViewModel {
    private(set) var decisions: [ExitDecision] = []
    /// Held names the reviewer could not re-value (missing fundamentals / no price) and skipped this
    /// run — surfaced (with the buy-side skips) as the Recommendations screen's "N skipped" note.
    private(set) var skipped: [SkippedName] = []
    var isLoading = false
    var error: String?

    /// True once a load has *succeeded* (even with zero decisions). Lets the view distinguish "reviewed,
    /// nothing to do" (the empty state) from "haven't loaded yet". A failed load leaves it false.
    private(set) var hasLoaded = false

    /// True when the selection cache is still cold for the held names (sweep hasn't warmed it). Mirrors
    /// `TodaysPicksViewModel.awaitingData`; left un-`hasLoaded` so a re-appearance retries.
    private(set) var awaitingData = false

    let config: SelectionConfig
    private let source: (SelectionConfig) async throws -> ReviewOutcome
    /// Where the verdicts are cached so the paper-trading allocator can act on them without re-running
    /// this (expensive) review on every rebalance. This VM is the only writer; it refreshes on each load.
    private let exitDecisionsStore: ExitDecisionsStore

    init(config: SelectionConfig = .balanced,
         source: @escaping (SelectionConfig) async throws -> ReviewOutcome
            = { try await AppDependencies.shared.reviewPositions(config: $0) },
         exitDecisionsStore: ExitDecisionsStore = AppDependencies.shared.exitDecisionsStore) {
        self.config = config
        self.source = source
        self.exitDecisionsStore = exitDecisionsStore
    }

    /// The names flagged to act on (exit or trim), surfaced first; holds are the rest.
    var actionable: [ExitDecision] { decisions.filter { $0.action != .hold } }

    func load(force: Bool = false) async {
        if !force, hasLoaded { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let outcome = try await source(config)
            decisions = outcome.decisions
            skipped = outcome.skipped
            awaitingData = outcome.awaitingData
            exitDecisionsStore.update(decisions)   // feed the allocator's Gate-5 cache
            hasLoaded = !outcome.awaitingData       // cold cache isn't "reviewed" — retry on next appearance
        } catch {
            self.error = error.localizedDescription
        }
    }
}
