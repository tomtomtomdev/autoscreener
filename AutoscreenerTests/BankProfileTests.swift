import Foundation
import Testing
@testable import Autoscreener

// MARK: - Phase 3 (INTEGRATION.md §8 / §14): the financial (bank) SelectionProfile.
//
// The archetype seam (Phase 2) is already proven; this suite drives the NEW financial path it was
// built for — the capital-strength gate, the justified-P/B valuator, the bank scorers, the
// `.financial` profile composition, and the engine routing a `.financial` name to it. The industrial
// golden master (SelectionEngineCharacterizationTests) stays the byte-for-byte unchanged baseline.
//
// Bank numbers are anchored to the BBCA capture (proxseer_collection-2.json, §14): ROE 22.41%,
// payout 63.17%, ROA 3.54%, BVPS 2,102.07, P/B 2.41 — with the calibrated default bank params
// (Rf 6.5%, ERP 7%, β 1.0 — gate-strictness #2 dropped the 1.1 placeholder) the justified P/B comes
// out ~2.27, i.e. BBCA still screens as ~6% rich at that captured price.

private let fixedDate = Date(timeIntervalSince1970: 0)

private func flatBars(count: Int, close: Decimal = 1000, value: Decimal) -> [OHLCV] {
    (0..<count).map { _ in
        OHLCV(date: fixedDate, open: close, high: close, low: close, close: close,
              volume: 1000, value: value)
    }
}

/// Five clean years of rising net income — enough to clear DataIntegrity (≥5y) and to give the bank
/// earnings-quality scorer a stable, monotone series. Bank balance sheets lack the current/receivable
/// split, so those stay 0 (the bank profile never reads them).
private func bankFinancials(netIncomes: [Decimal] = [40, 44, 48, 52, 58].map { $0 * 1_000_000_000_000 })
    -> [AnnualFinancials] {
    netIncomes.enumerated().map { i, ni in
        AnnualFinancials(
            year: 2021 + i,
            revenue: 0, netIncome: ni, operatingCashFlow: ni,
            totalAssets: 1_640_831 * 1_000_000_000, totalLiabilities: 0,
            currentAssets: 0, currentLiabilities: 0,
            shareholderEquity: 259_132 * 1_000_000_000, receivables: 0,
            sharesOutstanding: 0)
    }
}

/// A BBCA-shaped bank. `currentRatio` / `debtToEquity` are 0 (banks report "-"); the financial profile
/// never runs SolvencyGate, so those are unread. `bvps` × `shares` ÷ `totalAssets` is the equity/assets
/// capital proxy; the knobs let a test push it below the floor.
private func bankSecurity(
    sector: String = "Keuangan",
    price: Decimal = 5066,                 // ≈ P/B 2.41 × BVPS 2,102.07
    bvps: Decimal = 2102.07,
    shares: Decimal = 123_270_000_000,     // ≈ NI 58,075 B ÷ EPS 471.10
    totalAssets: Decimal = 1_640_831 * 1_000_000_000,
    roe: Double = 0.2241,
    roa: Double = 0.0354,
    payout: Double = 0.6317,
    epsGrowthPct: Double = 10.0,
    barCount: Int = 250,
    barValue: Decimal = 50_000_000_000,
    financials: [AnnualFinancials] = bankFinancials()
) -> SecurityData {
    let ttm = TTMFinancials(
        eps: 471.10, bookValuePerShare: bvps,
        netIncome: 58_075 * 1_000_000_000, operatingCashFlow: 58_075 * 1_000_000_000,
        totalAssets: totalAssets,
        epsGrowthPct: epsGrowthPct, currentRatio: 0, debtToEquity: 0, returnOnEquity: roe,
        payoutRatio: payout, returnOnAssets: roa)
    return SecurityData(
        ticker: "BBCA", sector: sector, price: price,
        sharesOutstanding: shares, freeFloatPct: 0.40,
        financials: financials, ttm: ttm,
        dailyBars: flatBars(count: barCount, value: barValue),
        foreignNetFlow: [], brokerAccumulationSignal: 0,
        sectorIndexBars: flatBars(count: barCount, value: 1),
        marketIndexBars: flatBars(count: barCount, value: 1))
}

private func failReason(_ v: Verdict) -> String? {
    if case let .fail(reason) = v { return reason }
    return nil
}
private func isPass(_ v: Verdict) -> Bool {
    if case .pass = v { return true }
    return false
}

