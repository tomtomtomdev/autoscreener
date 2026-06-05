import Foundation
import Testing
@testable import Autoscreener

@Suite struct RegimeFactorBuilderTests {
    private static let snapshot = RegimeSnapshot(
        asOf: "2026-01-31",
        biRate: RegimeSnapshot.BIRate(value: 4.75, direction: .cut, asOf: "2026-01-15"),
        indices: ["COMPOSITE": RegimeSnapshot.IndexValuation(pe: 13.2, pb: 2.1, pePctile: 0.10, pbPctile: 0.10)])

    private func signal(_ factors: [RegimeFactor], _ kind: RegimeFactor.Kind) -> RegimeSignal? {
        factors.first { $0.kind == kind }?.signal
    }

    @Test func buildsAllSixFactorsWhenEveryInputIsPresent() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot,
            netForeignRaw: 1_200_000_000_000, netForeignText: "1.20 T",
            ihsgDistanceFrom200dma: 0.04,
            usdIdrChangePercent: -1.8,            // USD/IDR down → rupiah strengthening
            breadth: BreadthReading(above: 30, measured: 45))

        #expect(Set(factors.map(\.kind)) == Set(RegimeFactor.Kind.allCases))
        #expect(signal(factors, .valuation) == .riskOn)    // 10th pctile → cheap
        #expect(signal(factors, .policyRate) == .riskOn)    // cut
        #expect(signal(factors, .foreignFlow) == .riskOn)   // net buy
        #expect(signal(factors, .trend) == .riskOn)         // above 200dma
        #expect(signal(factors, .rupiah) == .riskOn)        // strengthening
        #expect(signal(factors, .breadth) == .riskOn)       // 67% > MA
    }

    @Test func dropsServerFactorsWhenSnapshotMissing() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil,
            netForeignRaw: -360_000_000_000, netForeignText: "-360.70 B",
            ihsgDistanceFrom200dma: -0.05,
            usdIdrChangePercent: 2.0,
            breadth: BreadthReading(above: 10, measured: 45))

        #expect(factors.contains { $0.kind == .valuation } == false)
        #expect(factors.contains { $0.kind == .policyRate } == false)
        #expect(signal(factors, .foreignFlow) == .riskOff)
        #expect(signal(factors, .trend) == .riskOff)
        #expect(signal(factors, .rupiah) == .riskOff)       // USD/IDR up → weakening
        #expect(signal(factors, .breadth) == .riskOff)      // 22% > MA
    }

    @Test func foreignSellDetailNamesTheSideAndDropsTheMinus() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: -360_000_000_000, netForeignText: "-360.70 B",
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        let detail = factors.first { $0.kind == .foreignFlow }?.detail
        #expect(detail == "Net foreign sell 360.70 B")
    }

    @Test func detailsCarryTheDrivingFigures() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: 0.032, usdIdrChangePercent: nil,
            breadth: BreadthReading(above: 28, measured: 45))
        #expect(factors.first { $0.kind == .policyRate }?.detail.contains("BI rate 4.75%") == true)
        #expect(factors.first { $0.kind == .trend }?.detail.contains("200-day average") == true)
        #expect(factors.first { $0.kind == .breadth }?.detail.contains("of 45 LQ45") == true)
    }

    @Test func emptyWhenNothingAvailable() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        #expect(factors.isEmpty)
    }
}
