import Foundation
import Testing
@testable import Autoscreener

// MARK: - Per-factor classifiers

@Suite struct RegimeFactorClassifierTests {
    @Test func valuationCheapIsRiskOnExpensiveIsRiskOff() {
        #expect(RegimeSynthesizer.valuationSignal(percentile: 0.10) == .riskOn)   // cheap vs own history
        #expect(RegimeSynthesizer.valuationSignal(percentile: 0.50) == .neutral)
        #expect(RegimeSynthesizer.valuationSignal(percentile: 0.90) == .riskOff)  // stretched
        #expect(RegimeSynthesizer.valuationSignal(percentile: nil) == nil)        // absent
    }

    @Test func policyRateEasingIsRiskOnTighteningIsRiskOff() {
        #expect(RegimeSynthesizer.policyRateSignal(direction: .cut) == .riskOn)
        #expect(RegimeSynthesizer.policyRateSignal(direction: .hold) == .neutral)
        #expect(RegimeSynthesizer.policyRateSignal(direction: .hike) == .riskOff)
        #expect(RegimeSynthesizer.policyRateSignal(direction: nil) == nil)
    }

    @Test func foreignBuyingIsRiskOnSellingIsRiskOff() {
        #expect(RegimeSynthesizer.foreignFlowSignal(netForeign: 1_000) == .riskOn)
        #expect(RegimeSynthesizer.foreignFlowSignal(netForeign: -1_000) == .riskOff)
        #expect(RegimeSynthesizer.foreignFlowSignal(netForeign: 0) == .neutral)
        #expect(RegimeSynthesizer.foreignFlowSignal(netForeign: nil) == nil)
    }

    @Test func trendAboveTheMovingAverageIsRiskOn() {
        #expect(RegimeSynthesizer.trendSignal(distanceFrom200dma: 0.05) == .riskOn)
        #expect(RegimeSynthesizer.trendSignal(distanceFrom200dma: 0.0) == .neutral)   // on the line
        #expect(RegimeSynthesizer.trendSignal(distanceFrom200dma: -0.05) == .riskOff)
        #expect(RegimeSynthesizer.trendSignal(distanceFrom200dma: nil) == nil)
    }

    @Test func weakeningRupiahIsRiskOff() {
        // USD/IDR rising = more rupiah per dollar = rupiah weakening.
        #expect(RegimeSynthesizer.rupiahSignal(usdIdrChange: 0.03) == .riskOff)
        #expect(RegimeSynthesizer.rupiahSignal(usdIdrChange: 0.0) == .neutral)
        #expect(RegimeSynthesizer.rupiahSignal(usdIdrChange: -0.03) == .riskOn)
        #expect(RegimeSynthesizer.rupiahSignal(usdIdrChange: nil) == nil)
    }

    @Test func broadBreadthIsRiskOnNarrowIsRiskOff() {
        #expect(RegimeSynthesizer.breadthSignal(fractionAbove200dma: 0.70) == .riskOn)
        #expect(RegimeSynthesizer.breadthSignal(fractionAbove200dma: 0.50) == .neutral)
        #expect(RegimeSynthesizer.breadthSignal(fractionAbove200dma: 0.30) == .riskOff)
        #expect(RegimeSynthesizer.breadthSignal(fractionAbove200dma: nil) == nil)
    }

    @Test func risingGlobalHeadwindsAreRiskOff() {
        // Rising US yields / a strengthening dollar drain EM liquidity and pressure the
        // rupiah → risk-off. Falling → the tailwind that pulls foreign money back in.
        #expect(RegimeSynthesizer.globalHeadwindSignal(trend: .up) == .riskOff)
        #expect(RegimeSynthesizer.globalHeadwindSignal(trend: .flat) == .neutral)
        #expect(RegimeSynthesizer.globalHeadwindSignal(trend: .down) == .riskOn)
        #expect(RegimeSynthesizer.globalHeadwindSignal(trend: nil) == nil)
    }
}

// MARK: - Weighted aggregation + the late-cycle guard

@Suite struct RegimeAggregationTests {
    private func factor(_ kind: RegimeFactor.Kind, _ signal: RegimeSignal) -> RegimeFactor {
        RegimeFactor(kind: kind, signal: signal, detail: "")
    }

    /// One factor per kind, all the same signal.
    private func allFactors(_ signal: RegimeSignal) -> [RegimeFactor] {
        RegimeFactor.Kind.allCases.map { factor($0, signal) }
    }

