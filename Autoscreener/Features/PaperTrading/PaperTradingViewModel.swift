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
    private let exitDecisionsStore: ExitDecisionsStore
    private let config: AllocationConfig
    /// The Tier-A config the warming load runs under (mirrors `TodaysPicksViewModel.config`).
    private let selectionConfig: SelectionConfig
    /// The buy-picks source the manual plan warms from when the recommendation cache is cold — the same
    /// headless engine the Recommendations screen uses. Injected so the screen's wiring is unit-testable
    /// offline (the default hits the shared engine; tests pass a fake).
    private let picksSource: (SelectionConfig) async throws -> SelectionOutcome
    /// The sell-verdict source, paired with `picksSource` and warmed together.
    private let reviewSource: (SelectionConfig) async throws -> ReviewOutcome

    init(store: PaperTradingStore,
         screenerStore: ScreenerStore,
         marketStore: MarketDataStore,
         coordinator: DataSweepCoordinator,
         recommendationsStore: RecommendationsStore = AppDependencies.shared.recommendationsStore,
         exitDecisionsStore: ExitDecisionsStore = AppDependencies.shared.exitDecisionsStore,
         config: AllocationConfig = .standard,
         selectionConfig: SelectionConfig = .balanced,
         picksSource: @escaping (SelectionConfig) async throws -> SelectionOutcome
            = { try await AppDependencies.shared.todaysPicks(config: $0) },
         reviewSource: @escaping (SelectionConfig) async throws -> ReviewOutcome
            = { try await AppDependencies.shared.reviewPositions(config: $0) }) {
        self.store = store
        self.screenerStore = screenerStore
        self.marketStore = marketStore
        self.coordinator = coordinator
        self.recommendationsStore = recommendationsStore
        self.exitDecisionsStore = exitDecisionsStore
        self.config = config
        self.selectionConfig = selectionConfig
        self.picksSource = picksSource
        self.reviewSource = reviewSource
    }

    // MARK: - Inputs

    /// Live regime read (the Layer-1 signal). Reading it is observation-tracked.
    var regime: RegimeRead? { marketStore.regimeRead }

    /// True when this book ignores the regime exposure band (the RiBeTS book) — drives the screen's
    /// badge so a regime-blind book doesn't advertise a regime stance it doesn't act on.
    var isRegimeBlind: Bool { config.fixedExposure != nil }

    /// The fraction of equity this book targets deploying: the fixed full-deployment for the regime-blind
    /// book, otherwise the regime-aware exposure for the current score. The badge reads this (instead of
    /// hardcoding `.standard`) so it stays truthful for both RAPaTS and RiBeTS.
    var targetExposure: Double { config.fixedExposure ?? config.exposure(forScore: regime?.score ?? 0) }

    /// Ranked, veto-filtered watchlist composed from the cached screener snapshots. Still the source of
    /// display names + prices for the plan, but no longer the buy universe (that's the recommendations).
    var watchlist: [WatchlistRow] { WatchlistComposer.compose(screenerStore.snapshots).rows }

    /// Symbol → display name, from the composite watchlist, used to label the recommendation candidates.
    private var nameMap: [String: String] {
        Dictionary(watchlist.map { ($0.symbol, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// The latest ranked recommendations (the buy universe), newest cache wins. Empty until a load —
    /// `generatePlan()` warms it on demand.
    var rankedRecommendations: [Recommendation] { Array(recommendationsStore.byTicker.values) }

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

    /// When the autopilot last auto-rebalanced this book (once per trading day). `nil` until the first
    /// auto-run — surfaced so the autonomous trading is visible; the trade log is the full audit trail.
    var lastAutoRebalanceAt: Date? { store.state.lastAutoRebalanceAt }

    // MARK: - Status passthrough (the screen shows the same sweep state as Markets)

    var isLoading: Bool { coordinator.isSweeping }
    var lastFetchedAt: Date? { marketStore.lastSweepAt }
    var canPlan: Bool { !watchlist.isEmpty && !prices.isEmpty }

    // MARK: - Actions

    /// Idempotently ensures the shared sweep is running so regime + watchlist fill in.
    func autoRunIfNeeded() async { coordinator.start() }

    /// Recompute the proposed rebalance from the current portfolio, regime, prices and the buy/sell
    /// recommendations. The buy universe is the ranked Tier-A picks (`recommendationsStore`), sized by
    /// each name's `suggestedWeight`; the Gate-5 exit verdicts (`exitDecisionsStore`) are overlaid so a
    /// flagged name is forced out / barred from re-entry. If the recommendation cache is cold (the user
    /// hasn't opened the Recommendations screen and the autopilot hasn't run), it's warmed once from the
    /// same headless engine before planning — a warm cache plans without any fetch.
    ///
    /// Drives the screen's READ-ONLY preview now (the view auto-calls it on appear + each sweep); the
    /// autopilot does the actual once-per-day booking. The mirror of the autopilot's own plan build.
    func generatePlan() async {
        await refreshRecommendationsIfNeeded()
        pendingPlan = AllocationEngine.plan(
            state: store.state,
            candidates: PaperTradingPlanner.candidates(from: rankedRecommendations, names: nameMap),
            regime: regime, prices: prices,
            exitDecisions: exitDecisionsStore.byTicker, config: config)
    }

    /// Warms the buy/sell recommendation caches once when both are cold, reusing the same sources the
    /// Recommendations screen uses (and the autopilot). A failed load leaves the caches empty so the
    /// next attempt retries — never blocks the plan (a cold cache just yields an empty buy universe).
    private func refreshRecommendationsIfNeeded() async {
        guard recommendationsStore.byTicker.isEmpty else { return }
        if let outcome = try? await picksSource(selectionConfig) {
            recommendationsStore.update(outcome.recommendations)
        }
        if let review = try? await reviewSource(selectionConfig) {
            exitDecisionsStore.update(review.decisions)
        }
    }

    /// Book the pending plan into the portfolio, then clear it. Each buy that OPENS a position is
    /// stamped with an `EntryThesis` (Gate-5 Phase 3) reusing the IV/MoS the selection engine already
    /// computed for that name — read cheaply from `recommendationsStore` (no engine re-run). A name
    /// absent from the latest ranked set simply gets no thesis, so it later reviews on current data alone.
    ///
    /// No longer surfaced in the (hands-free) UI — the autopilot books via the same `store.apply` path.
    /// Retained as the manual booking primitive that the allocation/Gate-5 tests drive directly.
    func execute() {
        guard let plan = pendingPlan else { return }
        let now = Date()
        let theses = PaperTradingPlanner.theses(
            for: plan, recommendations: recommendationsStore.byTicker, at: now)
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
