import Foundation
import Testing
@testable import Autoscreener

@Suite struct ScreenerSnapshotStoreTests {
    private func makeTempStore(enabled: Bool = true) -> (ScreenerSnapshotStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoscreenerSnapshotTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ScreenerSnapshotStore(directory: dir, isEnabled: { @Sendable in enabled }), dir)
    }

    private func sampleScreenerSnapshot() -> ScreenerSnapshot {
        var config = ScreenerConfig()
        config.screenerID = "6676213"
        config.sequence = [14399, 14426]
        return ScreenerSnapshot(
            templateID: "6676213",
            config: config,
            rows: [
                ScreenerRow(symbol: "BBCA", name: "Bank Central Asia",
                            values: [123.0, 456.0], lastPrice: 9000, pctChange: 0.5),
                ScreenerRow(symbol: "BBRI", name: "Bank Rakyat Indonesia",
                            values: [78.0, 90.0], lastPrice: 4400, pctChange: -0.3),
            ],
            total: 42,
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func savedScreenerRoundTripsRowsAndConfig() async {
        let (store, _) = makeTempStore()
        let original = sampleScreenerSnapshot()
        await store.saveScreener(original)
        let restored = await store.loadScreener(templateID: original.templateID)
        #expect(restored?.rows.count == 2)
        #expect(restored?.rows.first?.symbol == "BBCA")
        #expect(restored?.config.sequence == [14399, 14426])
        #expect(restored?.total == 42)
        #expect(restored?.fetchedAt == original.fetchedAt)
    }

    @Test func loadScreenerReturnsNilWhenFileMissing() async {
        let (store, _) = makeTempStore()
        let restored = await store.loadScreener(templateID: "missing")
        #expect(restored == nil)
    }

    @Test func saveIsNoOpWhenPersistenceDisabled() async {
        let (store, dir) = makeTempStore(enabled: false)
        await store.saveScreener(sampleScreenerSnapshot())
        let fileURL = dir.appendingPathComponent("6676213.json")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(await store.persistenceEnabled == false)
    }

    @Test func saveCreatesDirectoryIfMissing() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoscreenerSnapshotTests-\(UUID().uuidString)")
        // Don't pre-create — verify the store does it.
        let store = ScreenerSnapshotStore(directory: dir, isEnabled: { @Sendable in true })
        await store.saveScreener(sampleScreenerSnapshot())
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func watchlistRoundTrips() async {
        let (store, _) = makeTempStore()
        let snap = WatchlistSnapshot(rows: [
            WatchlistRow(symbol: "BBCA", name: "BCA",
                         matchedScreeners: [.accumulating, .aboveMA20]),
            WatchlistRow(symbol: "BBRI", name: "BRI",
                         matchedScreeners: [.shiftToday]),
        ], fetchedAt: Date(timeIntervalSince1970: 1_780_000_000))
        await store.saveWatchlist(snap)
        let restored = await store.loadWatchlist()
        #expect(restored?.rows.count == 2)
        #expect(restored?.rows.first?.matchedScreeners == [.accumulating, .aboveMA20])
    }

    @Test func loadWatchlistReturnsNilWhenFileMissing() async {
        let (store, _) = makeTempStore()
        let restored = await store.loadWatchlist()
        #expect(restored == nil)
    }
}