    @Test func unanimousRiskOnReadsRiskOn() {
        let read = RegimeSynthesizer.read(factors: allFactors(.riskOn), asOf: nil)
        #expect(read.stance == .riskOn)
        #expect(read.score == 1.0)
        #expect(read.valuationCapped == false)
    }

    @Test func unanimousRiskOffReadsRiskOff() {
        #expect(RegimeSynthesizer.read(factors: allFactors(.riskOff), asOf: nil).stance == .riskOff)
    }

    @Test func unanimousNeutralReadsNeutral() {
        let read = RegimeSynthesizer.read(factors: allFactors(.neutral), asOf: nil)
        #expect(read.stance == .neutral)
        #expect(read.score == 0.0)
    }

    @Test func noFactorsReadsNeutral() {
        let read = RegimeSynthesizer.read(factors: [], asOf: "2026-01-31")
        #expect(read.stance == .neutral)
        #expect(read.score == 0.0)
        #expect(read.asOf == "2026-01-31")
    }

    @Test func valuationIsWeightedDouble() {
        // Valuation risk-off (weight 2) vs. one momentum risk-on (weight 1):
        // score = (−2 + 1) / 3 = −0.33 → risk-off. A single momentum vote cannot
        // outweigh stretched valuation.
        let read = RegimeSynthesizer.read(
            factors: [factor(.valuation, .riskOff), factor(.foreignFlow, .riskOn)], asOf: nil)
        #expect(abs(read.score - (-1.0 / 3.0)) < 1e-9)
        #expect(read.stance == .riskOff)
    }

    @Test func expensiveMarketCannotReadRiskOnEvenWithAGreenTape() {
        // The euphoric top: valuation stretched (risk-off) but every momentum/macro
        // factor screaming risk-on. Raw score (−2 + 5)/7 = +0.43 would read risk-on;
        // the Marks guard caps it at neutral.
        var factors = [factor(.valuation, .riskOff)]
        factors += [.policyRate, .foreignFlow, .trend, .rupiah, .breadth].map { factor($0, .riskOn) }
        let read = RegimeSynthesizer.read(factors: factors, asOf: nil)
        #expect(read.score > RegimeSynthesizer.Threshold.stanceBand)   // raw score says risk-on
        #expect(read.stance == .neutral)                               // …but the guard holds it back
        #expect(read.valuationCapped == true)
    }

    @Test func guardIsOneSidedCheapButCollapsingStaysRiskOff() {
        // Cheap valuation (risk-on, weight 2) but the tape is collapsing. The guard
        // only ever pulls risk-on → neutral; it must NOT lift a falling market up.
        var factors = [factor(.valuation, .riskOn)]
        factors += [.policyRate, .foreignFlow, .trend, .rupiah, .breadth].map { factor($0, .riskOff) }
        let read = RegimeSynthesizer.read(factors: factors, asOf: nil)
        #expect(read.stance == .riskOff)
        #expect(read.valuationCapped == false)
    }

    @Test func guardDoesNotFireWhenValuationIsNotStretched() {
        // Valuation neutral, tape risk-on → genuinely risk-on, no cap.
        var factors = [factor(.valuation, .neutral)]
        factors += [.policyRate, .foreignFlow, .trend, .rupiah, .breadth].map { factor($0, .riskOn) }
        let read = RegimeSynthesizer.read(factors: factors, asOf: nil)
        #expect(read.stance == .riskOn)
        #expect(read.valuationCapped == false)
    }

    @Test func degradesGracefullyWhenServerSnapshotMissing() {
        // No valuation / no BI rate (regime.json absent): the read is built from the
        // live factors alone and still produces a stance.
        let live: [RegimeFactor] = [.foreignFlow, .trend, .rupiah, .breadth].map { factor($0, .riskOn) }
        let read = RegimeSynthesizer.read(factors: live, asOf: nil)
        #expect(read.stance == .riskOn)
        #expect(read.factors.contains { $0.kind == .valuation } == false)
    }
}

// MARK: - regime.json contract

