import Foundation
import Testing
@testable import Autoscreener

// The selection-layer cache the sweep fills so Recommendations ranks from cache instead of fetching
// per ticker on tab open. These pin its two behaviours: keying by ticker (last-write-wins), and the
// staleness check that `CachedDataProvider` reads through — a too-old entry/context is a cache miss.

@Suite @MainActor struct SecurityDataStoreTests {

    private func security(_ t: Ticker) -> SecurityData {
        SecurityData(
            ticker: t, sector: "Industrials", price: 100, sharesOutstanding: 0, freeFloatPct: 0,
            financials: [],
            ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                               totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                               returnOnEquity: 0),
            dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
            sectorIndexBars: [], marketIndexBars: [])
    }

    private func context() -> MarketContext {
        MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                      idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                      commodityTailwind: true)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func startsEmpty() {
        let store = SecurityDataStore()
        #expect(store.entries.isEmpty)
        #expect(store.context == nil)
    }

    @Test func updateKeysByTickerLastWriteWins() {
        let store = SecurityDataStore()
        store.update(security("WIFI"), at: t0)
        store.update(security("BBCA"), at: t0)
        store.update(security("WIFI"), at: t0.addingTimeInterval(60))  // re-swept
        #expect(store.entries.count == 2)
        #expect(store.entry(for: "WIFI")?.fetchedAt == t0.addingTimeInterval(60))
        #expect(store.entry(for: "NONE") == nil)
    }

    @Test func freshWithinWindowStaleBeyondItMissingIsNeverFresh() {
        let store = SecurityDataStore()
        store.update(security("WIFI"), at: t0)
        let window: TimeInterval = 3600
        #expect(store.isFresh("WIFI", asOf: t0.addingTimeInterval(1800), within: window))   // within
        #expect(store.isFresh("WIFI", asOf: t0.addingTimeInterval(3600), within: window))   // boundary
        #expect(!store.isFresh("WIFI", asOf: t0.addingTimeInterval(3601), within: window))  // stale
        #expect(!store.isFresh("ABSENT", asOf: t0, within: window))                          // miss
    }

    @Test func freshSnapshotDropsStaleEntriesAndStaleContext() {
        let store = SecurityDataStore()
        store.update(security("FRESH"), at: t0)
        store.update(security("STALE"), at: t0.addingTimeInterval(-10_000))
        store.updateContext(context(), at: t0.addingTimeInterval(-10_000))

        let snap = store.freshSnapshot(asOf: t0, within: 3600)
        #expect(Array(snap.data.keys) == ["FRESH"])
        #expect(snap.context == nil)   // context too old → dropped, so the provider reports cold
    }

    @Test func freshSnapshotKeepsFreshContext() {
        let store = SecurityDataStore()
        store.update(security("WIFI"), at: t0)
        store.updateContext(context(), at: t0)
        let snap = store.freshSnapshot(asOf: t0.addingTimeInterval(60), within: 3600)
        #expect(snap.context != nil)
        #expect(snap.data["WIFI"] != nil)
    }

    // MARK: - Closed-market read: rank the last-warmed close (Fix A)

    @Test func lastWarmedAtIsTheNewestFetchedTimeAcrossEntriesAndContext() {
        let store = SecurityDataStore()
        #expect(store.lastWarmedAt() == nil)                       // nothing cached yet
        store.update(security("WIFI"), at: t0)
        store.update(security("BBCA"), at: t0.addingTimeInterval(120))   // newest entry
        store.updateContext(context(), at: t0.addingTimeInterval(60))
        #expect(store.lastWarmedAt() == t0.addingTimeInterval(120))
    }

    @Test func lastWarmedAtCanBeTheContextWhenItIsNewest() {
        let store = SecurityDataStore()
        store.update(security("WIFI"), at: t0)
        store.updateContext(context(), at: t0.addingTimeInterval(300))   // context warmed last
        #expect(store.lastWarmedAt() == t0.addingTimeInterval(300))
    }

    @Test func anUnboundedWindowRanksEvenLongStaleEntries() {
        // The closed-market read path uses an effectively-unbounded window so the last-warmed close
        // ranks no matter how long the market's been shut (a weekend / holiday past the 36h window).
        let store = SecurityDataStore()
        store.update(security("WIFI"), at: t0)
        store.updateContext(context(), at: t0)
        let weekLater = t0.addingTimeInterval(7 * 24 * 3600)       // a week after it was warmed

        #expect(store.freshSnapshot(asOf: weekLater, within: SecurityDataStore.defaultMaxAge).data.isEmpty)  // 36h: dropped
        let snap = store.freshSnapshot(asOf: weekLater, within: .greatestFiniteMagnitude)
        #expect(snap.data["WIFI"] != nil)                          // unbounded: still ranked
        #expect(snap.context != nil)
    }
}
