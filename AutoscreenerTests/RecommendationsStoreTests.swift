import Foundation
import Testing
@testable import Autoscreener

// The cheap Gate-5 Phase-3 cache: the latest ranked recommendations keyed by ticker, written by
// `TodaysPicksViewModel` and read by the paper-trading flow at fill time. These pin only its two
// behaviours: keying by ticker, and last-write-wins (a fresh load fully supersedes the previous one).

@Suite @MainActor struct RecommendationsStoreTests {
    private func rec(_ ticker: Ticker, iv: Double = 1_000) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: 0.5, intrinsicValue: iv,
                       marginOfSafety: 0.25, conviction: 0.5, suggestedWeight: 0.05, audit: [])
    }

    @Test func updateKeysByTicker() {
        let store = RecommendationsStore()
        store.update([rec("WIFI"), rec("BBCA")])
        #expect(store.byTicker["WIFI"]?.ticker == "WIFI")
        #expect(store.byTicker["BBCA"]?.ticker == "BBCA")
        #expect(store.byTicker["NONE"] == nil)
    }

    @Test func aFreshLoadSupersedesThePreviousSet() {
        let store = RecommendationsStore()
        store.update([rec("WIFI", iv: 100), rec("BBCA")])
        store.update([rec("WIFI", iv: 999)])           // re-ranked: WIFI updated, BBCA dropped out
        #expect(store.byTicker["WIFI"]?.intrinsicValue == 999)
        #expect(store.byTicker["BBCA"] == nil)
        #expect(store.byTicker.count == 1)
    }

    @Test func startsEmpty() {
        #expect(RecommendationsStore().byTicker.isEmpty)
    }
}
