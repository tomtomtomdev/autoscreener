import Foundation
import Testing
@testable import Autoscreener

// MARK: - Regression: GrahamValuator — NCAV is a value FLOOR, never a ceiling.
//
// Regression Test pattern (tdd-kent-beck): the bug *is* the test. The industrial valuator combined the
// earnings-based Graham number with the asset-based NCAV using `min`, which valued a company *below* its
// own net current asset (liquidation) value and silently sank the margin-of-safety gate for any name
// with a positive NCAV — perversely punishing the cash-rich, low-debt balance sheets hardest.
//
// Grounded in the two listed Graham skills (consulted, not priors):
//   • intelligent-investor — the Graham Number √(22.5·EPS·BVPS) is a fair-value CEILING (it bakes in
//     P/E ≤ 15 and P/B ≤ 1.5); NCAV = (Current Assets − Total Liabilities)/shares is a *separate*
//     enterprising-investor deep-value screen ("buy below ⅔ of NCAV"). Two distinct valuation methods.
//   • graham-financial-statements — net current asset value is the "net-net" liquidation floor: a stock
//     below it is backed by liquid assets alone. A business is therefore worth AT LEAST its NCAV.
//
// Hence intrinsic value is the GREATER of the two — max, not min. NCAV can only RAISE intrinsic value.

@Suite struct GrahamValuatorTests {
    private let B: Decimal = 1_000_000_000

    /// EPS 100 · BVPS 1,000 ⇒ Graham number = √(22.5·100·1000) = √2,250,000 = exactly 1,500.
    /// `currentAssetsB`/`totalLiabilitiesB` are in billions; with 1e9 shares the per-share NCAV is
    /// simply (currentAssetsB − totalLiabilitiesB). Everything else is benign filler the valuator ignores.
    private func security(eps: Decimal = 100, bvps: Decimal = 1000, price: Decimal = 1000,
                          currentAssetsB: Decimal, totalLiabilitiesB: Decimal) -> SecurityData {
        let annual = AnnualFinancials(
            year: 2025, revenue: 1000 * B, netIncome: 100 * B, operatingCashFlow: 120 * B,
            totalAssets: 5000 * B, totalLiabilities: totalLiabilitiesB * B,
            currentAssets: currentAssetsB * B, currentLiabilities: 500 * B,
            shareholderEquity: 1000 * B, receivables: 50 * B, sharesOutstanding: B)
        let ttm = TTMFinancials(eps: eps, bookValuePerShare: bvps, netIncome: 100 * B,
                                operatingCashFlow: 120 * B, totalAssets: 5000 * B,
                                epsGrowthPct: 10, currentRatio: 2.0, debtToEquity: 0.5, returnOnEquity: 0.15)
        return SecurityData(ticker: "TEST", sector: "Industrials", price: price,
                            sharesOutstanding: B, freeFloatPct: 0.4, financials: [annual], ttm: ttm,
                            dailyBars: [], foreignNetFlow: [], brokerAccumulationSignal: 0,
                            sectorIndexBars: [], marketIndexBars: [])
    }

    /// THE BUG: a profitable company with a positive NCAV (500) *below* its Graham number (1,500). The
    /// going-concern value is the Graham number; the lower liquidation floor must not drag it down.
    /// Under the old `min` this returned 500 — valuing the business below its own net liquid assets.
    @Test func positiveNCAVBelowGrahamDoesNotDragIntrinsicValueDown() {
        let s = security(currentAssetsB: 1500, totalLiabilitiesB: 1000)   // NCAV/share = 500
        let iv = GrahamValuator().intrinsicValue(s, config: .balanced)
        #expect(abs(iv - 1500) < 1e-6)
    }

    /// THE FLOOR (triangulation): when NCAV (3,000) *exceeds* the Graham number (1,500) — a genuinely
    /// cash-rich balance sheet — the business is worth at least its net liquid assets, so NCAV binds.
    @Test func positiveNCAVAboveGrahamBecomesTheIntrinsicValueFloor() {
        let s = security(currentAssetsB: 4000, totalLiabilitiesB: 1000)   // NCAV/share = 3,000
        let iv = GrahamValuator().intrinsicValue(s, config: .balanced)
        #expect(abs(iv - 3000) < 1e-6)
    }

    /// No regression for the common case: a going concern whose liabilities exceed its current assets has
    /// a non-positive NCAV (not a candidate), so intrinsic value stays the Graham number.
    @Test func nonPositiveNCAVLeavesIntrinsicValueAtTheGrahamNumber() {
        let s = security(currentAssetsB: 800, totalLiabilitiesB: 1000)    // NCAV/share = −200 ⇒ dropped
        let iv = GrahamValuator().intrinsicValue(s, config: .balanced)
        #expect(abs(iv - 1500) < 1e-6)
    }

    /// The gate consequence the bug caused: at price 1,000 the corrected IV (1,500) gives MoS = +33%,
    /// which clears the neutral 30% floor. Under the old `min` (IV 500) MoS was −100% — the cheap, clean
    /// name was wrongly screened out.
    @Test func marginOfSafetyUsesTheCorrectedFloorNotTheCollapsedNCAV() {
        let s = security(price: 1000, currentAssetsB: 1500, totalLiabilitiesB: 1000)
        let mos = GrahamValuator().marginOfSafety(s, config: .balanced)
        #expect(abs(mos - (1.0 / 3.0)) < 1e-6)
    }
}
