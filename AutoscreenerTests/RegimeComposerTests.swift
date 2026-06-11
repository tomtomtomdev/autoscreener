import Foundation
import Testing
@testable import Autoscreener

/// The regime composition contract, lifted out of `RegimeViewModel` into the pure
/// `RegimeComposer` the coordinator calls. Inputs are passed directly (no services),
/// so the factor-presence and graceful-degradation behaviour is testable without I/O.
@MainActor
@Suite struct RegimeComposerTests {
    private func above200MA(_ symbols: [String]) -> ScreenerSnapshot {
        let rows = symbols.map { ScreenerRow(symbol: $0, name: "\($0) Co", values: [1], lastPrice: nil, pctChange: nil) }
        return ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: Date(timeIntervalSince1970: 1_000))
    }

    private let constituents = ["BBCA", "TLKM", "BMRI"]

    @Test func composesAReadFromTheAvailableInputs() {
        let read = RegimeComposer.compose(
            snapshot: UITestFixtures.regimeSnapshot,
            flow: UITestFixtures.foreignFlow(symbol: "IHSG"),
            ihsg: nil,                              // < 200 days elsewhere → trend factor absent here
            sp500: nil,
            usdIdrChangePercent: 2.04,
            aboveSnapshot: above200MA(["BBCA", "TLKM"]),
            constituents: constituents)

        #expect(read != nil)
        #expect(read?.factors.contains { $0.kind == .valuation } == true)   // from the snapshot
        #expect(read?.factors.contains { $0.kind == .breadth } == true)     // derived from .above200MA
        #expect(read?.factors.contains { $0.kind == .foreignFlow } == true)
        #expect(read?.factors.contains { $0.kind == .trend } == false)      // no IHSG series
        #expect(read?.asOf == "2026-01-31")
    }

    @Test func returnsNilWhenNoInputProducesAFactor() {
        let read = RegimeComposer.compose(
            snapshot: nil, flow: nil, ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil, aboveSnapshot: nil, constituents: constituents)
        #expect(read == nil)
    }

    @Test func degradesToLiveFactorsWhenTheSnapshotIsUnavailable() {
        // regime.json not published yet — no valuation / BI-rate factors, but the live
        // legs (foreign flow + derived breadth) still produce a read.
        let read = RegimeComposer.compose(
            snapshot: nil,
            flow: UITestFixtures.foreignFlow(symbol: "IHSG"),
            ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil,
            aboveSnapshot: above200MA(["BBCA", "TLKM", "BMRI"]),
            constituents: constituents)

        #expect(read != nil)
        #expect(read?.factors.contains { $0.kind == .valuation } == false)
        #expect(read?.factors.contains { $0.kind == .policyRate } == false)
        #expect(read?.factors.contains { $0.kind == .breadth } == true)
    }

    @Test func breadthFactorAbsentWithoutAScreenerSnapshot() {
        let read = RegimeComposer.compose(
            snapshot: UITestFixtures.regimeSnapshot,
            flow: nil, ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil,
            aboveSnapshot: nil,                     // sweep hasn't collected .above200MA yet
            constituents: constituents)

        #expect(read != nil)                        // valuation/BI rate still produce a read
        #expect(read?.factors.contains { $0.kind == .breadth } == false)
    }
}