private let neutral = RegimePolicy(regime: .neutral, minMarginOfSafety: 0.30, maxTotalExposure: 0.65,
                                   maxPositionPct: 0.10, maxSectorPct: 0.25, maxNames: 10, weightTilt: [:])

/// risk = 0.5·1.0 + (1−0.6)·0.5 = 0.70 → neutral (minMoS 0.30 under .balanced).
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

// MARK: - 3.1 CapitalStrengthGate (CAR proxy: Common Equity ÷ Total Assets)

@Suite struct CapitalStrengthGateTests {
    @Test func wellCapitalisedBankPasses() {
        // BBCA: equity 259,132 B ÷ assets 1,640,831 B ≈ 15.8% ≫ 6% floor.
        let s = bankSecurity()
        #expect(isPass(CapitalStrengthGate().evaluate(s, config: .balanced, policy: neutral)))
    }

    @Test func thinlyCapitalisedBankFails() {
        // Same equity, 10× the assets → equity/assets ≈ 1.6% < 6% floor.
        let s = bankSecurity(totalAssets: 16_408_310 * 1_000_000_000)
        #expect(failReason(CapitalStrengthGate().evaluate(s, config: .balanced, policy: neutral))?
            .hasPrefix("thin capital") == true)
    }

    @Test func failsWhenAssetsAreZero() {
        // No assets figure → can't form the ratio → conservatively fail rather than divide by zero.
        let s = bankSecurity(totalAssets: 0)
        #expect(failReason(CapitalStrengthGate().evaluate(s, config: .balanced, policy: neutral)) != nil)
    }
}

// MARK: - 3.2 JustifiedPBValuator (Damodaran financial-firm P/B-vs-ROE)

/// A config whose bank valuation rates are clean round numbers, so the justified-P/B arithmetic is
/// evident in the test rather than copied from a run.
private func bankConfig(rf: Double, erp: Double, beta: Double) -> SelectionConfig {
    var c = SelectionConfig.balanced
    c.bank.riskFreeRate = rf
    c.bank.equityRiskPremium = erp
    c.bank.beta = beta
    return c
}

@Suite struct JustifiedPBValuatorTests {

    @Test func cappedGrowthCaseIsEvident() {
        // ROE 20%, payout 50% → g = (1−0.5)·0.20 = 0.10, capped to Rf 0.06.
        // Ke = 0.06 + 1.0·0.08 = 0.14. justified P/B = (0.20−0.06)/(0.14−0.06) = 0.14/0.08 = 1.75.
        // IV = 1.75 × BVPS 1000 = 1750.
        let c = bankConfig(rf: 0.06, erp: 0.08, beta: 1.0)
        let s = bankSecurity(bvps: 1000, roe: 0.20, payout: 0.50)
        #expect(abs(JustifiedPBValuator().intrinsicValue(s, config: c) - 1750) < 1e-6)
    }

    @Test func uncappedGrowthCaseIsEvident() {
        // ROE 10%, payout 60% → g = 0.4·0.10 = 0.04 (< Rf 0.06, NOT capped).
        // Ke = 0.14. justified P/B = (0.10−0.04)/(0.14−0.04) = 0.06/0.10 = 0.60. IV = 0.60 × 1000 = 600.
        let c = bankConfig(rf: 0.06, erp: 0.08, beta: 1.0)
        let s = bankSecurity(bvps: 1000, roe: 0.10, payout: 0.60)
        #expect(abs(JustifiedPBValuator().intrinsicValue(s, config: c) - 600) < 1e-6)
    }

    @Test func reproducesTheBbcaWorkedExample() {
        // §14 worked check on real capture values with the calibrated defaults (Rf 6.5%, ERP 7%, β 1.0;
        // gate-strictness #2 lowered β from the 1.1 placeholder): g = (1−0.6317)·0.2241 ≈ 0.0825 → capped
        // to 0.065; Ke = 0.135; justified P/B = (0.2241−0.065)/(0.135−0.065) ≈ 2.273; IV ≈ 4,777.7.
        let v = JustifiedPBValuator()
        let s = bankSecurity()
        #expect(abs(v.intrinsicValue(s, config: .balanced) - 4777.7) < 1.0)
        // Actual P/B 2.41 > justified 2.27 → BBCA is still ~6% rich → negative margin of safety.
        let mos = v.marginOfSafety(s, config: .balanced)
        #expect(mos < 0)
        #expect(abs(mos - (-0.060)) < 5e-3)
    }

