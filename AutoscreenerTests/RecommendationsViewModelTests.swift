import Foundation
import Testing
@testable import Autoscreener

// Drives the unified "Recommendations" screen ViewModel. It owns the two child VMs (Today's Picks +
// Positions to Review), each of which has its own suite; these tests pin the COMPOSITION contract:
// the pure `merge` (buy→hold→trim→exit order, and verdict-wins dedupe for held names), the fan-out load, and the
// aggregated loading / error / loaded state across the two children.

@Suite @MainActor struct RecommendationsViewModelTests {
    private struct Boom: Error {}

    // MARK: Object Mothers

    private func rec(_ ticker: Ticker, weight: Double = 0.05, conviction: Double = 0.6) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: 0.6, intrinsicValue: 1_000,
                       marginOfSafety: 0.2, conviction: conviction, suggestedWeight: weight,
                       audit: ["→ conviction \(String(format: "%.2f", conviction)) weight 5%"])
    }

    private func dec(_ ticker: Ticker, _ action: ExitAction) -> ExitDecision {
        ExitDecision(ticker: ticker, action: action, reason: "r", audit: ["review \(ticker)"])
    }

    /// A spy standing in for BOTH child sources — records call counts and serves fixed results/errors,
    /// mirroring the proven per-VM spies (`TodaysPicksViewModelTests` / `PositionReviewViewModelTests`).
    @MainActor private final class Spies {
        var picksResult: [Recommendation] = []
        var decisionsResult: [ExitDecision] = []
        var picksSkipped: [SkippedName] = []
        var decisionsSkipped: [SkippedName] = []
        var picksAwaiting = false
        var decisionsAwaiting = false
        var picksError: Error?
        var decisionsError: Error?
        private(set) var picksCalls = 0
        private(set) var decisionsCalls = 0

        func picksSource(_ c: SelectionConfig) async throws -> SelectionOutcome {
            picksCalls += 1
            if let picksError { throw picksError }
            return SelectionOutcome(recommendations: picksResult, skipped: picksSkipped, awaitingData: picksAwaiting)
        }
        func decisionsSource(_ c: SelectionConfig) async throws -> ReviewOutcome {
            decisionsCalls += 1
            if let decisionsError { throw decisionsError }
            return ReviewOutcome(decisions: decisionsResult, skipped: decisionsSkipped, awaitingData: decisionsAwaiting)
        }
    }

    /// Build a unified VM whose two children are wired to the spy and to throwaway stores (so the
    /// shared singleton stores the allocator reads are never touched by a test run). `snapshot` defaults
    /// to a fresh, persistence-off snapshot cache so the cold-start fallback is empty unless seeded.
    private func makeVM(_ spies: Spies,
                        snapshot: RecommendationsSnapshotStore? = nil) -> RecommendationsViewModel {
        RecommendationsViewModel(
            picks: TodaysPicksViewModel(source: spies.picksSource, recommendationsStore: RecommendationsStore()),
            positions: PositionReviewViewModel(source: spies.decisionsSource, exitDecisionsStore: ExitDecisionsStore()),
            snapshotStore: snapshot ?? RecommendationsSnapshotStore(fileURL: nil, loadFromDisk: false))
    }

    /// A snapshot cache pre-seeded with a previously-displayed inbox, to drive the cold-start fallback.
    private func seededSnapshot(_ recs: [Recommendation], _ decs: [ExitDecision],
                                skipped: [SkippedName] = [], asOf: Date? = nil) -> RecommendationsSnapshotStore {
        let store = RecommendationsSnapshotStore(fileURL: nil, loadFromDisk: false)
        store.save(.init(recommendations: recs, decisions: decs, skipped: skipped, asOf: asOf))
        return store
    }

    // MARK: - Pure merge

    @Test func mergeRanksBuyHoldTrimExit() {
        let rows = RecommendationsViewModel.merge(
            picks: [rec("BBBB")],
            decisions: [dec("HHHH", .hold), dec("EEEE", .exit), dec("TTTT", .trim)])

        #expect(rows.map(\.ticker) == ["BBBB", "HHHH", "TTTT", "EEEE"])
    }

    @Test func mergeDedupesHeldNamesSoTheExitVerdictWinsOverAFreshBuy() {
        // WIFI is both a ranked buy candidate AND a held position under review: you own it, so its
        // verdict governs and it appears once — as a verdict, not a buy.
        let rows = RecommendationsViewModel.merge(
            picks: [rec("WIFI"), rec("AAAA")],
            decisions: [dec("WIFI", .hold)])

        #expect(rows.map(\.ticker) == ["AAAA", "WIFI"])   // buy AAAA (prio 0) then hold WIFI (prio 1)
        if case .verdict(let d)? = rows.first(where: { $0.ticker == "WIFI" }) {
            #expect(d.action == .hold)
        } else {
            Issue.record("WIFI should survive as a verdict (held), not a buy")
        }
    }

    @Test func mergeOrdersBuysByConvictionDescendingThenTicker() {
        // Within the buy group, conviction wins over ticker: ZZZZ (higher conviction) leads AAAA
        // even though it sorts later alphabetically. CCCC ties ZZZZ on conviction → ticker breaks it.
        let rows = RecommendationsViewModel.merge(
            picks: [rec("AAAA", conviction: 0.30),
                    rec("ZZZZ", conviction: 0.90),
                    rec("CCCC", conviction: 0.90)],
            decisions: [])

        #expect(rows.map(\.ticker) == ["CCCC", "ZZZZ", "AAAA"])
    }

    @Test func buysLeadAllVerdictsAndExitsSortLast() {
        // Buys are now the primary group: every buy sorts ahead of every verdict, regardless of how
        // urgent the verdict is. Within verdicts the order is hold → trim → exit.
        let rows = RecommendationsViewModel.merge(
            picks: [rec("HIGH", conviction: 0.99)],
            decisions: [dec("EEEE", .exit), dec("HHHH", .hold)])

        #expect(rows.map(\.ticker) == ["HIGH", "HHHH", "EEEE"])
    }

    @Test func mergeOfEmptyInputsIsEmpty() {
        #expect(RecommendationsViewModel.merge(picks: [], decisions: []).isEmpty)
    }

    // MARK: - Composition over the live children

    @Test func loadFansOutToBothChildrenAndMergesTheResult() async {
        let spies = Spies()
        spies.picksResult = [rec("BBCA")]
        spies.decisionsResult = [dec("XXXX", .exit), dec("WIFI", .hold)]
        let vm = makeVM(spies)

        await vm.load()

        #expect(spies.picksCalls == 1)
        #expect(spies.decisionsCalls == 1)
        #expect(vm.rows.map(\.ticker) == ["BBCA", "WIFI", "XXXX"])   // buy, hold, exit
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
        #expect(vm.hasLoaded)
    }

    @Test func actionableCountExcludesPlainHolds() async {
        let spies = Spies()
        spies.picksResult = [rec("BBCA")]
        spies.decisionsResult = [dec("XXXX", .exit), dec("BBNI", .trim), dec("WIFI", .hold)]
        let vm = makeVM(spies)

        await vm.load()

        #expect(vm.rows.count == 4)
        #expect(vm.actionableCount == 3)   // exit + trim + buy; the hold is not "to act on"
    }

    @Test func anyChildErrorSurfacesAndBlocksTheLoadedState() async {
        let spies = Spies()
        spies.picksError = Boom()
        spies.decisionsResult = [dec("WIFI", .hold)]
        let vm = makeVM(spies)

        await vm.load()

        #expect(vm.error != nil)
        #expect(vm.hasLoaded == false)     // one child failed → not fully loaded
        #expect(vm.isLoading == false)
    }

    @Test func hasLoadedIsTrueOnlyWhenBothChildrenSucceed() async {
        let spies = Spies()
        spies.picksResult = []
        spies.decisionsResult = []
        let vm = makeVM(spies)

        await vm.load()

        #expect(vm.hasLoaded)              // an empty merged inbox is still a successful load
        #expect(vm.rows.isEmpty)
        #expect(vm.error == nil)
    }

    @Test func skippedAggregatesBothChildrenForTheScreenNote() async {
        let spies = Spies()
        spies.picksResult = [rec("WIFI")]
        spies.picksSkipped = [SkippedName(ticker: "BAD1", reason: "Current Ratio unavailable")]
        spies.decisionsSkipped = [SkippedName(ticker: "BAD2", reason: "no price data")]
        let vm = makeVM(spies)

        await vm.load()

        #expect(vm.error == nil)                                       // skips aren't failures
        #expect(Set(vm.skipped.map(\.ticker)) == ["BAD1", "BAD2"])     // buy- + sell-side merged
    }

    // MARK: - Incremental warm-progress reloads (coalesced)
    //
    // While the per-symbol cache warms, the screen re-ranks after EACH stock is considered (driven off
    // the sweep coordinator's per-stock progress) instead of waiting for the whole warm to finish. Those
    // ticks can fire faster than a load completes, so the VM coalesces them: never two overlapping engine
    // passes, and a tick that arrives mid-load folds into a single trailing re-rank.

    /// A source that records peak concurrency, so an overlapping second load is observable. Each call
    /// suspends (via `Task.yield`) long enough for a racing call to be detected if the guard were absent.
    @MainActor private final class ConcurrencyProbe {
        private(set) var calls = 0
        private var inFlight = 0
        private(set) var maxInFlight = 0
        func source(_ c: SelectionConfig) async throws -> SelectionOutcome {
            calls += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            await Task.yield(); await Task.yield()
            inFlight -= 1
            return SelectionOutcome(recommendations: [], skipped: [])
        }
    }

    @Test func warmProgressReloadsNeverRunOverlappingEnginePasses() async {
        let probe = ConcurrencyProbe()
        let spies = Spies()   // positions side returns immediately
        let vm = RecommendationsViewModel(
            picks: TodaysPicksViewModel(source: probe.source, recommendationsStore: RecommendationsStore()),
            positions: PositionReviewViewModel(source: spies.decisionsSource, exitDecisionsStore: ExitDecisionsStore()),
            snapshotStore: RecommendationsSnapshotStore(fileURL: nil, loadFromDisk: false))

        // Five warm-progress ticks fire before the first reload can finish (as they would per-stock).
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { @MainActor in await vm.reloadForWarmProgress() } }
        }

        #expect(probe.maxInFlight == 1)   // the picks engine never re-ran while a pass was already running
        #expect(probe.calls >= 1)         // …but at least one re-rank actually happened
    }

    // MARK: - Cold-start cache (stale-while-revalidate)
    //
    // On a cold launch (or the first visit before the sweep warms the cache) the screen should render
    // the LAST persisted inbox instead of a spinner, then swap to live data once the fresh load lands —
    // and never show a stale list once a genuine load has completed.

    @Test func beforeAnyLoadTheRestoredInboxIsShownInsteadOfNothing() {
        let vm = makeVM(Spies(),   // sources never called — we don't load
                        snapshot: seededSnapshot([rec("BBCA")], [dec("WIFI", .exit)]))

        #expect(vm.hasLoaded == false)
        #expect(vm.rows.map(\.ticker) == ["BBCA", "WIFI"])   // buy leads the exit — the restored cache
    }

    @Test func aColdCacheRefreshKeepsTheRestoredInboxRatherThanBlankingToWaiting() async {
        let spies = Spies()
        spies.picksAwaiting = true          // the sweep is still cold on both sides
        spies.decisionsAwaiting = true
        let vm = makeVM(spies, snapshot: seededSnapshot([rec("BBCA")], [dec("WIFI", .exit)]))

        await vm.load()

        #expect(vm.awaitingData)            // the refresh did come back "awaiting"…
        #expect(vm.hasLoaded == false)
        #expect(vm.rows.map(\.ticker) == ["BBCA", "WIFI"])   // …but the cache stays on screen
    }

    @Test func aFailedRefreshKeepsTheRestoredInbox() async {
        let spies = Spies()
        spies.picksError = Boom()
        spies.decisionsError = Boom()
        let vm = makeVM(spies, snapshot: seededSnapshot([rec("BBCA")], []))

        await vm.load()

        #expect(vm.error != nil)
        #expect(vm.hasLoaded == false)
        #expect(vm.rows.map(\.ticker) == ["BBCA"])   // still the cache, not the error state
    }

    @Test func aGenuineEmptyLoadClearsTheCacheAndShowsNothingToDo() async {
        let spies = Spies()                 // both children succeed with empty results
        let vm = makeVM(spies, snapshot: seededSnapshot([rec("BBCA")], [dec("WIFI", .hold)]))

        await vm.load()

        #expect(vm.hasLoaded)
        #expect(vm.rows.isEmpty)            // a real "nothing to act on today" — never the stale cache
    }

    @Test func liveDataReplacesTheCacheOnceItArrives() async {
        let spies = Spies()
        spies.picksResult = [rec("AAAA")]   // the fresh ranking differs from the cached one
        let vm = makeVM(spies, snapshot: seededSnapshot([rec("BBCA")], [dec("WIFI", .exit)]))

        await vm.load()

        #expect(vm.hasLoaded)
        #expect(vm.rows.map(\.ticker) == ["AAAA"])   // live wins; the cache is gone
    }

    @Test func aSuccessfulLoadPersistsTheInboxForTheNextColdStart() async {
        let snapshot = RecommendationsSnapshotStore(fileURL: nil, loadFromDisk: false)
        let spies = Spies()
        spies.picksResult = [rec("BBCA")]
        spies.decisionsResult = [dec("WIFI", .exit)]
        let vm = makeVM(spies, snapshot: snapshot)

        await vm.load()

        #expect(vm.rows.map(\.ticker) == ["BBCA", "WIFI"])
        // The store now holds exactly what was shown, ready to restore on the next launch.
        #expect(snapshot.snapshot.recommendations.map(\.ticker) == ["BBCA"])
        #expect(snapshot.snapshot.decisions.map(\.ticker) == ["WIFI"])
    }

    @Test func aColdCacheRefreshDoesNotPersistOverTheGoodCache() async {
        // An "awaiting" refresh must NOT overwrite a good persisted inbox with an empty one — otherwise
        // the next launch would lose the cache it was meant to restore.
        let snapshot = seededSnapshot([rec("BBCA")], [dec("WIFI", .exit)])
        let spies = Spies()
        spies.picksAwaiting = true
        spies.decisionsAwaiting = true
        let vm = makeVM(spies, snapshot: snapshot)

        await vm.load()

        #expect(snapshot.snapshot.recommendations.map(\.ticker) == ["BBCA"])   // untouched on disk
    }
}
