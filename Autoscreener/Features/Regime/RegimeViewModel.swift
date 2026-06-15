import Foundation
import Observation

/// Thin projection over the shared `MarketDataStore` for the Market Regime banner. It
/// no longer fans out the regime inputs — the `DataSweepCoordinator` gathers them
/// through the shared throttle (`RegimeComposer` does the synthesis) and writes the
/// read here. Mirrors `ScreenerViewModel` / `MarketQuotesViewModel`: the last read
/// renders immediately (incl. from the disk cache on a cold launch), and a live sweep
/// recomputes it while the IDX session is open.
@MainActor
@Observable
final class RegimeViewModel {
    private let store: MarketDataStore
    private let coordinator: DataSweepCoordinator

    init(store: MarketDataStore = AppDependencies.shared.marketDataStore,
         coordinator: DataSweepCoordinator = AppDependencies.shared.dataSweepCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    var read: RegimeRead? { store.regimeRead }

    /// Spinner only before the first read lands; once the store has a read it renders.
    var isLoading: Bool { coordinator.isSweeping && store.regimeRead == nil }

    /// Banner render state. With a read it's `.ready`. Without one it's `.loading` until
    /// a sweep completes; the regime leg only runs while the IDX session is open, so a
    /// completed-but-closed sweep leaves no read → `.empty` (the banner then says the
    /// regime updates while the market is open) rather than spinning forever.
    var loadState: LoadState {
        if read != nil { return .ready }
        return store.lastSweepAt == nil ? .loading : .empty
    }

    /// Ensures the sweep is running (idempotent). A forced call pulls a fresh sweep now.
    func load(force: Bool = false) async {
        if force { await coordinator.refreshNow() } else { coordinator.start() }
    }
}
