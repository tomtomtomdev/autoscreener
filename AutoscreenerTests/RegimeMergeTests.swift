import Foundation
import Testing
@testable import Autoscreener

// MARK: - Fakes

/// Returns a fixed BI rate and counts how many times it was actually fetched, so the
/// daily-staleness guard can be asserted.
final class FakeBIRateProvider: BIRateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let value: RegimeSnapshot.BIRate?
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(_ value: RegimeSnapshot.BIRate?) { self.value = value }
    func biRate() async -> RegimeSnapshot.BIRate? {
        lock.lock(); _calls += 1; lock.unlock(); return value
    }
}

final class FakeMacroProvider: FREDMacroProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let value: RegimeSnapshot.MacroBlock?
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    init(_ value: RegimeSnapshot.MacroBlock?) { self.value = value }
    func macro() async -> RegimeSnapshot.MacroBlock? {
        lock.lock(); _calls += 1; lock.unlock(); return value
    }
}

/// Serves a fixed published snapshot (or 404s when `nil`), standing in for the
/// `regime.json` GET so the merge can be exercised deterministically.
struct FixedSnapshotService: RegimeSnapshotProviding {
    let snap: RegimeSnapshot?
    func snapshot() async throws -> RegimeSnapshot {
        guard let snap else { throw RegimeSnapshotError.notFound }
        return snap
    }
}

/// A mutable clock backing for the TTL test.
final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock() }
}

// MARK: - Tests

@MainActor
@Suite struct RegimeMergeTests {
    static func snapshot(biRate: RegimeSnapshot.BIRate?, withValuation: Bool = true) -> RegimeSnapshot {
        RegimeSnapshot(
            asOf: "2026-01-31", biRate: biRate, macro: nil,
            indices: withValuation
                ? ["COMPOSITE": RegimeSnapshot.IndexValuation(pe: 13.2, pb: 2.1, pePctile: 0.42, pbPctile: 0.55)]
                : [:])
    }

    private func policyFactor(_ store: MarketDataStore) -> RegimeFactor? {
        store.regimeRead?.factors.first { $0.kind == .policyRate }
    }

    @Test func nativeBIRateOverridesPublished() async {
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            snapshotProvider: FixedSnapshotService(snap: Self.snapshot(
                biRate: .init(value: 4.00, direction: .cut, asOf: "2026-01-15"))),
            biRateProvider: FakeBIRateProvider(.init(value: 6.00, direction: .hike, asOf: "2026-06-09")),
            macroProvider: FakeMacroProvider(nil),
            catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)

        let policy = policyFactor(marketStore)
        #expect(policy?.detail.contains("6.00%") == true)   // device value, not 4.00
        #expect(policy?.detail.contains("hike") == true)
    }

    @Test func fallsBackToPublishedBIRateWhenNativeUnavailable() async {
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            snapshotProvider: FixedSnapshotService(snap: Self.snapshot(
                biRate: .init(value: 4.00, direction: .cut, asOf: "2026-01-15"))),
            biRateProvider: FakeBIRateProvider(nil),
            macroProvider: FakeMacroProvider(nil),
            catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)

        #expect(policyFactor(marketStore)?.detail.contains("4.00%") == true)  // published fallback
    }

    @Test func dropsPolicyFactorWhenNeitherSourceHasIt() async {
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            snapshotProvider: FixedSnapshotService(snap: Self.snapshot(biRate: nil)),
            biRateProvider: FakeBIRateProvider(nil),
            macroProvider: FakeMacroProvider(nil),
            catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)

        #expect(policyFactor(marketStore) == nil)                                  // dropped
        #expect(marketStore.regimeRead?.factors.contains { $0.kind == .valuation } == true)  // still reads
    }

    @Test func reusesCachedMacroWithinTTL() async {
        let bi = FakeBIRateProvider(.init(value: 6.00, direction: .hike, asOf: "2026-06-09"))
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: SweepTestKit.marketStore(),
            snapshotProvider: FixedSnapshotService(snap: Self.snapshot(biRate: nil)),
            biRateProvider: bi, macroProvider: FakeMacroProvider(nil),
            catalog: SweepTestKit.mixedCatalog)  // fixed clock → no time passes between sweeps

        await coord.runSweep(includeIDX: true)
        await coord.runSweep(includeIDX: true)

        #expect(bi.calls == 1)  // second sweep within TTL reused the cache
    }

    @Test func refetchesMacroAfterTTL() async {
        let timeBox = TimeBox(SweepTestKit.jakarta(2026, 6, 11, 10, 0))
        let bi = FakeBIRateProvider(.init(value: 6.00, direction: .hike, asOf: "2026-06-09"))
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: SweepTestKit.marketStore(),
            snapshotProvider: FixedSnapshotService(snap: Self.snapshot(biRate: nil)),
            biRateProvider: bi, macroProvider: FakeMacroProvider(nil),
            catalog: SweepTestKit.mixedCatalog,
            clock: MarketClock(now: { timeBox.now }),
            macroTTL: 1)

        await coord.runSweep(includeIDX: true)
        timeBox.advance(2)  // past the 1s TTL
        await coord.runSweep(includeIDX: true)

        #expect(bi.calls == 2)
    }
}
