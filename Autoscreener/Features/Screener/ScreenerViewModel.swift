import Foundation
import Observation
import SwiftUI

/// Thin projection over the shared `ScreenerStore` for a single screener tab. It
/// renders the cached snapshot for its `kind`; it no longer fetches or paginates —
/// the `DataSweepCoordinator` is the single fetch path and each snapshot already
/// holds the screener's full result set. Sorting and stock-code search are applied
/// client-side over the cached rows.
@MainActor
@Observable
final class ScreenerViewModel {
    /// Live stock-code search term (bound on the screeners that opt into search).
    var searchText: String = ""
    /// Header-click sort order. Empty ⇒ fall back to the template's default sort.
    var sort: [KeyPathComparator<ScreenerRow>] = []

    let kind: BandarScreenerKind
    private let store: ScreenerStore
    private let coordinator: DataSweepCoordinator

    init(store: ScreenerStore, coordinator: DataSweepCoordinator, kind: BandarScreenerKind) {
        self.store = store
        self.coordinator = coordinator
        self.kind = kind
    }

    var config: ScreenerConfig { store.snapshot(for: kind)?.config ?? ScreenerConfig() }

    /// Cached rows, ordered for display.
    var rows: [ScreenerRow] { sortedForDisplay(store.snapshot(for: kind)?.rows ?? []) }

    /// Rows after the stock-code search.
    var visibleRows: [ScreenerRow] { rows.filteredBySymbol(searchText) }

    var total: Int? { store.snapshot(for: kind)?.rows.count }
    var lastFetchedAt: Date? { store.snapshot(for: kind)?.fetchedAt }
    var isLoading: Bool { coordinator.isSweeping }
    var error: String? { coordinator.lastError }
    var paywallMessage: String? { coordinator.paywallMessage }

    /// Ensures the sweep pipeline is running (idempotent). Cached rows render
    /// immediately from the store; the live sweep refreshes them.
    func autoRunIfNeeded() async {
        coordinator.start()
    }

    /// User-initiated refresh — force one sweep now, regardless of session.
    func refresh() async {
        await coordinator.refreshNow()
    }

    /// Header sort when set, else the template's `ordercol`/`ordertype` default
    /// (metric column at index `ordercol - 2`, nils sorted last).
    private func sortedForDisplay(_ rows: [ScreenerRow]) -> [ScreenerRow] {
        if !sort.isEmpty { return rows.sorted(using: sort) }
        let ascending = config.orderType.lowercased() == "asc"
        let metricIndex = max(0, config.orderColumn - 2)
        return rows.sorted { a, b in
            ScreenerRow.sortNilLast(a.value(at: metricIndex), b.value(at: metricIndex), ascending: ascending)
        }
    }
}