@Suite struct RegimeSnapshotDecodeTests {
    // The draft contract from idx-regime-data-research.md §6, verbatim.
    static let json = Data(#"""
    { "asOf": "2026-01-31",
      "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
      "indices": {
        "COMPOSITE": { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 },
        "LQ45":      { "pe": 12.1, "pb": 1.9, "pePctile": 0.38, "pbPctile": 0.49 }
      } }
    """#.utf8)

    @Test func decodesTheContract() throws {
        let snap = try JSONDecoder().decode(RegimeSnapshot.self, from: Self.json)
        #expect(snap.asOf == "2026-01-31")
        #expect(snap.biRate?.value == 4.75)
        #expect(snap.biRate?.direction == .cut)
        #expect(snap.biRate?.asOf == "2026-01-15")
        #expect(snap.composite?.pe == 13.2)
        #expect(snap.composite?.pePctile == 0.42)
        #expect(snap.indices["LQ45"]?.pbPctile == 0.49)
    }

    // The `macro` block (global-rates anchor) the scraper now emits alongside biRate.
    static let withMacro = Data(#"""
    { "asOf": "2026-05-31",
      "biRate": { "value": 5.25, "direction": "cut", "asOf": "2026-05-20" },
      "macro": {
        "usFedFunds":  { "value": 4.33,  "trend": "down", "asOf": "2026-06-10" },
        "us10y":       { "value": 4.30,  "trend": "up",   "asOf": "2026-06-10" },
        "broadDollar": { "value": 121.5, "trend": "up",   "asOf": "2026-06-10" }
      },
      "indices": { "COMPOSITE": { "pe": 13.2, "pb": 2.1, "pePctile": 0.42, "pbPctile": 0.55 } } }
    """#.utf8)

    @Test func decodesTheMacroBlock() throws {
        let snap = try JSONDecoder().decode(RegimeSnapshot.self, from: Self.withMacro)
        #expect(snap.macro?.us10y?.value == 4.30)
        #expect(snap.macro?.us10y?.trend == .up)
        #expect(snap.macro?.broadDollar?.value == 121.5)
        #expect(snap.macro?.broadDollar?.trend == .up)
        #expect(snap.macro?.usFedFunds?.trend == .down)
    }

    @Test func macroIsNilWhenAbsentFromContract() throws {
        // The pre-macro contract (no `macro` key) still decodes — backward compatible.
        let snap = try JSONDecoder().decode(RegimeSnapshot.self, from: Self.json)
        #expect(snap.macro == nil)
    }

    @Test func compositeValuationPercentileAveragesPeAndPb() throws {
        let snap = try JSONDecoder().decode(RegimeSnapshot.self, from: Self.json)
        // (0.42 + 0.55) / 2 = 0.485
        #expect(abs(snap.composite!.valuationPercentile! - 0.485) < 1e-9)
    }

    @Test func valuationPercentileFallsBackToWhicheverIsPresent() {
        let onlyPE = RegimeSnapshot.IndexValuation(pe: nil, pb: nil, pePctile: 0.30, pbPctile: nil)
        #expect(onlyPE.valuationPercentile == 0.30)
        let neither = RegimeSnapshot.IndexValuation(pe: 1, pb: 1, pePctile: nil, pbPctile: nil)
        #expect(neither.valuationPercentile == nil)
    }

    // Verbatim output of `tools/idx-regime-scraper` (its `build`): extra `SECTOR:*`
    // index keys and a loss-making sector with a null P/E. Proves the app consumes
    // the scraper's real shape — the two halves of the regime read agree.
    static let scraperOutput = Data(#"""
    { "asOf": "2026-01-31",
      "biRate": { "value": 4.75, "direction": "cut", "asOf": "2026-01-15" },
      "indices": {
        "COMPOSITE":  { "pe": 13.33, "pb": 2.09, "pePctile": 0.42, "pbPctile": 0.55 },
        "SECTOR:FIN": { "pe": 13.33, "pb": 2.67, "pePctile": 1.0,  "pbPctile": 1.0 },
        "SECTOR:ENE": { "pe": null,  "pb": 1.0,  "pePctile": null, "pbPctile": 1.0 },
        "LQ45":       { "pe": 10.0,  "pb": 1.56, "pePctile": 0.38, "pbPctile": 0.49 }
      } }
    """#.utf8)

    @Test func decodesTheScraperOutputAndIgnoresSectorKeys() throws {
        let snap = try JSONDecoder().decode(RegimeSnapshot.self, from: Self.scraperOutput)
        #expect(snap.composite?.pe == 13.33)
        #expect(snap.indices["LQ45"]?.pePctile == 0.38)
        #expect(snap.indices["SECTOR:ENE"]?.pe == nil)        // loss-making sector
        #expect(snap.indices["SECTOR:ENE"]?.pbPctile == 1.0)  // …but P/B still ranks
    }
}
