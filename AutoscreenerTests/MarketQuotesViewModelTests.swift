import Foundation
import Testing
@testable import Autoscreener

/// `MarketQuotesViewModel` is now a thin projection over the shared `MarketDataStore`
/// (the `DataSweepCoordinator` is the single fetch path — its fan-out is covered by
/// `DataSweepCoordinatorMarketTests`). These tests pin the projection contract.
@MainActor
@Suite struct MarketQuotesViewModelTests {
    private func quote(_ symbol: String) -> CommodityQuote {
        CommodityQuote(symbol: symbol, name: symbol, price: 100, previousClose: 99,
                       change: 1, changePercent: 1.0, volume: 10, formattedPrice: "100", asOf: "now")
    }

    private func vm(_ store: MarketDataStore) -> MarketQuotesViewModel {
        MarketQuotesViewModel(
            store: store,
            coordinator: SweepTestKit.coordinator(store: SweepTestKit.store(), marketStore: store))
    }

    @Test func quotesProjectTheStore() {
        let store = SweepTestKit.marketStore()
        store.applyQuotes(["OIL": quote("OIL"), "XAU": quote("XAU")])

        let model = vm(store)
        #expect(model.quotes.count == 2)
        #expect(model.quotes["OIL"]?.price == 100)
    }

    @Test func emptyStoreProjectsNoQuotes() {
        #expect(vm(SweepTestKit.marketStore()).quotes.isEmpty)
    }

    @Test func notLoadingOnceQuotesHaveLanded() {
        let store = SweepTestKit.marketStore()
        store.applyQuotes(["OIL": quote("OIL")])
        #expect(vm(store).isLoading == false)   // store non-empty → no spinner regardless of sweep state
    }

    // MARK: - loadState / hasLoadedOnce (cold-launch empty/loading)

    @Test func loadStateIsLoadingBeforeAnySweep() {
        let model = vm(SweepTestKit.marketStore())
        #expect(model.hasLoadedOnce == false)
        #expect(model.loadState == .loading)
    }

    @Test func hasLoadedOnceFlipsAndStateIsEmptyAfterASweepWithNoQuotes() {
        let store = SweepTestKit.marketStore()
        store.markSweepComplete(at: Date(timeIntervalSince1970: 0))
        let model = vm(store)
        #expect(model.hasLoadedOnce == true)
        #expect(model.loadState == .empty)   // sweep ran, priced nothing → genuinely empty, not loading
    }

    @Test func loadStateIsReadyOnceQuotesLand() {
        let store = SweepTestKit.marketStore()
        store.applyQuotes(["OIL": quote("OIL")])
        let model = vm(store)
        #expect(model.hasLoadedOnce == true)
        #expect(model.loadState == .ready)
    }
}
