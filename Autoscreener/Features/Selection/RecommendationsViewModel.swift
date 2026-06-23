import Foundation
import Observation

/// One actionable row in the unified Recommendations inbox. It WRAPS — without flattening — the two
/// engine outputs the screen merges: a buy-side `Recommendation` and a sell-side `ExitDecision`. Each
/// case keeps its full domain value so the row renders with the metric block native to its kind, while a
/// single `priority` collapses both into one order (buy → hold → trim → exit).
enum ActionRow: Identifiable {
    case buy(Recommendation)        // a ranked buy candidate from Today's Picks
    case verdict(ExitDecision)      // a hold / trim / exit verdict from the Gate-5 review

    var ticker: Ticker {
        switch self {
        case .buy(let r):     return r.ticker
        case .verdict(let d): return d.ticker
        }
    }

    /// The full audited reasoning, surfaced behind the row's "Why" disclosure.
    var audit: [String] {
        switch self {
        case .buy(let r):     return r.audit
        case .verdict(let d): return d.audit
        }
    }

    /// Rank for the single ranked list — lower sorts first. Fresh buys lead, then the held-position
    /// verdicts in escalating order: hold, trim, exit.
    var priority: Int {
        switch self {
        case .buy: return 0
        case .verdict(let d):
            switch d.action {
            case .hold: return 1
            case .trim: return 2
            case .exit: return 3
            }
        }
    }

    /// Everything except a plain HOLD asks the reader to do something (open a position, trim, or sell).
    var isActionable: Bool {
        switch self {
        case .buy:            return true
        case .verdict(let d): return d.action != .hold
        }
    }

    var id: Ticker { ticker }
}

/// Drives the unified "Recommendations" screen — one ranked inbox that merges the buy-side picks
/// (`TodaysPicksViewModel`) and the Gate-5 sell-side verdicts (`PositionReviewViewModel`) into a single
/// list answering *"what should I do today?"*.
///
/// It OWNS the two existing view models rather than reimplementing them: each child still loads from its
/// own source and still feeds its own store (`RecommendationsStore` / `ExitDecisionsStore`, which the
/// paper-trading allocator reads), so the data path below this screen is unchanged. This type only
/// composes their outputs for display — no business logic, no extra fetch. Because the children are
/// `@Observable`, reading their published outputs inside the computed `rows` lets SwiftUI re-render
/// whenever either side reloads.
@MainActor
@Observable
final class RecommendationsViewModel {
    let picks: TodaysPicksViewModel
    let positions: PositionReviewViewModel

    /// Persisted display cache of the last successful inbox. Read once on init to seed the cold-start
    /// fallback below, and written after each fully successful load. This VM is its only reader/writer.
    private let snapshotStore: RecommendationsSnapshotStore
    /// The last displayed inbox, restored from `snapshotStore` at construction. Shown verbatim until the
    /// first live data arrives, so a cold launch renders the last-known list instead of a spinner.
    private let cachedRows: [ActionRow]
    private let cachedSkipped: [SkippedName]
    private let cachedAsOf: Date?

    // Defaults are nil and resolved in the body: the children's `@MainActor` initializers can't be
    // called from a default-argument expression (which Swift evaluates in a nonisolated context), but
    // they can be from this `@MainActor` init. Mirrors `RecommendationsView.init`'s `vm ?? …` pattern.
    init(picks: TodaysPicksViewModel? = nil,
         positions: PositionReviewViewModel? = nil,
         snapshotStore: RecommendationsSnapshotStore? = nil) {
        self.picks = picks ?? TodaysPicksViewModel()
        self.positions = positions ?? PositionReviewViewModel()
        let store = snapshotStore ?? AppDependencies.shared.recommendationsSnapshotStore
        self.snapshotStore = store
        let snap = store.snapshot
        self.cachedRows = Self.merge(picks: snap.recommendations, decisions: snap.decisions)
        self.cachedSkipped = snap.skipped
        self.cachedAsOf = snap.asOf
    }

    /// The live merged, ranked inbox from the two children's current outputs. Computed so Observation
    /// tracks both children whenever either reloads.
    private var liveRows: [ActionRow] { Self.merge(picks: picks.picks, decisions: positions.decisions) }

    /// The inbox the screen renders. Live data wins as soon as there is any; before the first real load
    /// completes (cold start, an awaiting-data pass, or a failed refresh) it falls back to the restored
    /// snapshot, so the screen shows the last-known list instead of a spinner. Once a load has genuinely
    /// completed, an empty result is honoured as "nothing to act on today" — never a stale cache.
    var rows: [ActionRow] {
        if !liveRows.isEmpty { return liveRows }
        return hasLoaded ? [] : cachedRows
    }

