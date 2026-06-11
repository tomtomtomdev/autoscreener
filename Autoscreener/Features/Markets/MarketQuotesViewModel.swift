import Foundation
import Observation

/// Thin projection over the shared `MarketDataStore` for the Markets price list. It no
/// longer fetches — the `DataSweepCoordinator` is the single fetch path that prices
/// every Markets row (composite, indices, sectors, commodities, currencies) through
/// the shared throttle and writes them here. Mirrors `ScreenerViewModel`: the cached
/// quotes render immediately (incl. from the disk cache on a cold launch), and a live
/// sweep refreshes them.
@MainActor
@Observable
final class MarketQuotesViewModel {
    private let store: MarketDataStore
    private let coordinator: DataSweepCoordinator

    init(store: MarketDataStore = AppDependencies.shared.marketDataStore,
         coordinator: DataSweepCoordinator = AppDependencies.shared.dataSweepCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    /// Latest price snapshot per symbol, keyed by ticker.
    var quotes: [String: CommodityQuote] { store.quotes }

    /// Spinner only before the first quotes land; once the store has data the rows render.
    var isLoading: Bool { coordinator.isSweeping && store.quotes.isEmpty }

    /// Ensures the sweep is running (idempotent). A forced call pulls a fresh sweep now.
    func load(force: Bool = false) async {
        if force { await coordinator.refreshNow() } else { coordinator.start() }
    }
}
