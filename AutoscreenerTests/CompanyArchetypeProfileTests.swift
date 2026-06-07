import Foundation
import Testing
@testable import Autoscreener

// MARK: - Phase 2 (INTEGRATION.md §8 / §14): the additive CompanyArchetype / SelectionProfile seam.
//
// These tests cover the NEW behaviour Phase 2 introduces — the sector→archetype classifier, the
// industrial profile's composition, and the engine's profileSelector (DIP). The proof that the
// *industrial path is byte-for-byte unchanged* lives in SelectionEngineCharacterizationTests (the
// locked golden master); these tests prove the seam is real and is actually consulted.

// MARK: - Object Mother (compact, local — independent of the characterization mother)

private let fixedDate = Date(timeIntervalSince1970: 0)

private func flatBars(count: Int, close: Decimal = 1000, value: Decimal) -> [OHLCV] {
    (0..<count).map { _ in
        OHLCV(date: fixedDate, open: close, high: close, low: close, close: close,
              volume: 1000, value: value)
    }
}

/// Five clean years matching the characterization mother: rising NI, CFO 1.2× NI, flat receivables,
/// NCAV/share 2,500 so the Graham number (~2,012) is the binding intrinsic value.
private func cleanFinancials() -> [AnnualFinancials] {
    let b: Decimal = 1_000_000_000
    let nis: [Decimal] = [100, 110, 120, 130, 140].map { Decimal($0) * b }
    let revs: [Decimal] = [1000, 1100, 1200, 1300, 1400].map { Decimal($0) * b }
    let cfos: [Decimal] = [120, 132, 144, 156, 168].map { Decimal($0) * b }
    return (0..<5).map { i in
        AnnualFinancials(
            year: 2021 + i,
            revenue: revs[i], netIncome: nis[i], operatingCashFlow: cfos[i],
            totalAssets: Decimal(2_000) * b, totalLiabilities: Decimal(2_000) * b,
            currentAssets: Decimal(4_500) * b, currentLiabilities: Decimal(1_000) * b,
            shareholderEquity: Decimal(1_000) * b, receivables: Decimal(50) * b,
            sharesOutstanding: b)
    }
}

/// A name that passes DataIntegrity / Liquidity / Forensic, with the current ratio as a free knob so
/// a test can make it fail (only) the industrial SolvencyGate.
private func seamSecurity(sector: String = "Industrials", currentRatio: Double = 2.0) -> SecurityData {
    let ttm = TTMFinancials(
        eps: 150, bookValuePerShare: 1200,
        netIncome: Decimal(140) * 1_000_000_000, operatingCashFlow: Decimal(168) * 1_000_000_000,
        totalAssets: Decimal(2_000) * 1_000_000_000,
        epsGrowthPct: 15.0, currentRatio: currentRatio, debtToEquity: 0.5, returnOnEquity: 0.20)
    return SecurityData(
        ticker: "TEST", sector: sector, price: 1000,
        sharesOutstanding: 1_000_000_000, freeFloatPct: 0.40,
        financials: cleanFinancials(), ttm: ttm,
        dailyBars: flatBars(count: 250, value: 10_000_000_000),
        foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: flatBars(count: 250, value: 1),
        marketIndexBars: flatBars(count: 250, value: 1))
}

/// risk = 0.5·1.0 + (1−0.6)·0.5 = 0.70 → neutral (minMoS 0.30).
private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}

private struct StubDataProvider: DataProvider {
    var security: SecurityData
    var context: MarketContext
    func universe() async throws -> [Ticker] { [security.ticker] }
    func data(for t: Ticker) async throws -> SecurityData { security }
    func marketContext() async throws -> MarketContext { context }
}

/// A valuator test-double that reports a fixed intrinsic value — used to prove the engine reads the
/// *profile's* valuator (not a hardcoded one) for the reported IV.
private struct FixedValuator: Valuator {
    let iv: Double
    func intrinsicValue(_ s: SecurityData, config: SelectionConfig) -> Double { iv }
}

// MARK: - Classifier (test-first)

@Suite struct CompanyArchetypeClassifyTests {
    @Test func nonFinancialSectorsAreIndustrial() {
        #expect(CompanyArchetype.classify(sector: "Industrials") == .industrial)
        #expect(CompanyArchetype.classify(sector: "Teknologi") == .industrial)
        #expect(CompanyArchetype.classify(sector: "") == .industrial)
    }
    @Test func keuanganIsFinancial() {
        #expect(CompanyArchetype.classify(sector: "Keuangan") == .financial)
    }
    @Test func classificationIsCaseAndWhitespaceInsensitive() {
        #expect(CompanyArchetype.classify(sector: "  KEUANGAN  ") == .financial)
        #expect(CompanyArchetype.classify(sector: "keuangan") == .financial)
    }
}

