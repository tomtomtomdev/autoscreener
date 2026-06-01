import Foundation
import Testing
@testable import Autoscreener

/// In-memory snapshot store for ViewModel tests. Bypasses filesystem.
final class FakeSnapshotStore: ScreenerSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var screenerByID: [String: ScreenerSnapshot] = [:]
    private var watchlist: WatchlistSnapshot?
    var enabled: Bool = true

    func seedScreener(_ snap: ScreenerSnapshot) {
        lock.lock(); screenerByID[snap.templateID] = snap; lock.unlock()
    }

    func seedWatchlist(_ snap: WatchlistSnapshot) {
        lock.lock(); watchlist = snap; lock.unlock()
    }

    var persistenceEnabled: Bool { get async { enabled } }

    func loadScreener(templateID: String) async -> ScreenerSnapshot? {
        lock.lock(); defer { lock.unlock() }; return screenerByID[templateID]
    }

    func saveScreener(_ snapshot: ScreenerSnapshot) async {
        guard enabled else { return }
        lock.lock(); screenerByID[snapshot.templateID] = snapshot; lock.unlock()
    }

    func loadWatchlist() async -> WatchlistSnapshot? {
        lock.lock(); defer { lock.unlock() }; return watchlist
    }

    func saveWatchlist(_ snapshot: WatchlistSnapshot) async {
        guard enabled else { return }
        lock.lock(); watchlist = snapshot; lock.unlock()
    }
}

@MainActor
@Suite struct ScreenerViewModelSnapshotTests {
    private func sampleSnapshot(templateID: String = "6676213") -> ScreenerSnapshot {
        var config = ScreenerConfig()
        config.screenerID = templateID
        config.sequence = [14399, 14426]
        return ScreenerSnapshot(
            templateID: templateID,
            config: config,
            rows: [
                ScreenerRow(symbol: "BBCA", name: "BCA",
                            values: [100, 200], lastPrice: nil, pctChange: nil),
                ScreenerRow(symbol: "BBRI", name: "BRI",
                            values: [50, 75], lastPrice: nil, pctChange: nil),
            ],
            total: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private final class CountingService: ScreenerServicing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: Int = 0
        func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
            lock.lock(); calls += 1; lock.unlock()
            return ScreenerPage(rows: [], total: 0, page: page)
        }
    }

    private final class CountingTemplates: ScreenerTemplateServicing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: Int = 0
        func load(templateID: String) async throws -> ScreenerInitialResult {
            lock.lock(); calls += 1; lock.unlock()
            var config = ScreenerConfig()
            config.screenerID = templateID
            return ScreenerInitialResult(
                config: config,
                page: ScreenerPage(rows: [], total: 0, page: 1))
        }
    }

    @Test func autoRunRendersSnapshotAndSkipsTemplateLoad() async {
        let store = FakeSnapshotStore()
        store.seedScreener(sampleSnapshot())
        let templates = CountingTemplates()
        let service = CountingService()
        let vm = ScreenerViewModel(
            service: service,
            paywall: nil,
            templates: templates,
            snapshots: store,
            templateID: "6676213")

        await vm.autoRunIfNeeded()

        // Snapshot was applied — rows visible without any network calls.
        #expect(vm.rows.count == 2)
        #expect(vm.rows.first?.symbol == "BBCA")
        #expect(vm.lastFetchedAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(templates.calls == 0)
        #expect(service.calls == 0)
        // Restored snapshots are treated as a complete page → no auto-load-more.
        #expect(vm.hasMore == false)
    }

    @Test func autoRunWithoutSnapshotFallsThroughToTemplateLoad() async {
        let store = FakeSnapshotStore()  // empty
        let templates = CountingTemplates()
        let vm = ScreenerViewModel(
            service: CountingService(),
            paywall: nil,
            templates: templates,
            snapshots: store,
            templateID: "6676213")

        await vm.autoRunIfNeeded()

        #expect(templates.calls == 1)
        // After the call, snapshot should have been written.
        let saved = await store.loadScreener(templateID: "6676213")
        #expect(saved != nil)
    }

    @Test func refreshWritesNewSnapshotWhenPersistenceEnabled() async {
        let store = FakeSnapshotStore()
        let vm = ScreenerViewModel(
            service: CountingService(),
            paywall: nil,
            templates: CountingTemplates(),
            snapshots: store,
            templateID: "6676213")
        await vm.refresh()
        let saved = await store.loadScreener(templateID: "6676213")
        #expect(saved?.templateID == "6676213")
    }

    @Test func refreshWritesNothingWhenPersistenceDisabled() async {
        let store = FakeSnapshotStore()
        store.enabled = false
        let vm = ScreenerViewModel(
            service: CountingService(),
            paywall: nil,
            templates: CountingTemplates(),
            snapshots: store,
            templateID: "6676213")
        await vm.refresh()
        let saved = await store.loadScreener(templateID: "6676213")
        #expect(saved == nil)
    }
}
