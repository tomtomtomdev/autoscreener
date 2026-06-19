import Foundation
import Testing
@testable import Autoscreener

@Suite struct RegimeFactorBuilderTests {
    private static let snapshot = RegimeSnapshot(
        asOf: "2026-01-31",
        biRate: RegimeSnapshot.BIRate(value: 4.75, direction: .cut, asOf: "2026-01-15"),
        macro: RegimeSnapshot.MacroBlock(
            usFedFunds: RegimeSnapshot.MacroSeries(value: 4.33, trend: .down, asOf: "2026-01-31"),
            us10y: RegimeSnapshot.MacroSeries(value: 4.10, trend: .down, asOf: "2026-01-31"),
            broadDollar: RegimeSnapshot.MacroSeries(value: 119.0, trend: .down, asOf: "2026-01-31")),
        indices: ["COMPOSITE": RegimeSnapshot.IndexValuation(pe: 13.2, pb: 2.1, pePctile: 0.10, pbPctile: 0.10)])

    private func signal(_ factors: [RegimeFactor], _ kind: RegimeFactor.Kind) -> RegimeSignal? {
        factors.first { $0.kind == kind }?.signal
    }

    @Test func buildsEveryFactorWhenEveryInputIsPresent() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot,
            netForeignRaw: 1_200_000_000_000, netForeignText: "1.20 T",
            ihsgDistanceFrom200dma: 0.04,
            sp500DistanceFrom200dma: 0.06,        // S&P 500 above its 200dma
            usdIdrChangePercent: -1.8,            // USD/IDR down → rupiah strengthening
            breadth: BreadthReading(above: 30, measured: 45))

        #expect(Set(factors.map(\.kind)) == Set(RegimeFactor.Kind.allCases))
        #expect(signal(factors, .valuation) == .riskOn)    // 10th pctile → cheap
        #expect(signal(factors, .policyRate) == .riskOn)    // cut
        #expect(signal(factors, .usRates) == .riskOn)       // US 10y trending down
        #expect(signal(factors, .globalDollar) == .riskOn)  // broad dollar trending down
        #expect(signal(factors, .globalEquities) == .riskOn) // S&P 500 above 200dma
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
        #expect(factors.contains { $0.kind == .usRates } == false)       // macro is in the snapshot
        #expect(factors.contains { $0.kind == .globalDollar } == false)
        #expect(signal(factors, .foreignFlow) == .riskOff)
        #expect(signal(factors, .trend) == .riskOff)
        #expect(signal(factors, .rupiah) == .riskOff)       // USD/IDR up → weakening
        #expect(signal(factors, .breadth) == .riskOff)      // 22% > MA
    }

    @Test func dropsGlobalFactorsWhenMacroBlockAbsentButSnapshotPresent() {
        // A pre-macro snapshot (biRate + indices, no macro) still yields the server
        // valuation/rate factors but not the US-rates/dollar ones.
        let noMacro = RegimeSnapshot(
            asOf: "2026-01-31",
            biRate: RegimeSnapshot.BIRate(value: 4.75, direction: .cut, asOf: "2026-01-15"),
            macro: nil,
            indices: ["COMPOSITE": RegimeSnapshot.IndexValuation(pe: 13.2, pb: 2.1, pePctile: 0.10, pbPctile: 0.10)])
        let factors = RegimeFactorBuilder.factors(
            snapshot: noMacro, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)

        #expect(factors.contains { $0.kind == .valuation })
        #expect(factors.contains { $0.kind == .usRates } == false)
        #expect(factors.contains { $0.kind == .globalDollar } == false)
    }

    @Test func globalMacroDetailsCarryTheDrivingFigures() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        #expect(factors.first { $0.kind == .usRates }?.detail.contains("US 10y 4.10%") == true)
        #expect(factors.first { $0.kind == .globalDollar }?.detail.contains("119.0") == true)
    }

    @Test func usRatesDetailNamesFedFundsSoItDoesntContradictTheYield() {
        // Curve divergence: the 10y is *falling* while the Fed is still *hiking*. The
        // old label rendered "US 10y … falling (Fed tightening)" — a self-contradiction
        // on one line. The parenthetical must name its own subject (fed funds) so the
        // two rates can legibly move in opposite directions.
        let divergent = RegimeSnapshot(
            asOf: "2026-06-18",
            biRate: nil,
            macro: RegimeSnapshot.MacroBlock(
                usFedFunds: RegimeSnapshot.MacroSeries(value: 4.50, trend: .up, asOf: "2026-06-18"),
                us10y: RegimeSnapshot.MacroSeries(value: 4.49, trend: .down, asOf: "2026-06-18"),
                broadDollar: nil),
            indices: [:])
        let detail = RegimeFactorBuilder.factors(
            snapshot: divergent, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
            .first { $0.kind == .usRates }?.detail
        #expect(detail?.contains("US 10y 4.49% falling") == true)
        #expect(detail?.contains("Fed funds rising") == true)
        #expect(detail?.contains("Fed tightening") == false)   // no contradictory jargon
    }

    @Test func globalEquitiesIsRiskOffWhenSP500BelowIts200dma() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, sp500DistanceFrom200dma: -0.05,
            usdIdrChangePercent: nil, breadth: nil)
        #expect(signal(factors, .globalEquities) == .riskOff)
        #expect(factors.first { $0.kind == .globalEquities }?.detail.contains("S&P 500") == true)
        #expect(factors.first { $0.kind == .globalEquities }?.detail.contains("below") == true)
    }

    @Test func globalEquitiesDroppedWhenSP500Unavailable() {
        // A failed S&P 500 chart fetch (nil distance) drops the leg — the read degrades
        // to its other factors, exactly like any other absent live input.
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: 0.03, sp500DistanceFrom200dma: nil,
            usdIdrChangePercent: nil, breadth: nil)
        #expect(factors.contains { $0.kind == .globalEquities } == false)
        #expect(factors.contains { $0.kind == .trend })   // IHSG leg still present
    }

    @Test func foreignSellDetailNamesTheSideAndDropsTheMinus() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: -360_000_000_000, netForeignText: "-360.70 B",
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        let detail = factors.first { $0.kind == .foreignFlow }?.detail
        #expect(detail == "Net foreign sell 360.70 B")
    }

    @Test func foreignFlowDetailReportsForeignParticipationShareWhenAvailable() {
        // The non-redundant datum from the already-fetched value breakdown: the foreign
        // share of turnover. Vote is unchanged (still the net-foreign sign); the share
        // is context for how much the tape is foreign-driven. 50.99% → "51% of turnover".
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: -360_000_000_000, netForeignText: "-360.70 B",
            foreignParticipationPercent: 50.99,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        #expect(factors.first { $0.kind == .foreignFlow }?.detail
                == "Net foreign sell 360.70 B — foreigners 51% of turnover")
        #expect(signal(factors, .foreignFlow) == .riskOff)   // vote unchanged by participation
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

    // MARK: - Divergence-aware breadth (LQ45 leaders vs. KOMPAS100 broad market)

    /// Builds an isolated breadth factor (no other inputs) for the two readings.
    private func breadthFactor(leaders: BreadthReading?, broad: BreadthReading?) -> RegimeFactor? {
        RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil,
            breadth: leaders, kompasBreadth: broad)
            .first { $0.kind == .breadth }
    }

    @Test func breadthVotesOnTheBroadMarketSoANarrowingAdvanceReadsRiskOff() {
        // The point of the feature: leaders still strong (LQ45 70%) while the broad
        // market has rolled over (KOMPAS100 30%). The vote tracks KOMPAS100 → risk-off,
        // and the gap is labelled "narrowing" — the late-cycle thinning-advance tell.
        let factor = breadthFactor(leaders: BreadthReading(above: 7, measured: 10),
                                   broad: BreadthReading(above: 3, measured: 10))
        #expect(factor?.signal == .riskOff)
        #expect(factor?.detail == "KOMPAS100 30% vs LQ45 70% above their 200-day average — narrowing")
    }

    @Test func breadthReadsRiskOnWhenTheBroadMarketOutpacesTheLeaders() {
        // KOMPAS100 leading off a bottom (70%) while the leaders lag (30%): a broadening
        // base. The broad market drives the vote → risk-on, labelled "broadening".
        let factor = breadthFactor(leaders: BreadthReading(above: 3, measured: 10),
                                   broad: BreadthReading(above: 7, measured: 10))
        #expect(factor?.signal == .riskOn)
        #expect(factor?.detail == "KOMPAS100 70% vs LQ45 30% above their 200-day average — broadening")
    }

    @Test func breadthAgreementIsLabelledBroadBased() {
        let strong = breadthFactor(leaders: BreadthReading(above: 7, measured: 10),
                                   broad: BreadthReading(above: 8, measured: 10))
        #expect(strong?.signal == .riskOn)
        #expect(strong?.detail.contains("broad-based strength") == true)

        let weak = breadthFactor(leaders: BreadthReading(above: 3, measured: 10),
                                 broad: BreadthReading(above: 2, measured: 10))
        #expect(weak?.signal == .riskOff)
        #expect(weak?.detail.contains("broad-based weakness") == true)
    }

    @Test func breadthFallsBackToLQ45OnlyWhenKompasUnavailable() {
        // No KOMPAS100 membership (offline/cold sweep): the factor degrades to the
        // LQ45-only vote and *verbatim* detail it produced before becoming divergence-aware.
        let factor = breadthFactor(leaders: BreadthReading(above: 30, measured: 45), broad: nil)
        #expect(factor?.signal == .riskOn)   // 30/45 = 67% ≥ 60%
        #expect(factor?.detail == "67% of 45 LQ45 names above their 200-day average")
    }

    @Test func emptyWhenNothingAvailable() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil)
        #expect(factors.isEmpty)
    }
}
