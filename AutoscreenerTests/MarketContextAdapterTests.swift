import Foundation
import Testing
@testable import Autoscreener

// Phase 1.7 (§8 / §3): the pure adapter that re-packs the seven raw regime inputs the app already
// gathers (`RegimeFactorBuilder.factors` consumes the same set) into the engine's `MarketContext`.
// Pins the sign conventions (rising USD/IDR ⇒ rupiah weakening, hike ⇒ rate rising, distance ≥ 0 ⇒
// above trend, negative net ⇒ outflow, positive commodity move ⇒ tailwind) and the neutral
// degradation policy for absent inputs (never fabricate a false risk-on read).

@Suite struct MarketContextAdapterTests {

    /// A composite-valuation + BI-rate snapshot. `valuationPercentile: nil` models "snapshot
    /// published but the composite carries no percentile yet"; `rate: nil` models "no BI rate".
    private func snapshot(valuationPercentile: Double?, rate: BIRateDirection?) -> RegimeSnapshot {
        let composite = RegimeSnapshot.IndexValuation(
            pe: nil, pb: nil, pePctile: valuationPercentile, pbPctile: nil)
        let biRate = rate.map { RegimeSnapshot.BIRate(value: 5.75, direction: $0, asOf: "2026-06-01") }
        return RegimeSnapshot(
            asOf: "2026-06-01", biRate: biRate, macro: nil,
            indices: [RegimeSnapshot.compositeKey: composite])
    }

    /// Calls the adapter with all-absent defaults so each test overrides only the inputs it exercises.
    private func ctx(
        snapshot: RegimeSnapshot? = nil,
        flow: Double? = nil,
        distance: Double? = nil,
        usdIdr: Double? = nil,
        breadth: BreadthReading? = nil,
        commodity: Double? = nil,
        bondFlow: Double? = nil
    ) -> MarketContext {
        SelectionFundamentals.marketContext(
            snapshot: snapshot,
            marketForeignFlowNet: flow,
            ihsgDistanceFrom200dma: distance,
            usdIdrChangePercent: usdIdr,
            breadth: breadth,
            commodityChangePercent: commodity,
            bondFlowChangePercent: bondFlow)
    }

    @Test func mapsAllSevenRegimeInputsWhenPresent() {
        let c = ctx(
            snapshot: snapshot(valuationPercentile: 0.42, rate: .hike),
            flow: -1_500_000_000,                              // net foreign sell
            distance: 0.08,                                    // IHSG 8% above its 200-day
            usdIdr: 0.35,                                      // USD/IDR up → rupiah weaker
            breadth: BreadthReading(above: 30, measured: 40),  // 75% above their 200-day
            commodity: 1.2)                                    // relevant commodity up → tailwind
        #expect(c.indexValuationPercentile == 0.42)
        #expect(c.breadthAbove200dma == 0.75)
        #expect(c.indexAbove200dma == true)
        #expect(c.idrWeakeningTrend == true)
        #expect(c.biRateRising == true)
        #expect(c.marketForeignFlowNet < 0)
        #expect(c.commodityTailwind == true)
    }

    @Test func mapsTheRiskOnMirrorOfEachSignal() {
        let c = ctx(
            snapshot: snapshot(valuationPercentile: 0.20, rate: .cut),
            flow: 2_000_000_000,                               // net foreign buy
            distance: -0.05,                                   // below its 200-day
            usdIdr: -0.40,                                     // rupiah strengthening
            breadth: BreadthReading(above: 10, measured: 40),  // 25%
            commodity: -0.8)                                   // commodity down → no tailwind
        #expect(c.indexValuationPercentile == 0.20)
        #expect(c.breadthAbove200dma == 0.25)
        #expect(c.indexAbove200dma == false)
        #expect(c.idrWeakeningTrend == false)
        #expect(c.biRateRising == false)
        #expect(c.marketForeignFlowNet > 0)
        #expect(c.commodityTailwind == false)
    }

    // MARK: - Boundary conventions

    @Test func indexExactlyAtItsTrendCountsAsAbove() {
        #expect(ctx(distance: 0).indexAbove200dma == true)     // distance ≥ 0
    }

    @Test func flatMovesAreNotStressNorTailwind() {
        let c = ctx(usdIdr: 0, commodity: 0)
        #expect(c.idrWeakeningTrend == false)                  // strictly > 0 weakens
        #expect(c.commodityTailwind == false)                  // strictly > 0 is a tailwind
    }

    @Test func zeroForeignFlowIsNotAnOutflow() {
        #expect(ctx(flow: 0).marketForeignFlowNet == 0)
    }

    @Test func foreignBondOutflowIsFlaggedOnlyBeyondTheHalfPercentBand() {
        // The MTD move must clear the displayed factor's ±0.5% band to count as bond-side flight,
        // so noise inside the band — and accumulation — reads as no outflow.
        #expect(ctx(bondFlow: -1.8).bondFlowOutflow == true)    // clearly distributing
        #expect(ctx(bondFlow: -0.2).bondFlowOutflow == false)   // inside the band → noise
        #expect(ctx(bondFlow: 1.2).bondFlowOutflow == false)    // accumulating
        #expect(ctx(bondFlow: -0.5).bondFlowOutflow == false)   // exactly the band edge (strict <)
    }

    @Test func biRateHoldIsNotRising() {
        let c = ctx(snapshot: snapshot(valuationPercentile: 0.5, rate: .hold))
        #expect(c.biRateRising == false)
    }

    // MARK: - Degradation policy (absent inputs → neutral / no-evidence)

    @Test func absentInputsDefaultToNeutralNoEvidence() {
        let c = ctx()   // every input nil
        #expect(c.indexValuationPercentile == 0.5)
        #expect(c.breadthAbove200dma == 0.5)
        #expect(c.indexAbove200dma == false)
        #expect(c.idrWeakeningTrend == false)
        #expect(c.biRateRising == false)
        #expect(c.marketForeignFlowNet == 0)
        #expect(c.commodityTailwind == false)
        #expect(c.bondFlowOutflow == false)   // absent bond-flow reading ⇒ no fabricated risk
    }

    @Test func unmeasurableBreadthAndUnpublishedValuationFallToNeutralMidpoint() {
        // Snapshot present but its composite has no percentile yet; breadth measured nothing.
        let c = ctx(
            snapshot: snapshot(valuationPercentile: nil, rate: .hike),
            breadth: BreadthReading(above: 0, measured: 0))
        #expect(c.indexValuationPercentile == 0.5)
        #expect(c.breadthAbove200dma == 0.5)
        #expect(c.biRateRising == true)   // the rate leg still reads even when valuation is absent
    }
}
