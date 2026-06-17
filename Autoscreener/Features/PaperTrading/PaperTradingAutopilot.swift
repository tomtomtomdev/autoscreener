import Foundation
import Observation
import OSLog

private let autopilotLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "paper-autopilot")

/// Runs the paper portfolio hands-free off the buy/sell recommendations. After a full sweep the
/// `DataSweepCoordinator` calls `runIfDue(now:)`; guarded to **once per trading day** so the 5–10 min
/// sweep cadence can't over-trade, it refreshes the picks + exit verdicts, builds the same
/// recommendation-driven plan the manual screen does (`AllocationEngine` + `PaperTradingPlanner`), and
/// — when `autoExecute` — books it. The manual Generate → Execute buttons stay available alongside it.
///
/// Sources are injected (the same headless engine the Recommendations screen uses) so the autopilot is
/// unit-testable offline. It writes the shared recommendation/exit caches too, so a run also freshens
/// the Recommendations screen.
@MainActor
@Observable
final class PaperTradingAutopilot {
    /// Whether a due run books the plan (vs. only refreshing the caches). Default on — the point is
    /// hands-free trading; a once-per-day guard bounds it.
    var autoExecute: Bool

    private let store: PaperTradingStore
    private let screenerStore: ScreenerStore
    private let marketStore: MarketDataStore
    private let recommendationsStore: RecommendationsStore
    private let exitDecisionsStore: ExitDecisionsStore
    private let picksSource: (SelectionConfig) async throws -> SelectionOutcome
    private let reviewSource: (SelectionConfig) async throws -> ReviewOutcome
    private let config: AllocationConfig
    private let selectionConfig: SelectionConfig
    private let calendar: Calendar

    init(store: PaperTradingStore,
         screenerStore: ScreenerStore,
         marketStore: MarketDataStore,
         recommendationsStore: RecommendationsStore = AppDependencies.shared.recommendationsStore,
         exitDecisionsStore: ExitDecisionsStore = AppDependencies.shared.exitDecisionsStore,
         picksSource: @escaping (SelectionConfig) async throws -> SelectionOutcome
            = { try await AppDependencies.shared.todaysPicks(config: $0) },
         reviewSource: @escaping (SelectionConfig) async throws -> ReviewOutcome
            = { try await AppDependencies.shared.reviewPositions(config: $0) },
         config: AllocationConfig = .standard,
         selectionConfig: SelectionConfig = .balanced,
         autoExecute: Bool = true,
         calendar: Calendar = .current) {
        self.store = store
        self.screenerStore = screenerStore
        self.marketStore = marketStore
        self.recommendationsStore = recommendationsStore
        self.exitDecisionsStore = exitDecisionsStore
        self.picksSource = picksSource
        self.reviewSource = reviewSource
        self.config = config
        self.selectionConfig = selectionConfig
        self.autoExecute = autoExecute
        self.calendar = calendar
    }

    /// True when no auto-rebalance has run yet today (different calendar day from the last, or never).
    func isDue(now: Date) -> Bool {
        guard let last = store.state.lastAutoRebalanceAt else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// The once-per-day auto-rebalance: refresh verdicts (on the CURRENT book) then picks, build the
    /// recommendation-driven plan, and — when `autoExecute` — book it. Records the run timestamp last so
    /// the day is only marked done once a full pass succeeds; a failed picks fetch leaves it un-stamped
    /// to retry on the next sweep. A no-trade plan still counts as done (nothing to do today).
    func runIfDue(now: Date) async {
        guard isDue(now: now) else { return }

        // Verdicts first — they review the book as it stands before any trade this pass.
        if let review = try? await reviewSource(selectionConfig) {
            exitDecisionsStore.update(review.decisions)
        }
        // Picks are required to plan; a failed fetch aborts without stamping the day (retry next sweep).
        guard let picks = try? await picksSource(selectionConfig) else {
            autopilotLog.error("auto-rebalance aborted — picks fetch failed; will retry next sweep")
            return
        }
        recommendationsStore.update(picks.recommendations)

        let candidates = PaperTradingPlanner.candidates(
            from: Array(recommendationsStore.byTicker.values), names: nameMap)
        let plan = AllocationEngine.plan(
            state: store.state, candidates: candidates, regime: marketStore.regimeRead,
            prices: prices, exitDecisions: exitDecisionsStore.byTicker, config: config)

        if autoExecute, plan.hasTrades {
            let theses = PaperTradingPlanner.theses(
                for: plan, recommendations: recommendationsStore.byTicker, at: now)
            store.apply(plan: plan, theses: theses, config: config, at: now)
            autopilotLog.info("auto-rebalanced: booked \(plan.lines.count) order(s)")
        } else {
            autopilotLog.info("auto-rebalance: no trades (autoExecute=\(self.autoExecute), trades=\(plan.hasTrades))")
        }
        store.recordAutoRebalance(at: now)
    }

    // MARK: - Inputs (mirror PaperTradingViewModel's read-only projections)

    /// Symbol → last price from every cached screener snapshot (first non-nil positive wins).
    private var prices: [String: Double] {
        var out: [String: Double] = [:]
        for snapshot in screenerStore.snapshots.values {
            for row in snapshot.rows where out[row.symbol] == nil {
                if let p = row.lastPrice, p > 0 { out[row.symbol] = p }
            }
        }
        return out
    }

    /// Symbol → display name from the composite watchlist, to label the recommendation candidates.
    private var nameMap: [String: String] {
        Dictionary(WatchlistComposer.compose(screenerStore.snapshots).rows.map { ($0.symbol, $0.name) },
                   uniquingKeysWith: { first, _ in first })
    }
}
