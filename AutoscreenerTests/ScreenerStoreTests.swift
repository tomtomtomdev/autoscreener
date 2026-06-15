import Foundation
import Testing
@testable import Autoscreener

@MainActor
@Suite struct ScreenerStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("screener-store-tests", isDirectory: true)
            .appendingPathComponent("cache-\(UUID().uuidString).json")
    }

    private func snapshot(_ symbols: [String], fetchedAt: Date = Date(timeIntervalSince1970: 1_000)) -> ScreenerSnapshot {
        let rows = symbols.map { ScreenerRow(symbol: $0, name: "\($0) Co", values: [1, 2], lastPrice: nil, pctChange: nil) }
        return ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: fetchedAt)
    }

    @Test func applyThenSnapshotRoundTrips() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        store.apply(snapshot(["BBCA", "BBRI"]), for: .accumulating)

        #expect(store.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA", "BBRI"])
        #expect(store.snapshot(for: .aboveMA20) == nil)
    }

    @Test func eachApplyBumpsVersion() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let v0 = store.version
        store.apply(snapshot(["A"]), for: .accumulating)
        store.apply(snapshot(["B"]), for: .aboveMA20)
        #expect(store.version == v0 + 2)
    }

    @Test func persistThenLoadRoundTripsToDisk() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = ScreenerStore(fileURL: url, loadFromDisk: false)
        writer.apply(snapshot(["BBCA"]), for: .accumulating)
        writer.apply(snapshot(["TLKM", "GOTO"]), for: .intradayLiquidity)
        writer.markSweepComplete(at: Date(timeIntervalSince1970: 5_000))

        // A fresh store pointed at the same file hydrates from disk on init.
        let reader = ScreenerStore(fileURL: url, loadFromDisk: true)
        #expect(reader.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA"])
        #expect(reader.snapshot(for: .intradayLiquidity)?.rows.map(\.symbol) == ["TLKM", "GOTO"])
        #expect(reader.lastSweepAt == Date(timeIntervalSince1970: 5_000))
    }

    @Test func loadIgnoresUnknownKindKeys() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Hand-write a cache file containing a real kind plus a bogus key.
        let snap = snapshot(["BBCA"])
        let real = try JSONEncoder().encode(snap)
        let realObj = try JSONSerialization.jsonObject(with: real)
        let model: [String: Any] = [
            "snapshots": [
                "accumulating": realObj,
                "this-kind-no-longer-exists": realObj,
            ],
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: model).write(to: url)

        let store = ScreenerStore(fileURL: url, loadFromDisk: true)
        #expect(store.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA"])
        #expect(store.snapshots.count == 1)  // bogus key dropped
    }

    @Test func corruptFileIsIgnoredAndStoreStartsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = ScreenerStore(fileURL: url, loadFromDisk: true)
        #expect(store.snapshots.isEmpty)
    }
}
