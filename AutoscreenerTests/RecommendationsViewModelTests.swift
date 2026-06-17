import Foundation
import Testing
@testable import Autoscreener

// Drives the unified "Recommendations" screen ViewModel. It owns the two child VMs (Today's Picks +
// Positions to Review), each of which has its own suite; these tests pin the COMPOSITION contract:
// the pure `merge` (urgency order, and verdict-wins dedupe for held names), the fan-out load, and the
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
        var picksError: Error?
        var decisionsError: Error?
        private(set) var picksCalls = 0
        private(set) var decisionsCalls = 0

        func picksSource(_ c: SelectionConfig) async throws -> SelectionOutcome {
            picksCalls += 1
            if let picksError { throw picksError }
            return SelectionOutcome(recommendations: picksResult, skipped: picksSkipped)
        }
        func decisionsSource(_ c: SelectionConfig) async throws -> ReviewOutcome {
            decisionsCalls += 1
            if let decisionsError { throw decisionsError }
            return ReviewOutcome(decisions: decisionsResult, skipped: decisionsSkipped)
        }
    }

    /// Build a unified VM whose two children are wired to the spy and to throwaway stores (so the
    /// shared singleton stores the allocator reads are never touched by a test run).
    private func makeVM(_ spies: Spies) -> RecommendationsViewModel {
        RecommendationsViewModel(
            picks: TodaysPicksViewModel(source: spies.picksSource, recommendationsStore: RecommendationsStore()),
            positions: PositionReviewViewModel(source: spies.decisionsSource, exitDecisionsStore: ExitDecisionsStore()))
    }

    // MARK: - Pure merge

    @Test func mergeRanksByUrgencyExitTrimBuyHold() {
        let rows = RecommendationsViewModel.merge(
            picks: [rec("BBBB")],
            decisions: [dec("HHHH", .hold), dec("EEEE", .exit), dec("TTTT", .trim)])

        #expect(rows.map(\.ticker) == ["EEEE", "TTTT", "BBBB", "HHHH"])
    }

    @Test func mergeDedupesHeldNamesSoTheExitVerdictWinsOverAFreshBuy() {
        // WIFI is both a ranked buy candidate AND a held position under review: you own it, so its
        // verdict governs and it appears once — as a verdict, not a buy.
        let rows = RecommendationsViewModel.merge(
            picks: [rec("WIFI"), rec("AAAA")],
            decisions: [dec("WIFI", .hold)])

        #expect(rows.map(\.ticker) == ["AAAA", "WIFI"])   // buy AAAA (prio 2) then hold WIFI (prio 3)
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

    @Test func verdictsStillLeadBuysRegardlessOfConviction() {
        // Urgency stays the primary key: a top-conviction buy never jumps ahead of an exit/trim
        // verdict, and a plain hold still sorts last.
        let rows = RecommendationsViewModel.merge(
            picks: [rec("HIGH", conviction: 0.99)],
            decisions: [dec("EEEE", .exit), dec("HHHH", .hold)])

        #expect(rows.map(\.ticker) == ["EEEE", "HIGH", "HHHH"])
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
        #expect(vm.rows.map(\.ticker) == ["XXXX", "BBCA", "WIFI"])   // exit, buy, hold
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
}