// MARK: - Industrial profile composition

@Suite struct SelectionProfileIndustrialTests {
    @Test func industrialProfileHasTodaysGatesScorersAndValuator() {
        let p = SelectionProfile.industrial(.balanced)
        #expect(p.archetype == .industrial)
        #expect(p.gates.map(\.name) == ["DataIntegrity", "Liquidity", "Forensic", "Solvency"])
        #expect(p.scorers.map(\.id) == [.grahamValue, .quality, .growthLynch, .earningsQuality])
        #expect(p.valuator is GrahamValuator)
    }
}

// MARK: - Default profile routing (Phase 2 fallback)

@Suite struct DefaultProfileRoutingTests {
    /// A bank classifies as `.financial`, but Phase 2 has no financial profile yet, so the default
    /// selector still hands it the industrial profile — no behaviour change. Phase 3 swaps this.
    @Test func bankClassifiesFinancialButStillGetsIndustrialProfileInPhase2() {
        let bank = seamSecurity(sector: "Keuangan")
        #expect(CompanyArchetype.classify(sector: bank.sector) == .financial)
        let profile = StockSelectionEngine.defaultProfile(for: bank, config: .balanced)
        #expect(profile.archetype == .industrial)
    }
    @Test func industrialNameGetsIndustrialProfile() {
        let profile = StockSelectionEngine.defaultProfile(for: seamSecurity(), config: .balanced)
        #expect(profile.archetype == .industrial)
    }
}

// MARK: - The engine actually consults the injected profileSelector (DIP)

@Suite struct ProfileSelectorSeamTests {

    /// Baseline: with the default selector, a name that fails the industrial SolvencyGate is screened out.
    @Test func defaultSelectorScreensOutSolvencyFailure() async throws {
        let s = seamSecurity(currentRatio: 0.5)   // < minCurrentRatio 1.0 → fails Solvency
        let engine = StockSelectionEngine(provider: StubDataProvider(security: s, context: neutralContext()),
                                          config: .balanced)
        #expect(try await engine.run().isEmpty)
    }

    /// Same name, but an injected gate-less profile admits it — proving the engine runs the profile's
    /// gates, not a hardcoded set.
    @Test func injectedGatelessProfileAdmitsSolvencyFailure() async throws {
        let s = seamSecurity(currentRatio: 0.5)
        let engine = StockSelectionEngine(
            provider: StubDataProvider(security: s, context: neutralContext()),
            config: .balanced,
            profileSelector: { _ in
                SelectionProfile(archetype: .industrial, gates: [],
                                 scorers: [QualityScorer()], valuator: GrahamValuator())
            })
        let recs = try await engine.run()
        #expect(recs.count == 1)
        #expect(recs.first?.ticker == "TEST")
    }

    /// The composite is built from the profile's scorers: with only QualityScorer injected, the audit
    /// carries that scorer's line and none of the other three.
    @Test func compositeUsesInjectedProfileScorers() async throws {
        let s = seamSecurity(currentRatio: 0.5)
        let engine = StockSelectionEngine(
            provider: StubDataProvider(security: s, context: neutralContext()),
            config: .balanced,
            profileSelector: { _ in
                SelectionProfile(archetype: .industrial, gates: [],
                                 scorers: [QualityScorer()], valuator: GrahamValuator())
            })
        let r = try #require(try await engine.run().first)
        #expect(r.audit.contains { $0.hasPrefix("Quality ") })
        #expect(!r.audit.contains { $0.hasPrefix("GrahamValue ") })
        #expect(!r.audit.contains { $0.hasPrefix("GrowthLynch ") })
        #expect(!r.audit.contains { $0.hasPrefix("EarningsQuality ") })
    }

    /// The reported intrinsic value comes from the profile's valuator, not a hardcoded Graham number.
    @Test func reportedIntrinsicValueComesFromProfileValuator() async throws {
        let s = seamSecurity()
        let engine = StockSelectionEngine(
            provider: StubDataProvider(security: s, context: neutralContext()),
            config: .balanced,
            profileSelector: { _ in
                SelectionProfile(archetype: .industrial,
                                 gates: [DataIntegrityGate(), LiquidityGate(), ForensicGate(), SolvencyGate()],
                                 scorers: [QualityScorer()], valuator: FixedValuator(iv: 9999))
            })
        let r = try #require(try await engine.run().first)
        #expect(abs(r.intrinsicValue - 9999) < 1e-6)
    }
}