    /// True while the screen is showing the restored snapshot rather than live data — nothing has loaded
    /// for real yet and there is nothing live to show. Keeps `asOf` / `skipped` consistent with `rows`.
    private var isShowingCache: Bool { !hasLoaded && liveRows.isEmpty }

    /// How many rows ask for an action (exit, trim, or buy) — drives the "N to act on" summary.
    var actionableCount: Int { rows.filter(\.isActionable).count }

    /// Names skipped (un-valuable: missing fundamentals / no price) across BOTH sides this load —
    /// the non-blocking "N skipped" note. Computed so Observation tracks both children's outputs.
    var skipped: [SkippedName] { isShowingCache ? cachedSkipped : picks.skipped + positions.skipped }

    /// Loading while either child is loading; the first child error surfaces; loaded once both have.
    var isLoading: Bool { picks.isLoading || positions.isLoading }
    var error: String?  { picks.error ?? positions.error }
    var hasLoaded: Bool { picks.hasLoaded && positions.hasLoaded }

    /// Either side is still waiting on the sweep to warm the selection cache — the screen shows a
    /// "waiting for the data sweep" note rather than the initial spinner or a misleading empty state.
    var awaitingData: Bool { picks.awaitingData || positions.awaitingData }

    /// Non-nil only while the market is CLOSED: the time the ranked figures were last warmed, so the
    /// screen labels them "as of <date> · market closed". Both sides read the same sweep-warmed cache, so
    /// either child's stamp serves. nil while open (live figures).
    var asOf: Date? { isShowingCache ? cachedAsOf : (picks.asOf ?? positions.asOf) }

    /// Fan both loads out concurrently. Each child keeps its own cache / `force` semantics and its own
    /// store write, so the allocator's caches are fed exactly as they were by the two separate screens.
    func load(force: Bool = false) async {
        async let buys: Void = picks.load(force: force)
        async let sells: Void = positions.load(force: force)
        _ = await (buys, sells)
        // Persist only a fully successful load (both children loaded for real — not a cold-cache
        // "awaiting" pass and not an error), so the next cold launch restores this exact inbox. A genuine
        // empty result persists an empty snapshot, correctly clearing any previously stale list.
        if hasLoaded {
            snapshotStore.save(.init(recommendations: picks.picks,
                                     decisions: positions.decisions,
                                     skipped: picks.skipped + positions.skipped,
                                     asOf: picks.asOf ?? positions.asOf))
        }
    }

    /// Coalescing guards for the per-stock warm-progress reloads. While the cache warms, the screen
    /// re-ranks after each stock is considered; those ticks can outpace a load, so a reload already in
    /// flight folds further ticks into a single trailing re-run rather than stacking overlapping engine
    /// passes. Both touched only on the main actor, so the check/set is race-free.
    private var isWarmReloadInFlight = false
    private var warmReloadRequestedAgain = false

    /// Re-rank from the (still warming) cache for one warm-progress tick, coalesced so concurrent ticks
    /// never run overlapping loads. If a load is already running the tick is remembered and folded into a
    /// single trailing reload, so the list lands on the latest cache state without N stacked engine passes.
    func reloadForWarmProgress() async {
        if isWarmReloadInFlight {
            warmReloadRequestedAgain = true
            return
        }
        isWarmReloadInFlight = true
        defer { isWarmReloadInFlight = false }
        repeat {
            warmReloadRequestedAgain = false
            await load(force: true)
        } while warmReloadRequestedAgain
    }

    /// Pure merge: dedupe by ticker (a held name's verdict WINS over a fresh buy signal — you already
    /// own it, so its hold/trim/exit discipline governs), then sort buy → hold → trim → exit. Within the
    /// buy group, ties break by conviction (highest first) so the strongest candidates surface top-left
    /// in the grid; every other tie (and the buy-conviction tie itself) breaks by ticker for stability.
    static func merge(picks: [Recommendation], decisions: [ExitDecision]) -> [ActionRow] {
        let held = Set(decisions.map(\.ticker))
        let buys = picks.filter { !held.contains($0.ticker) }.map(ActionRow.buy)
        let verdicts = decisions.map(ActionRow.verdict)
        return (buys + verdicts).sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if case let .buy(l) = a, case let .buy(r) = b, l.conviction != r.conviction {
                return l.conviction > r.conviction
            }
            return a.ticker < b.ticker
        }
    }
}
