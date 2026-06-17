import Foundation
import Observation

/// One actionable row in the unified Recommendations inbox. It WRAPS — without flattening — the two
/// engine outputs the screen merges: a buy-side `Recommendation` and a sell-side `ExitDecision`. Each
/// case keeps its full domain value so the row renders with the metric block native to its kind, while a
/// single `priority` collapses both into one urgency order (exit → trim → buy → hold).
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

    /// Urgency rank for the single ranked list — lower sorts first. Exits lead (a broken thesis is the
    /// most pressing), then trims, then fresh buys, with plain holds last (nothing to do).
    var priority: Int {
        switch self {
        case .verdict(let d):
            switch d.action {
            case .exit: return 0
            case .trim: return 1
            case .hold: return 3
            }
        case .buy: return 2
        }
    }

    /// Everything except a plain HOLD asks the reader to do something (sell, trim, or open a position).
    var isActionable: Bool { priority < 3 }

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

    // Defaults are nil and resolved in the body: the children's `@MainActor` initializers can't be
    // called from a default-argument expression (which Swift evaluates in a nonisolated context), but
    // they can be from this `@MainActor` init. Mirrors `RecommendationsView.init`'s `vm ?? …` pattern.
    init(picks: TodaysPicksViewModel? = nil,
         positions: PositionReviewViewModel? = nil) {
        self.picks = picks ?? TodaysPicksViewModel()
        self.positions = positions ?? PositionReviewViewModel()
    }

    /// The merged, ranked inbox. Computed so Observation tracks the two children's published outputs.
    var rows: [ActionRow] { Self.merge(picks: picks.picks, decisions: positions.decisions) }

    /// How many rows ask for an action (exit, trim, or buy) — drives the "N to act on" summary.
    var actionableCount: Int { rows.filter(\.isActionable).count }

    /// Names skipped (un-valuable: missing fundamentals / no price) across BOTH sides this load —
    /// the non-blocking "N skipped" note. Computed so Observation tracks both children's outputs.
    var skipped: [SkippedName] { picks.skipped + positions.skipped }

    /// Loading while either child is loading; the first child error surfaces; loaded once both have.
    var isLoading: Bool { picks.isLoading || positions.isLoading }
    var error: String?  { picks.error ?? positions.error }
    var hasLoaded: Bool { picks.hasLoaded && positions.hasLoaded }

    /// Either side is still waiting on the sweep to warm the selection cache — the screen shows a
    /// "waiting for the data sweep" note rather than the initial spinner or a misleading empty state.
    var awaitingData: Bool { picks.awaitingData || positions.awaitingData }

    /// Fan both loads out concurrently. Each child keeps its own cache / `force` semantics and its own
    /// store write, so the allocator's caches are fed exactly as they were by the two separate screens.
    func load(force: Bool = false) async {
        async let buys: Void = picks.load(force: force)
        async let sells: Void = positions.load(force: force)
        _ = await (buys, sells)
    }

    /// Pure merge: dedupe by ticker (a held name's exit verdict WINS over a fresh buy signal — you
    /// already own it, so its hold/trim/exit discipline governs), then sort by urgency. Within the buy
    /// group, ties break by conviction (highest first) so the strongest candidates surface top-left in
    /// the grid; every other tie (and the buy-conviction tie itself) breaks by ticker for stability.
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
