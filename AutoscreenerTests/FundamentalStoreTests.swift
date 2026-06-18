import Foundation
import Testing
@testable import Autoscreener

// The SLOW-leg cache: holds the per-symbol `FundamentalSlice` with its own (generous) staleness
// window so an intraday pass can reuse cached fundamentals while the close-capture sweep refreshes
// them, and persists to disk so a cold launch recomposes from yesterday's fundamentals. These pin its
// read/freshness contract and its persistence (round-trip + corrupt-file safety + cold-launch hydration).
@Suite @MainActor struct FundamentalStoreTests {

    private func slice(sector: String = "Tech") -> FundamentalSlice {
        FundamentalSlice(
            sector: sector, sharesOutstanding: 0, freeFloatPct: 0, financials: [],
            ttm: TTMFinancials(eps: 0, bookValuePerShare: 0, netIncome: 0, operatingCashFlow: 0,
                               totalAssets: 0, epsGrowthPct: 0, currentRatio: 0, debtToEquity: 0,
                               returnOnEquity: 0),
            sectorIndexSymbol: "IDXSECT", peerComparison: nil, seasonality: nil,
            analystCoverage: nil, governance: nil)
    }

    /// A unique temp file so persistence tests don't collide or touch the app's real cache.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fundamental-store-test-\(UUID().uuidString).json")
    }

    // MARK: - In-memory freshness (persistence off)

    @Test func storesAndReadsAFreshSlice() {
        let store = FundamentalStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.update(slice(sector: "Energy"), for: "AAA", at: now)
        #expect(store.freshSlice(for: "AAA", asOf: now)?.sector == "Energy")
        #expect(store.isFresh("AAA", asOf: now))
        #expect(store.lastWarmedAt() == now)
    }

    @Test func treatsAnEntryOlderThanMaxAgeAsAMiss() {
        let store = FundamentalStore(fileURL: nil)
        let warmedAt = Date(timeIntervalSince1970: 0)
        store.update(slice(), for: "AAA", at: warmedAt)
        let later = warmedAt.addingTimeInterval(FundamentalStore.defaultMaxAge + 1)
        #expect(store.freshSlice(for: "AAA", asOf: later) == nil)
        #expect(!store.isFresh("AAA", asOf: later))
        // ...but still fresh exactly at the boundary.
        #expect(store.isFresh("AAA", asOf: warmedAt.addingTimeInterval(FundamentalStore.defaultMaxAge)))
    }

    @Test func aMissingTickerIsACacheMiss() {
        let store = FundamentalStore(fileURL: nil)
        #expect(store.freshSlice(for: "ZZZ", asOf: Date(timeIntervalSince1970: 0)) == nil)
        #expect(store.lastWarmedAt() == nil)
    }

    // MARK: - Persistence (cold-launch hydration)

    @Test func persistsAndRehydratesAcrossInstances() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let warmedAt = Date(timeIntervalSince1970: 2_000_000)

        // First instance warms the slow leg (write-through to disk)...
        let writer = FundamentalStore(fileURL: url)
        writer.update(slice(sector: "Banks"), for: "BBCA", at: warmedAt)

        // ...a fresh instance (cold launch) hydrates yesterday's fundamentals from disk.
        let reloaded = FundamentalStore(fileURL: url)
        let restored = reloaded.freshSlice(for: "BBCA", asOf: warmedAt)
        #expect(restored?.sector == "Banks")
        #expect(restored?.sectorIndexSymbol == "IDXSECT")
        #expect(reloaded.lastWarmedAt() == warmedAt)
    }

    @Test func ignoresACorruptCacheFileAndStartsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        let store = FundamentalStore(fileURL: url)   // must not crash
        #expect(store.entries.isEmpty)
        #expect(store.lastWarmedAt() == nil)
    }
}
