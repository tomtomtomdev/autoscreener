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
    var isLoading = false
    var error: String?

    /// True once a load has *succeeded* (even with zero picks). Lets the view distinguish "loaded,
    /// nothing qualified" (the empty state) from "haven't loaded yet" (the initial spinner). A
    /// failed load leaves it false, so the next appearance retries.
    private(set) var hasLoaded = false

    let config: SelectionConfig
    private let source: (SelectionConfig) async throws -> [Recommendation]
    /// Where the ranked picks are cached so the paper-trading flow can snapshot an `EntryThesis` cheaply
    /// on a fill (Gate-5 Phase 3). This VM is the only writer; it refreshes the cache on each load.
    private let recommendationsStore: RecommendationsStore

    init(config: SelectionConfig = .balanced,
         source: @escaping (SelectionConfig) async throws -> [Recommendation]
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
            picks = try await source(config)
            recommendationsStore.update(picks)   // feed the Gate-5 entry-thesis cache (Phase 3)
            hasLoaded = true            // an empty result is still a successful load
        } catch {
            self.error = error.localizedDescription
        }
    }
}
