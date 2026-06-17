import Foundation
import Testing
@testable import Autoscreener

/// Behavioural coverage for the screen's wiring that the XCUITest can't provide on a
/// multi-display dev machine: the view model joins the stores, generates a regime-weighted
/// plan from the **buy/sell recommendations** (sized by `suggestedWeight`), and `execute()`
/// books it into Holdings (stamping the Gate-5 entry thesis).
@MainActor
@Suite struct PaperTradingViewModelTests {

    private func snapshot(_ kind: BandarScreenerKind, _ rows: [ScreenerRow]) -> ScreenerSnapshot {
        ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func row(_ symbol: String, price: Double) -> ScreenerRow {
        ScreenerRow(symbol: symbol, name: "\(symbol) Co", values: [1, 0], lastPrice: price, pctChange: 0)
    }

    private func rec(_ ticker: String, iv: Double = 10_000, mos: Double = 0.3,
                     conviction: Double = 0.6, weight: Double = 0.12) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: conviction, intrinsicValue: iv,
                       marginOfSafety: mos, conviction: conviction, suggestedWeight: weight, audit: [])
    }

    /// Seeds a screener store so the composite watchlist surfaces two priced names (the price + name
    /// source), plus a market store carrying a neutral regime read.
    private func makeStores() -> (ScreenerStore, MarketDataStore, PaperTradingStore) {
        let screener = SweepTestKit.store()
        let bbca = row("BBCA", price: 9_500)
        let tlkm = row("TLKM", price: 2_800)
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
                        recommendations: RecommendationsStore? = nil,
                        exits: ExitDecisionsStore? = nil,
                        picks: @escaping (SelectionConfig) async throws -> SelectionOutcome
                            = { _ in SelectionOutcome(recommendations: [], skipped: []) },
                        review: @escaping (SelectionConfig) async throws -> ReviewOutcome
                            = { _ in ReviewOutcome(decisions: [], skipped: []) }) -> PaperTradingViewModel {
        let coordinator = SweepTestKit.coordinator(store: screener, marketStore: market)
        return PaperTradingViewModel(store: paper, screenerStore: screener,
                                     marketStore: market, coordinator: coordinator,
                                     recommendationsStore: recommendations ?? RecommendationsStore(),
                                     exitDecisionsStore: exits ?? ExitDecisionsStore(),
                                     picksSource: picks, reviewSource: review)
    }

    @Test func startsSeededAndCanPlanOnceWatchlistAndPricesAreLoaded() {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)
        #expect(vm.equity == 100_000_000)
        #expect(vm.canPlan)                       // watchlist + prices both present
        #expect(vm.pendingPlan == nil)
    }

    // MARK: - The buy universe is the recommendations, not the watchlist

    @Test func generatePlanBuysOnlyRecommendedNames() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()
        recs.update([rec("BBCA")])                // BBCA recommended; TLKM is in the watchlist but not
        let vm = makeVM(s, m, p, recommendations: recs)
        await vm.generatePlan()

        let plan = vm.pendingPlan
        #expect(plan != nil)
        #expect(plan?.stance == .neutral)
        #expect(plan?.lines.contains { $0.symbol == "BBCA" && $0.side == .buy } == true)
        #expect(plan?.lines.contains { $0.symbol == "TLKM" } == false)   // not recommended → never bought
        #expect((plan?.targetExposure ?? 0) >= 0.50)
    }

    @Test func generatePlanWarmsAColdRecommendationCacheFromTheSource() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()         // cold cache
        let vm = makeVM(s, m, p, recommendations: recs,
                        picks: { _ in SelectionOutcome(recommendations: [self.rec("BBCA")], skipped: []) })
        await vm.generatePlan()
        #expect(recs.byTicker["BBCA"] != nil)     // warmed from the injected source
        #expect(vm.pendingPlan?.lines.contains { $0.symbol == "BBCA" && $0.side == .buy } == true)
    }

    @Test func withNoRecommendationsThereAreNoBuys() async {
        let (s, m, p) = makeStores()
        let vm = makeVM(s, m, p)                   // empty cache, empty injected source
        await vm.generatePlan()
        #expect(vm.pendingPlan?.lines.allSatisfy { $0.side == .sell } == true)  // no buys at all
        vm.execute()
        #expect(!vm.hasPositions)
    }

    @Test func executeBooksThePlanIntoHoldingsAndSpendsCash() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()
        recs.update([rec("BBCA"), rec("TLKM")])
        let vm = makeVM(s, m, p, recommendations: recs)
        await vm.generatePlan()
        vm.execute()

        #expect(vm.pendingPlan == nil)            // plan consumed
        #expect(vm.hasPositions)
        #expect(vm.holdings.contains { $0.symbol == "BBCA" })
        #expect(vm.cash < 100_000_000)            // cash deployed
        #expect(vm.investedValue > 0)
    }

    @Test func resetReturnsToTheSeed() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore(); recs.update([rec("BBCA"), rec("TLKM")])
        let vm = makeVM(s, m, p, recommendations: recs)
        await vm.generatePlan(); vm.execute()
        vm.reset()
        #expect(vm.equity == 100_000_000)
        #expect(!vm.hasPositions)
        #expect(vm.pendingPlan == nil)
    }

    // MARK: - Gate-5 Phase 3: entry-thesis capture at execute()

    @Test func executeStampsAnEntryThesisForEachBoughtName() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore()
        recs.update([rec("BBCA", iv: 12_000, mos: 0.3), rec("TLKM", iv: 5_000, mos: 0.2)])
        let vm = makeVM(s, m, p, recommendations: recs)
        await vm.generatePlan(); vm.execute()

        #expect(p.state.positions["BBCA"]?.thesis?.entryIntrinsicValue == 12_000)
        #expect(p.state.positions["BBCA"]?.thesis?.entryMarginOfSafety == 0.3)
        #expect(p.state.positions["TLKM"]?.thesis?.entryIntrinsicValue == 5_000)
    }

    // MARK: - Gate-5: exit decisions feed generatePlan()

    @Test func generatePlanBarsReentryForNamesFlaggedToExit() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore(); recs.update([rec("BBCA"), rec("TLKM")])
        let exits = ExitDecisionsStore()
        exits.update([ExitDecision(ticker: "BBCA", action: .exit, reason: "thesis broke", audit: [])])
        let vm = makeVM(s, m, p, recommendations: recs, exits: exits)
        await vm.generatePlan()
        #expect(vm.pendingPlan?.lines.contains { $0.symbol == "BBCA" } == false)  // never bought
        #expect(vm.pendingPlan?.lines.contains { $0.symbol == "TLKM" && $0.side == .buy } == true)
    }

    @Test func generatePlanSellsAHeldNameFlaggedForExit() async {
        let (s, m, p) = makeStores()
        let recs = RecommendationsStore(); recs.update([rec("BBCA"), rec("TLKM")])
        let exits = ExitDecisionsStore()
        let vm = makeVM(s, m, p, recommendations: recs, exits: exits)
        await vm.generatePlan(); vm.execute()                 // now holding BBCA + TLKM
        #expect(vm.holdings.contains { $0.symbol == "BBCA" })
        exits.update([ExitDecision(ticker: "BBCA", action: .exit, reason: "governance veto", audit: [])])
        await vm.generatePlan()
        let line = vm.pendingPlan?.lines.first { $0.symbol == "BBCA" }
        #expect(line?.side == .sell)
        #expect(line?.targetShares == 0)
    }
}
