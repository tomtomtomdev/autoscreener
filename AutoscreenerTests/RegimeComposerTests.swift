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

    @Test func fixtureBIRateHikeTipsTheDocumentedMixToRiskOff() {
        // The `-UITestFixtures` snapshot now carries the live BI rate (5.50%, a hike →
        // risk-off) instead of the stale 4.75/cut. Combined with the deterministic mix
        // `RegimeUITests` drives — neutral valuation, net foreign selling, a weakening
        // rupiah, soft LQ45 breadth, softened only by a falling US 10y — the read nets
        // to Risk-off. Regression guard: the old cut value read Neutral and masked the
        // tightening, which is exactly the bug this fixes. Display-independent, so it
        // verifies the stance even where the XCUITest skips on a multi-display setup.
        let mixConstituents = ["BBCA", "TLKM", "BMRI", "ASII", "UNVR"]
        let read = RegimeComposer.compose(
            snapshot: UITestFixtures.regimeSnapshot,
            flow: UITestFixtures.foreignFlow(symbol: "IHSG"),   // net selling → risk-off
            ihsg: nil, sp500: nil,                              // <200 candles at runtime → absent
            usdIdrChangePercent: 2.04,                          // rupiah weakening → risk-off
            aboveSnapshot: above200MA(["BBCA"]),                // 1 of 5 → <40% → risk-off
            constituents: mixConstituents)

        #expect(read?.factors.first { $0.kind == .policyRate }?.signal == .riskOff)
        #expect(read?.stance == .riskOff)
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

    @Test func threadsForeignParticipationShareFromTheFlowValueBreakdown() {
        // The foreign/domestic split is already fetched every sweep, but compose only
        // read `netForeign`. At the IHSG aggregate netDomestic ≡ −netForeign (every
        // foreign buy is a domestic sell), so the *non-redundant* datum to surface is
        // the foreign share of turnover — how much of the tape foreigners are driving.
        // The fixture's value breakdown is 50.99% foreign → "51% of turnover".
        let read = RegimeComposer.compose(
            snapshot: nil,
            flow: UITestFixtures.foreignFlow(symbol: "IHSG"),
            ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil,
            aboveSnapshot: nil,
            constituents: constituents)

        let detail = read?.factors.first { $0.kind == .foreignFlow }?.detail
        #expect(detail?.contains("foreigners 51% of turnover") == true)
    }

    @Test func divergenceBreadthVotesOnTheBroadKompasUniverse() {
        // Both index memberships supplied: the leaders (LQ45) are all above their 200dma
        // but the broader KOMPAS100 has rolled over (3 of 10). The breadth factor is built
        // from the SAME .above200MA snapshot for both, votes on the broad market → risk-off,
        // and names both universes in the detail. The narrowing late-cycle tell.
        let kompas = constituents + ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG"]   // 10 names
        let read = RegimeComposer.compose(
            snapshot: nil,
            flow: nil, ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil,
            aboveSnapshot: above200MA(constituents),     // all 3 LQ45 above; none of the extras
            constituents: constituents,
            kompasConstituents: kompas)

        let breadth = read?.factors.first { $0.kind == .breadth }
        #expect(breadth?.signal == .riskOff)             // 3/10 KOMPAS100 = 30% → weak
        #expect(breadth?.detail == "KOMPAS100 30% vs LQ45 100% above their 200-day average — narrowing")
    }

    @Test func threadsTheChinaChannelFactorWhenSupplied() {
        // The coordinator builds the reading from the priced quotes and hands it in; the composer
        // just threads it to the factor builder, yielding the China-channel factor in the read.
        let read = RegimeComposer.compose(
            snapshot: nil, flow: nil, ihsg: nil, sp500: nil,
            usdIdrChangePercent: nil, aboveSnapshot: nil,
            constituents: constituents,
            commodityChannel: CommodityChannelReading(
                basketChangePercent: 2.0, contributors: ["coal", "nickel"], cnyChangePercent: nil))

        let factor = read?.factors.first { $0.kind == .commodityChannel }
        #expect(factor?.signal == .riskOn)                                  // +2.0% > 1.5% band
        #expect(factor?.detail.contains("Export basket +2.00% (coal/nickel)") == true)
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
