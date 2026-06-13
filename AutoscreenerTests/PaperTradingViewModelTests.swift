import Foundation
import Testing
@testable import Autoscreener

/// Behavioural coverage for the screen's wiring that the XCUITest can't provide on a
/// multi-display dev machine: the view model joins the three stores, generates a
/// regime-weighted plan from the watchlist, and `execute()` books it into Holdings.
@MainActor
@Suite struct PaperTradingViewModelTests {

    private func snapshot(_ kind: BandarScreenerKind, _ rows: [ScreenerRow]) -> ScreenerSnapshot {
        ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func row(_ symbol: String, price: Double) -> ScreenerRow {
        ScreenerRow(symbol: symbol, name: "\(symbol) Co", values: [1, 0], lastPrice: price, pctChange: 0)
    }

    /// Seeds a screener store so the composite watchlist surfaces two priced names that
    /// clear both liquidity veto gates, plus a market store carrying a regime read.
    private func makeStores() -> (ScreenerStore, MarketDataStore, PaperTradingStore) {
        let screener = SweepTestKit.store()
        let bbca = row("BBCA", price: 9_500)
        let tlkm = row("TLKM", price: 2_800)
        // Present in enough gates (incl. both veto gates) to survive the composer.
        for kind in BandarScreenerKind.allCases {
            screener.apply(snapshot(kind, [bbca, tlkm]), for: kind)
        }
        let market = SweepTestKit.marketStore()
        market.apply(regimeRead: RegimeRead(
            stance: .neutral, score: 0.0,
            factors: [RegimeFactor(kind: .breadth, signal: .neutral, detail: "test")],
            asOf: "2026-06-12", valuationCapped: false))
        let paper = PaperTradingStore(fileURL: nil, loadFromDisk: false)
        return (screener, market, paper)
    }

    private func makeVM(_ screener: ScreenerStore, _ market: MarketDataStore,
                        _ paper: PaperTradingStore,
                        recommendations: RecommendationsStore? = nil) -> PaperTradingViewModel {
        let coordinator = SweepTestKit.coordinator(store: screener, marketStore: market)
        return PaperTradingViewModel(store: paper, screenerStore: screener,
                                     marketStore: market, coordinator: coordinator,
                                     recommendationsStore: recommendations ?? RecommendationsStore())
    }

    @Test func startsSeededAndCanPlanOnceWatchlistAndPricesAreLoaded() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)
        #expect(vm.equity == 100_000_000)
        #expect(vm.canPlan)                       // watchlist + prices both present
        #expect(vm.pendingPlan == nil)
    }

    @Test func generatePlanProposesBuysFromTheWatchlist() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)
        vm.generatePlan()

        let plan = vm.pendingPlan
        #expect(plan != nil)
        #expect(plan?.stance == .neutral)
        #expect(plan!.lines.contains { $0.symbol == "BBCA" && $0.side == .buy })
        // Neutral band deploys ~50–60% of equity; cash target is the complement.
        #expect((plan?.targetExposure ?? 0) >= 0.50)
    }

    @Test func executeBooksThePlanIntoHoldingsAndSpendsCash() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)
        vm.generatePlan()
        vm.execute()

        #expect(vm.pendingPlan == nil)            // plan consumed
        #expect(vm.hasPositions)
        #expect(vm.holdings.contains { $0.symbol == "BBCA" })
        #expect(vm.cash < 100_000_000)            // cash deployed
        #expect(vm.investedValue > 0)
    }

    @Test func resetReturnsToTheSeed() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)
        vm.generatePlan(); vm.execute()
        vm.reset()
        #expect(vm.equity == 100_000_000)
        #expect(!vm.hasPositions)
        #expect(vm.pendingPlan == nil)
    }

    // MARK: - Gate-5 Phase 3: entry-thesis capture at execute()

    @Test func executeStampsAnEntryThesisForBuysInTheRankedSet() {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()
        // Only BBCA was ranked by the engine; its IV/MoS are reused as the entry thesis (no re-fetch).
        recs.update([Recommendation(ticker: "BBCA", compositeScore: 0.6, intrinsicValue: 12_000,
                                    marginOfSafety: 0.3, conviction: 0.6, suggestedWeight: 0.1, audit: [])])
        let vm = makeVM(s, m, p, recommendations: recs)
        vm.generatePlan(); vm.execute()

        #expect(p.state.positions["BBCA"]?.thesis?.entryIntrinsicValue == 12_000)
        #expect(p.state.positions["BBCA"]?.thesis?.entryMarginOfSafety == 0.3)
        // TLKM was bought too, but it wasn't ranked → no thesis (reviews on current data alone).
        #expect(p.state.positions["TLKM"] != nil)
        #expect(p.state.positions["TLKM"]?.thesis == nil)
    }

    @Test func executeWithoutAnyRankedRecommendationsStampsNoThesis() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)                 // empty recommendations store (the default fresh one)
        vm.generatePlan(); vm.execute()
        #expect(vm.hasPositions)                 // behaviour unchanged — buys still book
        #expect(p.state.positions.values.allSatisfy { $0.thesis == nil })
    }
}
