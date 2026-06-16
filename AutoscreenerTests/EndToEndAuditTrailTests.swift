import Foundation
import Testing
@testable import Autoscreener

// MARK: - Phase 4.3 (INTEGRATION.md §8 / §13-A3): end-to-end audit-trail verification.
//
// The golden master and BankProfileTests already run the pipeline, but on FLAT bars — so their timing
// modifier always takes the degenerate fallback path. This suite is the missing end-to-end proof: it
// runs the WHOLE pipeline (regime → gates → MoS → scorers → flow → timing → sizing) on bars WITH
// variance, for one industrial and one bank, and verifies the complete audit trail reads coherently —
// including that the Phase-4.1 rolling regression engages (the timing line reports MEASURED betas, not
// the placeholder fallback). The stock bars are built as an exact factor combination of the index bars
// (βmarket 1.1, βsector 0.3) so the measured betas are evident, not copied from a run.
//
// This is the deterministic, offline half of 4.3. The truly-LIVE audit (running the engine against the
// authenticated Stockbit feed for real WIFI / BBCA) is a manual step — see INTEGRATION.md §8 Phase 4.

private let fixedDate = Date(timeIntervalSince1970: 0)
private let oneB: Decimal = 1_000_000_000

/// Builds `returns.count + 1` bars whose close-to-close returns reproduce `returns`, each carrying a
/// fixed traded `value` (so the liquidity gate/sizing see real ADV).
private func barSeries(returns: [Double], start: Double, value: Decimal) -> [OHLCV] {
    var close = start
    func bar(_ c: Double) -> OHLCV {
        OHLCV(date: fixedDate, open: Decimal(c), high: Decimal(c), low: Decimal(c),
              close: Decimal(c), volume: 1000, value: value)
    }
    var out = [bar(close)]
    for r in returns { close *= (1 + r); out.append(bar(close)) }
    return out
}

// Two independent index factor paths (periods 5 and 7 → not collinear), 250 daily returns each.
private let marketReturns: [Double] = (0..<250).map { Double($0 % 5 - 2) * 0.008 }
private let sectorReturns: [Double] = (0..<250).map { Double($0 % 7 - 3) * 0.006 }
// Stock = 1.1·market + 0.3·(sector − market) exactly → measured betas recover 1.10 / 0.30.
private let stockReturns: [Double] = zip(marketReturns, sectorReturns).map { 1.1 * $0 + 0.3 * ($1 - $0) }

private func varyingStockBars(start: Double, value: Decimal) -> [OHLCV] {
    barSeries(returns: stockReturns, start: start, value: value)
}
private let marketIndexBars = barSeries(returns: marketReturns, start: 7000, value: 1)
private let sectorIndexBars = barSeries(returns: sectorReturns, start: 1500, value: 1)

private func neutralContext() -> MarketContext {
    MarketContext(indexValuationPercentile: 0.5, breadthAbove200dma: 0.6, indexAbove200dma: true,
                  idrWeakeningTrend: false, biRateRising: false, marketForeignFlowNet: 0,
                  commodityTailwind: true)
}

private struct StubProvider: DataProvider {
    let security: SecurityData
    func universe() async throws -> [Ticker] { [security.ticker] }
    func data(for t: Ticker) async throws -> SecurityData { security }
    func marketContext() async throws -> MarketContext { neutralContext() }
}

// MARK: - Industrial (WIFI-shaped): a clean, cheap technology name.

/// Five clean years (margin stable, net income rising, CFO 1.2× NI) and a consistent, cash-rich balance
/// sheet (current assets 10,000B ≤ total assets 12,000B) whose NCAV ≈ 8,000 exceeds the earnings-based
/// Graham number (≈6,364), so the net-current-asset floor is the binding intrinsic value.
private func cleanIndustrialFinancials() -> [AnnualFinancials] {
    let nis: [Decimal] = [300, 330, 360, 400, 450].map { $0 * oneB }
    let revs: [Decimal] = [3000, 3300, 3600, 4000, 4500].map { $0 * oneB }
    let cfos: [Decimal] = nis.map { $0 * 12 / 10 }
    return (0..<5).map { i in
        AnnualFinancials(year: 2021 + i, revenue: revs[i], netIncome: nis[i], operatingCashFlow: cfos[i],
                         totalAssets: 12_000 * oneB, totalLiabilities: 2_000 * oneB,
                         currentAssets: 10_000 * oneB, currentLiabilities: 1_500 * oneB,
                         shareholderEquity: 10_000 * oneB, receivables: 220 * oneB, sharesOutstanding: oneB)
    }
}

private func wifiSecurity() -> SecurityData {
    let ttm = TTMFinancials(eps: 900, bookValuePerShare: 2000, netIncome: 450 * oneB,
                            operatingCashFlow: 540 * oneB, totalAssets: 12_000 * oneB,
                            epsGrowthPct: 20.0, currentRatio: 2.2, debtToEquity: 0.6, returnOnEquity: 0.18,
                            payoutRatio: 0.0161, returnOnAssets: 0.0303)
    return SecurityData(ticker: "WIFI", sector: "Teknologi", price: 2500, sharesOutstanding: oneB,
                        freeFloatPct: 0.40, financials: cleanIndustrialFinancials(), ttm: ttm,
                        dailyBars: varyingStockBars(start: 2500, value: 20_000_000_000),
                        foreignNetFlow: [3 * oneB, 5 * oneB, 4 * oneB], brokerAccumulationSignal: 0.4,
                        sectorIndexBars: sectorIndexBars, marketIndexBars: marketIndexBars)
}

// MARK: - Bank (BBCA-shaped): the captured fundamentals, priced cheaply so it clears the MoS gate.