    // MARK: - Regression: bank cost-of-equity calibration (gate-strictness #2, β fix).
    //
    // The default bank β was a placeholder 1.1 (the code comment flagged it as such), giving Ke 14.2%.
    // For a low-beta deposit franchise that is too high, and it pushed the ROE-justified P/B so low that
    // a bank trading BELOW book was scored as OVERVALUED. Live capture (2026-06-16): BBNI at 0.88× book,
    // ROE 12.6% — under β 1.1 its justified P/B (≈0.82) sat under its price → negative MoS → screened out.
    // A sub-book bank flagged as expensive is the bug. With the bottom-up β 1.0 (Ke 13.5%) the justified
    // P/B (≈0.89) clears its price → non-negative MoS. (Grounded in damodaran-valuation: large IDX banks
    // are low-beta; β is the input most worth correcting.)
    @Test func subBookValueBankIsNotValuedAsOvervalued() {
        let s = bankSecurity(price: 880, bvps: 1000, roe: 0.1259, payout: 0.5755)   // BBNI-shaped, P/B 0.88
        let mos = JustifiedPBValuator().marginOfSafety(s, config: .balanced)
        #expect(mos > 0)
    }

    @Test func lossMakingBankHasNoJustifiedValue() {
        // ROE ≤ 0: the justified-P/B model degenerates → IV 0 (screened out by the MoS gate).
        let s = bankSecurity(roe: -0.05)
        #expect(JustifiedPBValuator().intrinsicValue(s, config: .balanced) == 0)
    }

    @Test func negativeBookValueHasNoJustifiedValue() {
        let s = bankSecurity(bvps: 0)
        #expect(JustifiedPBValuator().intrinsicValue(s, config: .balanced) == 0)
    }
}

// MARK: - 3.3 Bank scorers (BankValue / BankQuality / BankEarningsQuality)

@Suite struct BankScorerTests {

    @Test func bankValueRewardsADiscountToJustifiedPB() {
        // justified P/B 1.75 (Rf 0.06, ERP 0.08, β 1.0; ROE 20% payout 50%). Actual P/B 0.875 (price
        // 875 ÷ BVPS 1000) → discount (1.75−0.875)/1.75 = 0.5 → full credit at pbDiscountFullCreditAt 0.5.
        let c = bankConfig(rf: 0.06, erp: 0.08, beta: 1.0)
        let s = bankSecurity(price: 875, bvps: 1000, roe: 0.20, payout: 0.50)
        #expect(abs(BankValueScorer().score(s, config: c).value - 1.0) < 1e-6)
    }

    @Test func bankValueScoresZeroWhenRichToJustifiedPB() {
        // BBCA: actual P/B 2.41 > justified 2.27 → no discount → 0.
        #expect(BankValueScorer().score(bankSecurity(), config: .balanced).value == 0)
    }

    @Test func bankQualityCombinesRoeAndRoa() {
        // ROE 25% → (0.25−0.10)/0.15 = 1.0 ×0.5 = 0.5; ROA 2.5% → (0.025−0.005)/0.02 = 1.0 ×0.3 = 0.3.
        let s = bankSecurity(roe: 0.25, roa: 0.025)
        #expect(abs(BankQualityScorer().score(s, config: .balanced).value - 0.8) < 1e-6)
    }

    @Test func bankEarningsQualityRewardsStableGrowthAndSustainablePayout() {
        // Net income compounding a constant 10% → growth-rate stability 1.0 (×0.5). Payout 63% ≤ 0.8
        // ceiling → sustainable, full credit (×0.5). Total 1.0.
        let ni: [Decimal] = [10000, 11000, 12100, 13310, 14641].map { $0 * 1_000_000_000 }
        let s = bankSecurity(payout: 0.6317, financials: bankFinancials(netIncomes: ni))
        #expect(abs(BankEarningsQualityScorer().score(s, config: .balanced).value - 1.0) < 1e-9)
    }

    @Test func bankEarningsQualityPenalisesUnsustainablePayout() {
        // Same stable growth, but payout 100% (paying out every rupiah) → payout credit 0 → only the
        // stability half (0.5) remains.
        let ni: [Decimal] = [10000, 11000, 12100, 13310, 14641].map { $0 * 1_000_000_000 }
        let s = bankSecurity(payout: 1.0, financials: bankFinancials(netIncomes: ni))
        #expect(abs(BankEarningsQualityScorer().score(s, config: .balanced).value - 0.5) < 1e-9)
    }
}

