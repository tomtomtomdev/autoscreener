import Foundation
import Observation
import SwiftUI

/// Thin projection over the shared `ScreenerStore`: it composes the cached
/// per-screener snapshots into the ranked, veto-filtered composite Watchlist. It no
/// longer fetches — the `ScreenerSweepCoordinator` is the single fetch path, and the
/// store is the single source of truth (read live during open hours, from the disk
/// cache when closed). The compose result is memoised against the store's `version`
/// so it isn't recomputed on every SwiftUI render.
@MainActor
@Observable
final class WatchlistViewModel {
    /// Live stock-code search term (bound to the toolbar search field). Empty = no
    /// filtering. The watchlist isn't paginated, so the filter is always complete.
    var searchText: String = ""

    private let store: ScreenerStore
    private let coordinator: ScreenerSweepCoordinator

    // Memoised composite — recomputed only when the store's write counter changes.
    @ObservationIgnored private var cacheVersion: Int = -1
    @ObservationIgnored private var cachedRows: [WatchlistRow] = []
    @ObservationIgnored private var cachedNotice: String?

    init(store: ScreenerStore, coordinator: ScreenerSweepCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    /// The ranked, veto-filtered composite. Reads `store.version` (observation-tracked)
    /// so SwiftUI refreshes as each screener lands during a sweep.
    var rows: [WatchlistRow] {
        composeIfNeeded()
        return cachedRows
    }

    /// Rows after applying the stock-code search.
    var visibleRows: [WatchlistRow] { rows.filteredBySymbol(searchText) }

    /// Set when a liquidity veto gate couldn't be enforced (its snapshot is missing),
    /// so the status bar can warn that liquidity filtering wasn't fully applied.
    var vetoNotice: String? {
        composeIfNeeded()
        return cachedNotice
    }

    var isLoading: Bool { coordinator.isSweeping }
    var loadedScreenerCount: Int { coordinator.loadedScreenerCount }
    var totalScreenerCount: Int { coordinator.totalScreenerCount }
    var error: String? { coordinator.lastError }
    var paywallMessage: String? { coordinator.paywallMessage }
    /// Wall-clock when the currently-cached composite landed — drives "as of HH:mm".
    var lastFetchedAt: Date? { store.lastSweepAt }

    /// Ensures the sweep pipeline is running (idempotent). The store already holds the
    /// disk cache, so cached rows render immediately while the first live sweep runs.
    func autoRunIfNeeded() async {
        coordinator.start()
    }

    /// User-initiated refresh — force one sweep now, regardless of session.
    func refresh() async {
        await coordinator.refreshNow()
    }

    private func composeIfNeeded() {
        guard store.version != cacheVersion else { return }
        let result = WatchlistComposer.compose(store.snapshots)
        cachedRows = result.rows
        cachedNotice = result.vetoNotice
        cacheVersion = store.version
    }
}