private func cleanBankFinancials() -> [AnnualFinancials] {
    let nis: [Decimal] = [40, 44, 48, 53, 58].map { $0 * 1_000 * oneB }
    return nis.enumerated().map { i, ni in
        AnnualFinancials(year: 2021 + i, revenue: 0, netIncome: ni, operatingCashFlow: ni,
                         totalAssets: 1_640_831 * oneB, totalLiabilities: 0, currentAssets: 0,
                         currentLiabilities: 0, shareholderEquity: 259_132 * oneB, receivables: 0,
                         sharesOutstanding: 0)
    }
}

private func bbcaSecurity(price: Decimal) -> SecurityData {
    // Captured BBCA fundamentals (proxseer_collection-2.json, §14): ROE 22.41%, payout 63.17%,
    // ROA 3.54%, BVPS 2,102.07. Justified P/B ≈ 2.07 → IV ≈ 4,343.
    let ttm = TTMFinancials(eps: 471.10, bookValuePerShare: 2102.07, netIncome: 58_075 * oneB,
                            operatingCashFlow: 58_075 * oneB, totalAssets: 1_640_831 * oneB,
                            epsGrowthPct: 10.0, currentRatio: 0, debtToEquity: 0, returnOnEquity: 0.2241,
                            payoutRatio: 0.6317, returnOnAssets: 0.0354)
    return SecurityData(ticker: "BBCA", sector: "Keuangan", price: price,
                        sharesOutstanding: 123_270_000_000, freeFloatPct: 0.40,
                        financials: cleanBankFinancials(), ttm: ttm,
                        dailyBars: varyingStockBars(start: Double(truncating: price as NSNumber),
                                                    value: 80_000_000_000),
                        foreignNetFlow: [10 * oneB, -2 * oneB, 6 * oneB], brokerAccumulationSignal: 0.2,
                        sectorIndexBars: sectorIndexBars, marketIndexBars: marketIndexBars)
}

// MARK: - End-to-end audit trails

@Suite struct EndToEndAuditTrailTests {

    @Test func industrialRunsTheFullGrahamPathWithMeasuredTiming() async throws {
        let engine = StockSelectionEngine(provider: StubProvider(security: wifiSecurity()), config: .balanced)
        let r = try #require(try await engine.run().first, "a clean, cheap industrial should be recommended")
        #expect(r.ticker == "WIFI")

        // Intrinsic value is the net-current-asset floor: NCAV = (CA 10,000B − TL 2,000B)/1e9 = 8,000,
        // above the earnings-based Graham number √(22.5·900·2000) ≈ 6,364 — this cash-rich name is worth
        // at least its liquidation value (GrahamValuator: IV = max(Graham, NCAV); see GrahamValuatorTests).
        #expect(abs(r.intrinsicValue - 8000.0) < 1.0)
        #expect(r.marginOfSafety > 0.30)                                   // cheap → clears the neutral gate

        // The audit trail is the industrial pipeline, in order, end to end.
        #expect(r.audit.first == "regime=neutral")
        #expect(r.audit.contains("✓ DataIntegrity"))
        #expect(r.audit.contains("✓ Liquidity"))
        #expect(r.audit.contains("✓ Forensic"))
        #expect(r.audit.contains("✓ Solvency"))
        #expect(r.audit.contains { $0.hasPrefix("MoS ") && $0.contains("req 30%") })
        for id in ["GrahamValue ", "Quality ", "GrowthLynch ", "EarningsQuality "] {
            #expect(r.audit.contains { $0.hasPrefix(id) }, "missing \(id) score in audit")
        }
        #expect(r.audit.contains { $0.hasPrefix("flow ") })
        // Phase 4.1: timing engaged the rolling regression on the varying bars and recovered β 1.10/0.30.
        let timing = try #require(r.audit.first { $0.hasPrefix("timing ") })
        #expect(timing.contains("measured"))
        #expect(timing.contains("β 1.10/0.30"))
        #expect(r.audit.last?.hasPrefix("→ conviction ") == true)
    }

    @Test func bankRunsTheFinancialPathWithMeasuredTiming() async throws {
        // Priced at its BVPS (2,102) → P/B ≈ 1.0 vs justified ≈ 2.07 → MoS ≈ 52% → recommended.
        let engine = StockSelectionEngine(provider: StubProvider(security: bbcaSecurity(price: 2102)),
                                          config: .balanced)
        let r = try #require(try await engine.run().first, "a cheap bank should be recommended")
        #expect(r.ticker == "BBCA")
        #expect(abs(r.intrinsicValue - 4343.4) < 1.0)                      // JustifiedPBValuator, not Graham
        #expect(r.marginOfSafety > 0.30)

        // The audit proves the BANK profile ran — capital-strength + bank scorers, never the industrial
        // Solvency/Forensic gates or the Graham value scorer.
        #expect(r.audit.contains("✓ CapitalStrength"))
        for id in ["BankValue ", "BankQuality ", "BankEarningsQuality "] {
            #expect(r.audit.contains { $0.hasPrefix(id) }, "missing \(id) score in audit")
        }
        #expect(!r.audit.contains { $0.contains("Solvency") })
        #expect(!r.audit.contains { $0.hasPrefix("GrahamValue ") })
        let timing = try #require(r.audit.first { $0.hasPrefix("timing ") })
        #expect(timing.contains("measured"))
        #expect(timing.contains("β 1.10/0.30"))
    }

    @Test func bankAtCapturedPriceIsScreenedOutByMoS() async throws {
        // BBCA at its captured price 5,066 (P/B 2.41) → justified 2.07 → negative MoS → not recommended.
        let engine = StockSelectionEngine(provider: StubProvider(security: bbcaSecurity(price: 5066)),
                                          config: .balanced)
        #expect(try await engine.run().isEmpty)
    }
}
