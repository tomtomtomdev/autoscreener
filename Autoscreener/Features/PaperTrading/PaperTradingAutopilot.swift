import Foundation
import Observation
import OSLog

private let autopilotLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "paper-autopilot")

/// Runs the paper portfolio hands-free off the buy/sell recommendations. After a full sweep the
/// `DataSweepCoordinator` calls `run(now:)`, which runs two passes with **asymmetric cadences** —
/// defense fast, offense patient (Marks: defense before offense; Zweig: cut losers fast):
///
///   • **Exit pass (`runExits`)** — runs on EVERY warm sweep (5–10 min): re-review the book and
///     liquidate any name Gate-5 flags `.exit` (broken thesis / failed gate / governance / price past
///     IV) immediately. Capital protection can't wait for a boundary.
///   • **Rebalance pass (`runIfDue`)** — buys + regime trims, guarded to **once per IDX session
///     boundary** (open 09:00 / break 12:00 / resume 13:30 / close 16:00, via `MarketClock`) so the
///     sweep cadence can't over-trade; the book deploys/rebalances at the open, after the lunch break,
///     and on the official close rather than once a day.
///
/// Each pass — when `autoExecute` — books off the same `AllocationEngine` + `PaperTradingPlanner` the
/// manual screen uses. The manual Generate → Execute buttons stay available alongside it.
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
    private let clock: MarketClock

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
         calendar: Calendar = .current,
         clock: MarketClock = MarketClock()) {
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
        self.clock = clock
    }

    /// True when the autopilot is due for the current IDX **session boundary** — it runs at most once
    /// per boundary (09:00 open, 12:00 break, 13:30 resume, 16:00 close) rather than once per calendar
    /// day, so the book is re-evaluated at the open, after the lunch break, and on the official close.
    /// Due when no run has happened since the most recent boundary (or never). Falls back to the
    /// calendar-day check only if the clock can't place a boundary (no weekday within range).
    func isDue(now: Date) -> Bool {
        guard let last = store.state.lastAutoRebalanceAt else { return true }
        guard let boundary = clock.mostRecentBoundary(asOf: now) else {
            return !calendar.isDate(last, inSameDayAs: now)
        }
        return last < boundary
    }

    /// The sweep entry point. Defense every warm sweep, offense at session boundaries: always run the
    /// exit pass (liquidate `.exit` names now), then the boundary-gated rebalance (buys + regime trims).
    func run(now: Date) async {
        await runExits(now: now)
        await runIfDue(now: now)
    }

    /// The responsive **defense** pass — runs on every warm sweep, NOT boundary-gated: re-review the
    /// current book and immediately liquidate any name Gate-5 flags `.exit`. Buys and regime trims wait
    /// for `runIfDue`; capital protection does not. No-op when `autoExecute` is off, when the review
    /// fetch fails (retry next sweep), or when nothing is flagged. The boundary guard is deliberately
    /// untouched here — selling a broken thesis must not wait hours for the next boundary.
    func runExits(now: Date) async {
        guard autoExecute else { return }
        guard let review = try? await reviewSource(selectionConfig) else {
            autopilotLog.error("auto-exit skipped — review fetch failed; will retry next sweep")
            return
        }
        exitDecisionsStore.update(review.decisions)
        let plan = AllocationEngine.exitPlan(
            state: store.state, prices: prices, exitDecisions: exitDecisionsStore.byTicker,
            regime: marketStore.regimeRead, names: nameMap, config: config)
        guard plan.hasTrades else { return }
        store.apply(plan: plan, theses: [:], config: config, at: now)   // sells only — no new entry theses
        autopilotLog.info("auto-exit: liquidated \(plan.lines.count) flagged position(s)")
    }

    /// The once-per-boundary auto-rebalance: refresh verdicts (on the CURRENT book) then picks, build the
    /// recommendation-driven plan, and — when `autoExecute` — book it. Records the run timestamp last so
    /// the boundary is only marked done once a full pass succeeds; a failed picks fetch — or a sweep that
    /// produced no priced candidates yet (cache still warming) — leaves it un-stamped to retry on the next
    /// sweep. A no-trade plan with real candidates counts as done (nothing to do this boundary).
    func runIfDue(now: Date) async {
        guard isDue(now: now) else { return }

        // Verdicts first — they review the book as it stands before any trade this pass.
        if let review = try? await reviewSource(selectionConfig) {
            exitDecisionsStore.update(review.decisions)
        }
        // Picks are required to plan; a failed fetch aborts without stamping the boundary (retry next
        // sweep). A `CancellationError` is the benign case — the sweep task was torn down mid-fetch (a
        // newer sweep superseded it, or the app is quitting) — so it's an expected deferral, not a fault.
        // Any OTHER error is logged in full (`String(reflecting:)`) so the actual cause is visible rather
        // than swallowed by a bare `try?` (which is what hid this in the first place).
        let picks: SelectionOutcome
        do {
            picks = try await picksSource(selectionConfig)
        } catch is CancellationError {
            autopilotLog.info("auto-rebalance deferred — picks fetch cancelled (sweep superseded); will retry next sweep")
            return
        } catch {
            autopilotLog.error("auto-rebalance aborted — picks fetch failed: \(String(reflecting: error), privacy: .public); will retry next sweep")
            return
        }
        recommendationsStore.update(picks.recommendations)

        let candidates = PaperTradingPlanner.candidates(
            from: Array(recommendationsStore.byTicker.values), names: nameMap)
        let priceMap = prices
        let plan = AllocationEngine.plan(
            state: store.state, candidates: candidates, regime: marketStore.regimeRead,
            prices: priceMap, exitDecisions: exitDecisionsStore.byTicker, config: config)

        if autoExecute, plan.hasTrades {
            let theses = PaperTradingPlanner.theses(
                for: plan, recommendations: recommendationsStore.byTicker, at: now)
            store.apply(plan: plan, theses: theses, config: config, at: now)
            autopilotLog.info("auto-rebalanced: booked \(plan.lines.count) order(s)")
        } else if autoExecute, !candidates.contains(where: { (priceMap[$0.symbol] ?? 0) > 0 || ($0.referencePrice ?? 0) > 0 }) {
            // No *priced* recommendations yet — the per-symbol selection cache or the screener price cache
            // is still warming on this sweep. This covers both a fully empty candidate set AND the partial
            // warm where a few names rank but none can be valued: in either case the empty plan is a DATA
            // gap, not a "nothing to do" verdict, so booking nothing here is not a real decision. Treat it
            // like a failed fetch — don't consume this boundary's slot, just return so the next (warm)
            // sweep retries. Without this a cold/partial first sweep of the boundary strands the book in
            // cash until the *next* boundary (the "stuck in cash" regression).
            autopilotLog.info("auto-rebalance: no priced candidates yet (cache warming) — deferring to next sweep")
            return
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
