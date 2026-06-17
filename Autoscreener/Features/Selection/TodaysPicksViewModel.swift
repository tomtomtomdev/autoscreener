import Foundation
import Observation

/// Drives the "Today's Picks" screen — the user-facing surface over the Tier-A selection engine
/// (§8). It loads the ranked, audited `Recommendation`s from an injected async source (the headless
/// `SelectionRunner`, wired by `AppDependencies.todaysPicks`) and exposes the loading / loaded /
/// empty / error states the view renders.
///
/// The engine fan-out, throttling, and scoring all live below the source closure (`StockbitDataProvider`
/// + `StockSelectionEngine`); this type only owns presentation. An empty result is a *successful*
/// "no picks today" state (e.g. a risk-off regime caps exposure, or nothing clears the gates), not an
/// error. A failed load is left uncached so the next appearance retries (mirrors `RegimeViewModel`).
@MainActor
@Observable
final class TodaysPicksViewModel {
    private(set) var picks: [Recommendation] = []
    /// Names the engine could not value (missing fundamentals / no price) and skipped this run — a
    /// non-blocking signal the Recommendations screen surfaces as an "N skipped" note, distinct from
    /// `error` (a skipped name is a successful, partial load, not a failure).
    private(set) var skipped: [SkippedName] = []
    var isLoading = false
    var error: String?

    /// True once a load has *succeeded* (even with zero picks). Lets the view distinguish "loaded,
    /// nothing qualified" (the empty state) from "haven't loaded yet" (the initial spinner). A
    /// failed load leaves it false, so the next appearance retries.
    private(set) var hasLoaded = false

    /// True when the selection cache is still cold (the sweep hasn't warmed it yet): the screen shows a
    /// "waiting for the sweep" note instead of "no picks". Left un-`hasLoaded` so a re-appearance retries
    /// once the sweep fills the cache.
    private(set) var awaitingData = false

    /// Non-nil only while the market is CLOSED — the cache's last-warmed time. The picks are ranked from
    /// that last-known close, so the screen labels them "as of <date> · market closed" rather than
    /// implying live figures. nil while open.
    private(set) var asOf: Date?

    let config: SelectionConfig
    private let source: (SelectionConfig) async throws -> SelectionOutcome
    /// Where the ranked picks are cached so the paper-trading flow can snapshot an `EntryThesis` cheaply
    /// on a fill (Gate-5 Phase 3). This VM is the only writer; it refreshes the cache on each load.
    private let recommendationsStore: RecommendationsStore

    init(config: SelectionConfig = .balanced,
         source: @escaping (SelectionConfig) async throws -> SelectionOutcome
            = { try await AppDependencies.shared.todaysPicks(config: $0) },
         recommendationsStore: RecommendationsStore = AppDependencies.shared.recommendationsStore) {
        self.config = config
        self.source = source
        self.recommendationsStore = recommendationsStore
    }

    func load(force: Bool = false) async {
        if !force, hasLoaded { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let outcome = try await source(config)
            picks = outcome.recommendations
            skipped = outcome.skipped
            awaitingData = outcome.awaitingData
            asOf = outcome.asOf
            recommendationsStore.update(picks)   // feed the Gate-5 entry-thesis cache (Phase 3)
            hasLoaded = !outcome.awaitingData     // cold cache isn't "loaded" — retry on next appearance
        } catch {
            self.error = error.localizedDescription
        }
    }
}
