import Foundation
import Testing
@testable import Autoscreener

// The disk-backed display cache behind the Recommendations cold-start fallback: the last shown inbox
// (ranked picks + Gate-5 verdicts + skip note + "as of close" stamp). These pin its persistence
// contract — round-trip through disk, the loadFromDisk gate, corrupt-file tolerance, and last-write-wins
// — independent of the ViewModel that drives it.

@Suite @MainActor struct RecommendationsSnapshotStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-snapshot-tests", isDirectory: true)
            .appendingPathComponent("cache-\(UUID().uuidString).json")
    }

    private func rec(_ ticker: Ticker, iv: Double = 1_000) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: 0.5, intrinsicValue: iv,
                       marginOfSafety: 0.25, conviction: 0.6, suggestedWeight: 0.05,
                       audit: ["→ conviction 0.60 weight 5%"])
    }
    private func dec(_ ticker: Ticker, _ action: ExitAction) -> ExitDecision {
        ExitDecision(ticker: ticker, action: action, reason: "r", audit: ["review \(ticker)"])
    }

    @Test func startsEmptyWhenPersistenceIsOff() {
        let store = RecommendationsSnapshotStore(fileURL: nil, loadFromDisk: false)
        #expect(store.snapshot.isEmpty)
        #expect(store.snapshot.recommendations.isEmpty)
        #expect(store.snapshot.decisions.isEmpty)
        #expect(store.snapshot.asOf == nil)
    }

    @Test func saveThenLoadRoundTripsTheInboxThroughDisk() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asOf = Date(timeIntervalSince1970: 1_700_000_000)

        let writer = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: false)
        writer.save(.init(recommendations: [rec("BBCA", iv: 9_500)],
                          decisions: [dec("WIFI", .hold), dec("TLKM", .exit)],
                          skipped: [SkippedName(ticker: "BAD", reason: "no price")],
                          asOf: asOf))

        let reader = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: true)
        #expect(reader.snapshot.recommendations.map(\.ticker) == ["BBCA"])
        #expect(reader.snapshot.recommendations.first?.intrinsicValue == 9_500)
        #expect(reader.snapshot.decisions.map(\.ticker) == ["WIFI", "TLKM"])
        #expect(reader.snapshot.decisions.first?.action == .hold)
        #expect(reader.snapshot.skipped.map(\.ticker) == ["BAD"])
        #expect(reader.snapshot.asOf == asOf)
    }

    @Test func loadFromDiskFalseIgnoresAnExistingFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        RecommendationsSnapshotStore(fileURL: url, loadFromDisk: false)
            .save(.init(recommendations: [rec("BBCA")]))

        // A second store told NOT to load starts empty even though the file exists.
        let store = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: false)
        #expect(store.snapshot.isEmpty)
    }

    @Test func corruptFileIsIgnoredAndStartsEmpty() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: true)
        #expect(store.snapshot.isEmpty)
    }

    @Test func aLaterSaveSupersedesThePreviousInbox() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: false)
        writer.save(.init(recommendations: [rec("WIFI"), rec("BBCA")]))
        writer.save(.init(recommendations: [rec("TLKM")]))   // a fresh run fully replaces the old one

        let reader = RecommendationsSnapshotStore(fileURL: url, loadFromDisk: true)
        #expect(reader.snapshot.recommendations.map(\.ticker) == ["TLKM"])
    }
}
