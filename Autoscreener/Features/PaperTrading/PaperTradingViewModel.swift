import Foundation
import Observation
import SwiftUI

/// Thin projection that joins the three stores into the paper-trading screen: the
/// portfolio (`PaperTradingStore`), the market regime (`MarketDataStore.regimeRead`)
/// and the watchlist + prices (composed from `ScreenerStore`). It never fetches — the
/// `DataSweepCoordinator` is the single fetch path. `generatePlan()` runs the pure
/// `AllocationEngine`; `execute()` books the confirmed plan into the store.
@MainActor
@Observable
final class PaperTradingViewModel {
    /// The proposed rebalance awaiting confirmation. `nil` until the user generates one.
    private(set) var pendingPlan: AllocationPlan?

    private let store: PaperTradingStore
    private let screenerStore: ScreenerStore
    private let marketStore: MarketDataStore
    private let coordinator: DataSweepCoordinator
    private let recommendationsStore: RecommendationsStore
    private let config: AllocationConfig

    init(store: PaperTradingStore,
         screenerStore: ScreenerStore,
         marketStore: MarketDataStore,
         coordinator: DataSweepCoordinator,
         recommendationsStore: RecommendationsStore = AppDependencies.shared.recommendationsStore,
         config: AllocationConfig = .standard) {
        self.store = store
        self.screenerStore = screenerStore
        self.marketStore = marketStore
        self.coordinator = coordinator
        self.recommendationsStore = recommendationsStore
        self.config = config
    }

    // MARK: - Inputs

    /// Live regime read (the Layer-1 signal). Reading it is observation-tracked.
    var regime: RegimeRead? { marketStore.regimeRead }

    /// Ranked, veto-filtered watchlist composed from the cached screener snapshots.
    var watchlist: [WatchlistRow] { WatchlistComposer.compose(screenerStore.snapshots).rows }

    /// Symbol → last price, gathered from every screener snapshot's rows (first
    /// non-nil positive wins). The only price source the screen has.
    var prices: [String: Double] {
        var out: [String: Double] = [:]
        for snapshot in screenerStore.snapshots.values {
            for row in snapshot.rows where out[row.symbol] == nil {
                if let p = row.lastPrice, p > 0 { out[row.symbol] = p }
            }
        }
        return out
    }

    // MARK: - Portfolio readouts

    var equity: Double { store.state.equity(prices: prices) }
    var cash: Double { store.state.cash }
    var investedValue: Double { store.state.investedValue(prices: prices) }
    var initialCapital: Double { store.state.initialCapital }
    var unrealizedPnL: Double { store.state.unrealizedPnL(prices: prices) }
    var realizedPnL: Double { store.state.realizedPnL }
    var totalReturnPct: Double {
        guard initialCapital > 0 else { return 0 }
        return (equity - initialCapital) / initialCapital
    }
    /// Cash as a fraction of equity — the live counterpart to the plan's exposure.
    var cashWeight: Double { equity > 0 ? cash / equity : 1 }

    var trades: [PaperTrade] { store.state.trades.sorted { $0.date > $1.date } }

    /// One row per open position, valued at the current price.
    var holdings: [HoldingRow] {
        let px = prices
        return store.state.positions.map { symbol, pos in
            let last = px[symbol] ?? pos.avgCost
            let mv = pos.shares * last
            let cost = pos.shares * pos.avgCost
            return HoldingRow(symbol: symbol, shares: pos.shares, avgCost: pos.avgCost,
                              last: last, marketValue: mv, unrealizedPnL: mv - cost,
                              unrealizedPct: cost > 0 ? (mv - cost) / cost : 0)
        }
        .sorted { $0.marketValue > $1.marketValue }
    }

    var hasPositions: Bool { !store.state.positions.isEmpty }

    // MARK: - Status passthrough (the screen shows the same sweep state as Markets)

    var isLoading: Bool { coordinator.isSweeping }
    var lastFetchedAt: Date? { marketStore.lastSweepAt }
    var canPlan: Bool { !watchlist.isEmpty && !prices.isEmpty }

    // MARK: - Actions

    /// Idempotently ensures the shared sweep is running so regime + watchlist fill in.
    func autoRunIfNeeded() async { coordinator.start() }

    /// Recompute the proposed rebalance from the current portfolio, regime and prices.
    func generatePlan() {
        pendingPlan = AllocationEngine.plan(state: store.state, watchlist: watchlist,
                                            regime: regime, prices: prices, config: config)
    }

    /// Book the pending plan into the portfolio, then clear it. Each buy that OPENS a position is
    /// stamped with an `EntryThesis` (Gate-5 Phase 3) reusing the IV/MoS the selection engine already
    /// computed for that name — read cheaply from `recommendationsStore` (no engine re-run). A name
    /// absent from the latest ranked set simply gets no thesis, so it later reviews on current data alone.
    func execute() {
        guard let plan = pendingPlan else { return }
        let now = Date()
        let theses = Dictionary(
            plan.lines.lazy
                .filter { $0.side == .buy }
                .compactMap { line -> (String, EntryThesis)? in
                    guard let rec = self.recommendationsStore.byTicker[line.symbol] else { return nil }
                    return (line.symbol, EntryThesis(recommendation: rec, entryDate: now))
                },
            uniquingKeysWith: { first, _ in first })
        store.apply(plan: plan, theses: theses, config: config, at: now)
        pendingPlan = nil
    }

    /// Reset both the proposed plan and the portfolio back to the 100M seed.
    func reset() {
        store.reset()
        pendingPlan = nil
    }
}

/// A display row for one open position.
nonisolated struct HoldingRow: Identifiable, Hashable, Sendable {
    let symbol: String
    let shares: Double
    let avgCost: Double
    let last: Double
    let marketValue: Double
    let unrealizedPnL: Double
    let unrealizedPct: Double
    var id: String { symbol }
}
