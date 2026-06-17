import Foundation
import Testing
@testable import Autoscreener

// Drives the "Positions to Review" screen ViewModel. The live source (`PositionReviewer` via
// `AppDependencies.reviewPositions`) has its own suites; these pin only the VM's presentation contract:
// it loads the hold/trim/exit decisions from its injected async source, surfaces a load failure as an
// error, toggles `isLoading`, treats an empty result as a (successful) "nothing to review" state, splits
// out the actionable names, and caches — re-running only when `force` is passed.

@Suite @MainActor struct PositionReviewViewModelTests {
    private struct Boom: Error {}

    private func decision(_ ticker: Ticker, _ action: ExitAction,
                          _ reason: String = "r") -> ExitDecision {
        ExitDecision(ticker: ticker, action: action, reason: reason, audit: ["review \(ticker)"])
    }

    @MainActor private final class SourceSpy {
        private(set) var callCount = 0
        var result: [ExitDecision] = []
        var skipped: [SkippedName] = []
        var asOf: Date?
        var error: Error?
        var loadingWhenCalled: Bool?
        weak var vm: PositionReviewViewModel?

        func source(_ config: SelectionConfig) async throws -> ReviewOutcome {
            callCount += 1
            loadingWhenCalled = vm?.isLoading
            if let error { throw error }
            return ReviewOutcome(decisions: result, skipped: skipped, asOf: asOf)
        }
    }

    @Test func loadPopulatesDecisionsFromTheSource() async {
        let spy = SourceSpy()
        spy.result = [decision("WIFI", .hold), decision("XXXX", .exit)]
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()

        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
        #expect(vm.decisions.map(\.ticker) == ["WIFI", "XXXX"])
    }

    @Test func actionableSplitsOutExitsAndTrims() async {
        let spy = SourceSpy()
        spy.result = [decision("WIFI", .hold), decision("XXXX", .exit), decision("BBNI", .trim)]
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()

        #expect(Set(vm.actionable.map(\.ticker)) == ["XXXX", "BBNI"])
    }

    @Test func loadSurfacesAnErrorWhenTheSourceThrows() async {
        let spy = SourceSpy()
        spy.error = Boom()
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()

        #expect(vm.decisions.isEmpty)
        #expect(vm.error != nil)
        #expect(vm.isLoading == false)
    }

    @Test func isLoadingIsTrueWhileTheSourceRuns() async {
        let spy = SourceSpy()
        spy.result = [decision("WIFI", .hold)]
        let vm = PositionReviewViewModel(source: spy.source)
        spy.vm = vm

        await vm.load()

        #expect(spy.loadingWhenCalled == true)
        #expect(vm.isLoading == false)
    }

    @Test func anEmptyResultIsASuccessfulNothingToReviewStateNotAnError() async {
        let spy = SourceSpy()
        spy.result = []
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()

        #expect(vm.decisions.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.hasLoaded)
    }

    @Test func loadCachesAndDoesNotRefetchUnlessForced() async {
        let spy = SourceSpy()
        spy.result = [decision("WIFI", .hold)]
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()
        await vm.load()                 // cached — no second fetch
        #expect(spy.callCount == 1)

        await vm.load(force: true)      // explicit refresh re-fetches
        #expect(spy.callCount == 2)
    }

    @Test func aFailedLoadIsNotCachedSoTheNextAppearanceRetries() async {
        let spy = SourceSpy()
        spy.error = Boom()
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()
        await vm.load()
        #expect(spy.callCount == 2)
    }

    @Test func aClosedMarketLoadSurfacesTheAsOfStamp() async {
        let spy = SourceSpy()
        let close = Date(timeIntervalSince1970: 1_700_000_000)
        spy.result = [decision("WIFI", .hold)]
        spy.asOf = close                 // closed market → reviewed against the last-warmed close
        let vm = PositionReviewViewModel(source: spy.source)

        await vm.load()

        #expect(vm.asOf == close)        // feeds the screen's "as of <date> · market closed" caption
        #expect(vm.hasLoaded)
    }

    @Test func loadFeedsTheExitDecisionsStoreForTheAllocator() async {
        let spy = SourceSpy()
        spy.result = [decision("WIFI", .hold), decision("XXXX", .exit), decision("BBNI", .trim)]
        let store = ExitDecisionsStore()
        let vm = PositionReviewViewModel(source: spy.source, exitDecisionsStore: store)

        await vm.load()

        #expect(store.byTicker["XXXX"] == .exit)
        #expect(store.byTicker["BBNI"] == .trim)
        #expect(store.byTicker["WIFI"] == .hold)
    }
}
