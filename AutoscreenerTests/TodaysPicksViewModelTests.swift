import Foundation
import Testing
@testable import Autoscreener

// Drives the "Today's Picks" screen ViewModel. The live source (the headless `SelectionRunner` via
// `AppDependencies.todaysPicks`) has its own suites; these tests pin only the VM's presentation
// contract: it loads the ranked recommendations from its injected async source, surfaces a load
// failure as an error, toggles `isLoading`, treats an empty result as a (successful) "no picks"
// state, and caches — re-running only when `force` is passed (mirrors `RegimeViewModel`).

@Suite @MainActor struct TodaysPicksViewModelTests {
    private struct Boom: Error {}

    /// Object Mother — a recommendation with evident, readable values.
    private func makeRecommendation(_ ticker: Ticker = "WIFI",
                                    composite: Double = 0.72) -> Recommendation {
        Recommendation(
            ticker: ticker, compositeScore: composite, intrinsicValue: 6_364,
            marginOfSafety: 0.25, conviction: composite, suggestedWeight: 0.08,
            audit: ["regime=Neutral", "✓ DataIntegrity", "→ conviction 0.72 weight 8%"])
    }

    /// A spy standing in for the picks source: records its call count and (so the loading flag can
    /// be verified mid-flight) the VM's `isLoading` at the moment it is invoked.
    @MainActor private final class SourceSpy {
        private(set) var callCount = 0
        var result: [Recommendation] = []
        var skipped: [SkippedName] = []
        var error: Error?
        var loadingWhenCalled: Bool?
        weak var vm: TodaysPicksViewModel?

        func source(_ config: SelectionConfig) async throws -> SelectionOutcome {
            callCount += 1
            loadingWhenCalled = vm?.isLoading
            if let error { throw error }
            return SelectionOutcome(recommendations: result, skipped: skipped)
        }
    }

    @Test func loadPopulatesPicksFromTheSource() async {
        let spy = SourceSpy()
        spy.result = [makeRecommendation("WIFI"), makeRecommendation("BBCA", composite: 0.61)]
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()

        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
        #expect(vm.picks.map(\.ticker) == ["WIFI", "BBCA"])
    }

    @Test func loadSurfacesAnErrorWhenTheSourceThrows() async {
        let spy = SourceSpy()
        spy.error = Boom()
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()

        #expect(vm.picks.isEmpty)
        #expect(vm.error != nil)
        #expect(vm.isLoading == false)
    }

    @Test func isLoadingIsTrueWhileTheSourceRuns() async {
        let spy = SourceSpy()
        spy.result = [makeRecommendation()]
        let vm = TodaysPicksViewModel(source: spy.source)
        spy.vm = vm

        await vm.load()

        #expect(spy.loadingWhenCalled == true)   // set before awaiting the source
        #expect(vm.isLoading == false)            // cleared after it returns
    }

    @Test func anEmptyResultIsASuccessfulNoPicksStateNotAnError() async {
        let spy = SourceSpy()
        spy.result = []
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()

        #expect(vm.picks.isEmpty)
        #expect(vm.error == nil)
    }

    @Test func loadCachesAndDoesNotRefetchUnlessForced() async {
        let spy = SourceSpy()
        spy.result = [makeRecommendation()]
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()
        await vm.load()                 // cached — no second fetch
        #expect(spy.callCount == 1)

        await vm.load(force: true)      // explicit refresh re-fetches
        #expect(spy.callCount == 2)
    }

    @Test func aFailedLoadIsNotCachedSoTheNextAppearanceRetries() async {
        let spy = SourceSpy()
        spy.error = Boom()
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()                 // fails → not marked loaded
        await vm.load()                 // retries without force
        #expect(spy.callCount == 2)
    }

    // MARK: - Gate-5 Phase 3: feed the entry-thesis cache

    @Test func aSuccessfulLoadFeedsTheRecommendationsCache() async {
        let spy = SourceSpy()
        spy.result = [makeRecommendation("WIFI"), makeRecommendation("BBCA", composite: 0.61)]
        let recs = RecommendationsStore()
        let vm = TodaysPicksViewModel(source: spy.source, recommendationsStore: recs)

        await vm.load()

        // The paper-trading flow reads this cache at fill time to snapshot an EntryThesis cheaply.
        #expect(recs.byTicker["WIFI"]?.ticker == "WIFI")
        #expect(recs.byTicker["BBCA"]?.ticker == "BBCA")
    }

    @Test func aFailedLoadLeavesTheRecommendationsCacheUntouched() async {
        let spy = SourceSpy()
        spy.error = Boom()
        let recs = RecommendationsStore()
        let vm = TodaysPicksViewModel(source: spy.source, recommendationsStore: recs)

        await vm.load()

        #expect(recs.byTicker.isEmpty)
    }

    // MARK: - Skipped names (resilience): surfaced for the non-blocking "N skipped" note.

    @Test func loadSurfacesSkippedNamesWithoutAnError() async {
        let spy = SourceSpy()
        spy.result = [makeRecommendation("WIFI")]
        spy.skipped = [SkippedName(ticker: "BAD", reason: "Current Ratio unavailable")]
        let vm = TodaysPicksViewModel(source: spy.source)

        await vm.load()

        #expect(vm.error == nil)                       // a skipped name is not a failure
        #expect(vm.picks.map(\.ticker) == ["WIFI"])    // the valuable name still ranks
        #expect(vm.skipped.map(\.ticker) == ["BAD"])
    }
}
