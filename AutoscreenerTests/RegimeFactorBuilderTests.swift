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
            breadth: BreadthReading(above: 30, measured: 45),
            commodityChannel: CommodityChannelReading(   // export basket up → tailwind
                basketChangePercent: 2.5, contributors: ["coal", "nickel"], cnyChangePercent: 0.3),
            asiaEM: AsiaEMReading(                        // Asia-EM leading the S&P → risk-on
                regionalDistance: 0.05, contributors: ["Hang Seng"], relativeToSP: 0.03),
            sovereign: IndonesiaSovereignReading(         // 5y CDS tightening 7.39% over 1M → risk-on
                bond10yPercent: 7.07, cds5y: 86.48, cdsChange1MPercent: -7.39))

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
        #expect(signal(factors, .commodityChannel) == .riskOn) // basket +2.5% → tailwind
        #expect(signal(factors, .asiaEM) == .riskOn)        // +3% ahead of the S&P → risk-on
        #expect(signal(factors, .sovereignRisk) == .riskOn) // CDS tightening 7.39% over 1M → risk-on
    }

    @Test func sovereignDetailNamesTheCdsMoveTheBondYieldAndTheSpreadOverUST() {
        // With the macro leg present (UST 10y = 4.10), the detail carries the 5y CDS level + its
        // 1-month move (the vote), the INDOGB 10y yield, and the EM sovereign spread over the UST.
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot,
            netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil,
            sovereign: IndonesiaSovereignReading(
                bond10yPercent: 7.07, cds5y: 86.48, cdsChange1MPercent: -7.39))

        let detail = factors.first { $0.kind == .sovereignRisk }?.detail
        #expect(detail == "5y CDS 86 bps -7.39% 1M — INDOGB 10y 7.07% · +297 bps over UST, risk premium easing")
    }

    @Test func sovereignDetailOmitsTheSpreadWhenTheMacroLegIsAbsent() {
        // No snapshot (so no UST 10y) → the spread clause drops; the CDS vote + bond yield remain,
        // and a widening CDS reads "rising".
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil,
            netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil,
            sovereign: IndonesiaSovereignReading(
                bond10yPercent: 7.20, cds5y: 120, cdsChange1MPercent: 11.4))

        let factor = factors.first { $0.kind == .sovereignRisk }
        #expect(factor?.signal == .riskOff)
        #expect(factor?.detail == "5y CDS 120 bps +11.40% 1M — INDOGB 10y 7.20%, risk premium rising")
    }

    @Test func sovereignDroppedWhenAbsent() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: Self.snapshot,
            netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil, breadth: nil,
            sovereign: nil)
        #expect(!factors.contains { $0.kind == .sovereignRisk })
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

    // MARK: - China channel (commodity export terms of trade)

    /// Builds an isolated China-channel factor (no other inputs) for one reading.
    private func chinaFactor(_ reading: CommodityChannelReading?) -> RegimeFactor? {
        RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil,
            breadth: nil, commodityChannel: reading)
            .first { $0.kind == .commodityChannel }
    }

    @Test func chinaChannelNamesTheBasketAndCnyContextWhenFirming() {
        // Basket +1.8% (> 1.5% band) → risk-on, CNY corroborates in the detail (no second vote).
        let factor = chinaFactor(CommodityChannelReading(
            basketChangePercent: 1.8, contributors: ["coal", "CPO", "nickel"], cnyChangePercent: 0.3))
        #expect(factor?.signal == .riskOn)
        #expect(factor?.detail == "Export basket +1.80% (coal/CPO/nickel) · CNY/IDR +0.30% — China demand firming")
    }

    @Test func chinaChannelOmitsCnyWhenAbsentAndReadsSofteningOnAFallingBasket() {
        // Basket −2.1% (< −1.5% band) → risk-off; CNY unpriced → no CNY clause in the detail.
        let factor = chinaFactor(CommodityChannelReading(
            basketChangePercent: -2.1, contributors: ["nickel"], cnyChangePercent: nil))
        #expect(factor?.signal == .riskOff)
        #expect(factor?.detail == "Export basket -2.10% (nickel) — China demand softening")
    }

    @Test func chinaChannelDroppedWhenAbsent() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil,
            breadth: nil, commodityChannel: nil)
        #expect(factors.contains { $0.kind == .commodityChannel } == false)
    }

    // MARK: - Asia-EM equities (EM-vs-developed-market rotation)

    /// Builds an isolated Asia-EM factor (no other inputs) for one reading.
    private func asiaFactor(_ reading: AsiaEMReading?) -> RegimeFactor? {
        RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil,
            breadth: nil, asiaEM: reading)
            .first { $0.kind == .asiaEM }
    }

    @Test func asiaEMNamesTheBasketAndTheLeadOverTheSPWhenFirming() {
        // Regional +5% above its 200dma, 3% ahead of the S&P (> 1.5% band) → risk-on; the relative
        // lead is the vote and rides in the detail as the qualifier (no second vote).
        let factor = asiaFactor(AsiaEMReading(
            regionalDistance: 0.05, contributors: ["Hang Seng", "Shanghai", "KOSPI"], relativeToSP: 0.03))
        #expect(factor?.signal == .riskOn)
        #expect(factor?.detail == "Asia-EM +5.0% vs 200-day avg (Hang Seng/Shanghai/KOSPI) — 3.0% ahead of the S&P, EM appetite firming")
    }

    @Test func asiaEMReadsSofteningWhenLaggingARisingDevelopedMarketTape() {
        // Regional −2% and 4% behind the S&P (< −1.5% band) → risk-off: a DM-led advance not
        // reaching the EM periphery.
        let factor = asiaFactor(AsiaEMReading(
            regionalDistance: -0.02, contributors: ["Hang Seng"], relativeToSP: -0.04))
        #expect(factor?.signal == .riskOff)
        #expect(factor?.detail == "Asia-EM -2.0% vs 200-day avg (Hang Seng) — 4.0% behind the S&P, EM appetite softening")
    }

    @Test func asiaEMFallsBackToTheAbsoluteRegionalTrendWithoutABenchmark() {
        // No S&P benchmark (relativeToSP nil) → the vote is the absolute regional trend (+6% → on),
        // and the detail drops the comparison clause.
        let factor = asiaFactor(AsiaEMReading(
            regionalDistance: 0.06, contributors: ["Hang Seng", "Shanghai", "KOSPI"], relativeToSP: nil))
        #expect(factor?.signal == .riskOn)
        #expect(factor?.detail == "Asia-EM +6.0% vs 200-day avg (Hang Seng/Shanghai/KOSPI) — regional appetite firming")
    }

    @Test func asiaEMIsNeutralAndLevelWhenInLineWithTheSP() {
        // A small lead inside the dead-band → neutral, and the detail says "level with the S&P".
        let factor = asiaFactor(AsiaEMReading(
            regionalDistance: 0.01, contributors: ["Hang Seng"], relativeToSP: 0.005))
        #expect(factor?.signal == .neutral)
        #expect(factor?.detail == "Asia-EM +1.0% vs 200-day avg (Hang Seng) — level with the S&P, EM appetite steady")
    }

    @Test func asiaEMDroppedWhenAbsent() {
        let factors = RegimeFactorBuilder.factors(
            snapshot: nil, netForeignRaw: nil, netForeignText: nil,
            ihsgDistanceFrom200dma: nil, usdIdrChangePercent: nil,
            breadth: nil, asiaEM: nil)
        #expect(factors.contains { $0.kind == .asiaEM } == false)
    }
}