// MARK: - 3.4 Financial profile composition + the defaultProfile routing flip

@Suite struct FinancialProfileCompositionTests {
    @Test func financialProfileSwapsGatesScorersAndValuator() {
        let p = SelectionProfile.financial(.balanced)
        #expect(p.archetype == .financial)
        #expect(p.gates.map(\.name) == ["DataIntegrity", "Liquidity", "CapitalStrength"])
        #expect(p.scorers.map(\.id) == [.bankValue, .bankQuality, .growthLynch, .bankEarningsQuality])
        #expect(p.valuator is JustifiedPBValuator)
    }
    @Test func defaultSelectorNowRoutesBanksToTheFinancialProfile() {
        // The Phase 3 flip: a "Keuangan" name resolves to the financial profile (Phase 2 fell back to
        // industrial). Industrial names are unaffected.
        let bank = StockSelectionEngine.defaultProfile(for: bankSecurity(), config: .balanced)
        #expect(bank.archetype == .financial)
        #expect(bank.valuator is JustifiedPBValuator)
        let industrial = StockSelectionEngine.defaultProfile(for: bankSecurity(sector: "Teknologi"), config: .balanced)
        #expect(industrial.archetype == .industrial)
    }
}

// MARK: - 3.4 End-to-end: a bank runs through the bank profile (flip is live)

@Suite struct BankPipelineTests {

    @Test func cheapBankIsRecommendedAndAuditedAsAFinancial() async throws {
        // P/B ≈ 1.0 (price 2102 ÷ BVPS 2102.07) vs justified 2.27 → IV ≈ 4778, MoS ≈ 56% ≫ 15% bank floor.
        let s = bankSecurity(price: 2102)
        let engine = StockSelectionEngine(provider: StubDataProvider(security: s, context: neutralContext()),
                                          config: .balanced)
        let r = try #require(try await engine.run().first)
        #expect(r.ticker == "BBCA")
        #expect(abs(r.intrinsicValue - 4777.7) < 1.0)         // from JustifiedPBValuator, not Graham
        #expect(r.marginOfSafety > 0.30)
        // The audit proves the BANK profile ran — capital-strength gate + bank scorers, never the
        // industrial Solvency/Forensic gates or GrahamValue scorer.
        #expect(r.audit.contains("✓ CapitalStrength"))
        #expect(r.audit.contains { $0.hasPrefix("BankValue ") })
        #expect(r.audit.contains { $0.hasPrefix("BankQuality ") })
        #expect(r.audit.contains { $0.hasPrefix("BankEarningsQuality ") })
        #expect(!r.audit.contains { $0.contains("Solvency") })
        #expect(!r.audit.contains { $0.hasPrefix("GrahamValue ") })
    }

    @Test func richBankIsScreenedOutByTheMoSGate() async throws {
        // BBCA at its captured price (P/B 2.41) → justified ≈ 2.27 → negative MoS → not recommended.
        let engine = StockSelectionEngine(provider: StubDataProvider(security: bankSecurity(), context: neutralContext()),
                                          config: .balanced)
        #expect(try await engine.run().isEmpty)
    }

    // Regression (gate-strictness #2, β + bank-specific MoS floor): a quality bank ~18% below its
    // justified value (BMRI-shaped: ROE 19.2%, P/B 1.38) is NOW recommended. It was screened out before
    // on two counts — the placeholder β 1.1 understated its justified P/B (MoS only ~11.5%), and the 30%
    // industrial MoS floor demands a net-net discount banks almost never offer. With the bottom-up β 1.0
    // (MoS ~18.5%) and the financial-archetype floor (~15% neutral), a "wonderful business at a fair
    // price" bank finally clears the gate. The < 30% assertion proves the lower bank floor is what admits
    // it — under the industrial floor it would still be screened out.
    @Test func qualityBankBelowJustifiedValueClearsTheLowerBankFloor() async throws {
        let s = bankSecurity(price: 1380, bvps: 1000, roe: 0.1918, payout: 0.7234)   // BMRI-shaped, P/B 1.38
        let engine = StockSelectionEngine(provider: StubDataProvider(security: s, context: neutralContext()),
                                          config: .balanced)
        let r = try #require(try await engine.run().first,
                             "a quality bank ~18% below fair value should clear the 15% bank floor")
        #expect(r.marginOfSafety > 0.15)
        #expect(r.marginOfSafety < 0.30)
    }
}
