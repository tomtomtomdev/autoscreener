// StockSelectionEngine.swift
//
// IDX Stock-Selection Algorithm — reference specification in Swift 6.
// REFACTORED: every tunable knob now lives in a single `SelectionConfig`
// value type (Codable + Sendable), injected through every stage. Ship named
// presets (.defensive / .balanced / .deepValue / .growth) or load a config as
// JSON from your backend. Nothing in the pipeline reads a hardcoded threshold.
//
// What is ABSOLUTE (theory, not in config): accounting identities and the
// margin-of-safety / PEG formula *definitions*. The Graham constant 22.5 is a
// convention, so it IS exposed in config (valuation.grahamConstant) for sweeps.
//
// PIPELINE (unchanged):
//   Regime ─▶ policy (exposure/MoS/caps)            [never picks names]
//   Universe ─▶ hard gates ─▶ MoS gate ─▶ scorers ─▶ capped flow+timing
//            ─▶ composite ─▶ rank ─▶ constrained sizing ─▶ audited picks
//
// Reference spec, not a compiled build. Presets are starting points to sweep
// against your own paper-trading results — not advice.

import Foundation

// MARK: - 0. Primitives

typealias Ticker = String
typealias Score = Double
typealias Ratio = Double
typealias Rupiah = Decimal

enum MarketRegime: String, Sendable, Codable { case riskOn, neutral, riskOff }

enum LynchCategory: String, Sendable, Codable {
    case slowGrower, stalwart, fastGrower, cyclical, turnaround, assetPlay
}

enum ScorerID: String, Sendable, Codable {
    case grahamValue = "GrahamValue"
    case quality = "Quality"
    case growthLynch = "GrowthLynch"
    case earningsQuality = "EarningsQuality"
    // Financial-archetype scorers (§14). Distinct ids so the audit trail is honest about which model
    // ran; they reuse the matching base weight (value/quality/earnings) via `Weights.base`.
    case bankValue = "BankValue"
    case bankQuality = "BankQuality"
    case bankEarningsQuality = "BankEarningsQuality"
}

enum Verdict: Sendable { case pass, fail(reason: String) }

struct ScoreComponent: Sendable {
    let id: ScorerID
    let value: Score        // 0...1; weight is applied by the engine from config
    let rationale: String
}

// MARK: - 1. CONFIG — the single calibration surface

struct SelectionConfig: Sendable, Codable {

    struct Liquidity: Sendable, Codable {
        var minAvgDailyValue: Rupiah        // ADV floor
        var minFreeFloat: Ratio
        var advWindow: Int                  // lookback bars
    }
    struct DataIntegrity: Sendable, Codable {
        var minYearsFinancials: Int
        var minTradingDays: Int
    }
    struct Forensic: Sendable, Codable {
        var recentYears: Int
        var cfoToNiFloor: Double            // fail if CFO < NI*floor across recentYears
        var receivablesVsRevenueGap: Double // fail if recv growth > rev growth + gap
        var accrualsMax: Double             // fail if (NI-CFO)/assets > max
    }
    struct Solvency: Sendable, Codable {
        var minCurrentRatio: Ratio
        var maxDebtToEquity: Ratio
    }
    struct ValuationParams: Sendable, Codable {
        var grahamConstant: Double          // conventionally 22.5
        var useGrahamNumber: Bool
        var useNCAV: Bool
    }
    struct Weights: Sendable, Codable {     // base scorer weights (pre-tilt)
        var grahamValue: Double
        var quality: Double
        var growthLynch: Double
        var earningsQuality: Double
        func base(_ id: ScorerID) -> Double {
            switch id {
            case .grahamValue, .bankValue: return grahamValue
            case .quality, .bankQuality: return quality
            case .growthLynch: return growthLynch
            case .earningsQuality, .bankEarningsQuality: return earningsQuality
            }
        }
    }
    struct GrahamValueParams: Sendable, Codable {
        var mosFullCreditAt: Double         // MoS that earns full sub-credit
        var mosSubWeight: Double
        var pbTarget: Double
        var pbSubWeight: Double
        var currentRatioSpan: Double
        var currentRatioSubWeight: Double
    }
    struct QualityParams: Sendable, Codable {
        var roeFloor: Double
        var roeSpan: Double
        var roeSubWeight: Double
        var marginYears: Int
        var marginConsistencySubWeight: Double
        var earningsTrendSubWeight: Double
    }
    struct GrowthParams: Sendable, Codable {
        var pegFullCreditCeiling: Double    // PEG mapped 0→ceiling onto 1→0
    }
    struct EarningsQualityParams: Sendable, Codable {
        var recentYears: Int
        var cfoNiFloor: Double
        var cfoNiSpan: Double
    }
    struct FlowParams: Sendable, Codable {
        var cap: Double                     // max |modifier|
        var foreignWindow: Int
    }
    struct TimingParams: Sendable, Codable {
        var cap: Double
        // FALLBACK betas (§13-A2): used only when the per-name rolling regression can't be run
        // (insufficient or degenerate bars). When it can, `Modifiers.timing` uses the MEASURED betas
        // from `FactorRegression` instead, and the audit trail records which was used.
        var marketBeta: Double
        var sectorBeta: Double
        var returnWindow: Int
        var maPeriod: Int
        var healthyExtensionMax: Double     // up to this above MA = constructive
        var chasingExtensionMin: Double     // beyond this = penalise (spike chasing)
        // Rolling-regression lookback: how many of the most-recent daily returns the measured betas
        // are estimated over (one trading year ≈ 252). Defaulted so existing call sites are unchanged.
        var betaLookback: Int = 252
    }
    struct Sizing: Sendable, Codable {
        var portfolioValue: Double
        var liquidityParticipation: Double  // % of ADV we'd take
        var liquidityExitDays: Double       // exit within N days
        var advWindow: Int
        var minWeightFloor: Ratio           // ignore positions smaller than this
    }
    /// Financial-archetype (bank) calibration surface (§14). Read only by the `.financial`
    /// SelectionProfile; the industrial path never touches it. The valuation rates and beta are
    /// placeholders to sweep against paper-trading, exactly like the industrial `TimingParams` betas.
    struct BankParams: Sendable, Codable {
        // Capital-strength gate — the available CAR proxy: Common Equity ÷ Total Assets ≥ floor.
        var minEquityToAssets: Ratio
        // Justified-P/B valuation: Ke = riskFreeRate + beta·equityRiskPremium; g = (1−payout)·ROE capped ≤ Rf.
        var riskFreeRate: Double            // IDR 10y ≈ 0.065
        var equityRiskPremium: Double       // Damodaran Indonesia ERP ≈ 0.07
        var beta: Double                    // placeholder bank beta ≈ 1.0–1.2 (§13-A2)
        // Bank value scorer: how far actual P/B sits below the ROE-justified P/B earns full credit at…
        var pbDiscountFullCreditAt: Double
        // Bank quality scorer: ROE + ROA (efficiency/cost-to-income skipped in v1 — not structured, §14).
        var roeFloor: Double, roeSpan: Double, roeSubWeight: Double
        var roaFloor: Double, roaSpan: Double, roaSubWeight: Double
        // Bank earnings-quality scorer: net-income-growth stability + payout sustainability.
        var earningsYears: Int
        var stabilitySubWeight: Double
        var payoutCeiling: Double           // payout above this is treated as less sustainable
        var payoutSubWeight: Double
    }
    /// Slice 6 captured-endpoint tilt surfaces — small, capped overlays layered on the fundamental
    /// composite (parallel to `flow`/`timing`), each inert when its overlay is absent. All sweepable.
    struct RelativeValueParams: Sendable, Codable {
        var cap: Double                     // max |modifier|
        // Lower-is-cheaper valuation metrics (verified `fitem_name`s from the comparison/v2/ratios
        // capture). The subject is compared against its INDUSTRY and SECTOR benchmark columns on each.
        var cheaperMetricNames: [String]
    }
    struct SeasonalityParams: Sendable, Codable {
        var cap: Double                     // max |modifier|
        var avgReturnSpanPct: Double        // avg monthly % return mapped onto a full-magnitude signal
    }
    struct AccumulationParams: Sendable, Codable {
        var cap: Double                     // max |modifier|
        var topConcentrationN: Int          // top-N buying brokers for the surfaced buy-concentration read
    }
    struct RegimeParams: Sendable, Codable {
        struct RiskWeights: Sendable, Codable {
            var valuationPercentile: Double // multiplied by 0..1 percentile
            var belowTrend: Double
            var breadthInverse: Double      // multiplied by (1 - breadth)
            var idrWeakening: Double
            var biRateRising: Double
            var foreignOutflow: Double
            var noCommodityTailwind: Double
        }
        var riskWeights: RiskWeights
        var riskOnMax: Double               // risk < this → riskOn
        var neutralMax: Double              // risk < this → neutral, else riskOff
        var riskOnPolicy: RegimePolicy
        var neutralPolicy: RegimePolicy
        var riskOffPolicy: RegimePolicy
    }

    var liquidity: Liquidity
    var dataIntegrity: DataIntegrity
    var forensic: Forensic
    var solvency: Solvency
    var valuation: ValuationParams
    var weights: Weights
    var grahamValue: GrahamValueParams
    var quality: QualityParams
    var growth: GrowthParams
    var earningsQuality: EarningsQualityParams
    var flow: FlowParams
    var timing: TimingParams
    var sizing: Sizing
    var regime: RegimeParams
    var bank: BankParams
    var relativeValue: RelativeValueParams
    var seasonality: SeasonalityParams
    var accumulation: AccumulationParams
}

/// What the regime is ALLOWED to set — never which stock to buy. Now Codable so
/// the three templates live inside the config (and can come from the backend).
struct RegimePolicy: Sendable, Codable {
    var regime: MarketRegime
    var minMarginOfSafety: Ratio
    var maxTotalExposure: Ratio
    var maxPositionPct: Ratio
    var maxSectorPct: Ratio
    var maxNames: Int
    var weightTilt: [String: Double]    // keyed by ScorerID.rawValue
}

// MARK: - 1b. Presets (copy-and-tweak the balanced base)

extension SelectionConfig {

    static let balanced: SelectionConfig = .init(
        liquidity: .init(minAvgDailyValue: 5_000_000_000, minFreeFloat: 0.15, advWindow: 20),
        dataIntegrity: .init(minYearsFinancials: 5, minTradingDays: 200),
        forensic: .init(recentYears: 3, cfoToNiFloor: 0.6, receivablesVsRevenueGap: 0.50, accrualsMax: 0.15),
        solvency: .init(minCurrentRatio: 1.0, maxDebtToEquity: 2.0),
        valuation: .init(grahamConstant: 22.5, useGrahamNumber: true, useNCAV: true),
        weights: .init(grahamValue: 0.30, quality: 0.25, growthLynch: 0.20, earningsQuality: 0.15),
        grahamValue: .init(mosFullCreditAt: 0.5, mosSubWeight: 0.6, pbTarget: 1.5,
                           pbSubWeight: 0.2, currentRatioSpan: 1.0, currentRatioSubWeight: 0.2),
        quality: .init(roeFloor: 0.10, roeSpan: 0.15, roeSubWeight: 0.5, marginYears: 5,
                       marginConsistencySubWeight: 0.3, earningsTrendSubWeight: 0.2),
        growth: .init(pegFullCreditCeiling: 1.5),
        earningsQuality: .init(recentYears: 3, cfoNiFloor: 0.6, cfoNiSpan: 0.6),
        flow: .init(cap: 0.05, foreignWindow: 10),
        timing: .init(cap: 0.05, marketBeta: 1.0, sectorBeta: 0.5, returnWindow: 20,
                      maPeriod: 50, healthyExtensionMax: 0.15, chasingExtensionMin: 0.30),
        sizing: .init(portfolioValue: 1_000_000_000, liquidityParticipation: 0.20,
                      liquidityExitDays: 5.0, advWindow: 20, minWeightFloor: 0.005),
        regime: .init(
            riskWeights: .init(valuationPercentile: 1.0, belowTrend: 0.25, breadthInverse: 0.5,
                               idrWeakening: 0.25, biRateRising: 0.15, foreignOutflow: 0.25,
                               noCommodityTailwind: 0.10),
            riskOnMax: 0.6, neutralMax: 1.1,
            riskOnPolicy: .init(regime: .riskOn, minMarginOfSafety: 0.20, maxTotalExposure: 0.90,
                                maxPositionPct: 0.12, maxSectorPct: 0.30, maxNames: 12,
                                weightTilt: ["GrowthLynch": 1.2]),
            neutralPolicy: .init(regime: .neutral, minMarginOfSafety: 0.30, maxTotalExposure: 0.65,
                                 maxPositionPct: 0.10, maxSectorPct: 0.25, maxNames: 10, weightTilt: [:]),
            riskOffPolicy: .init(regime: .riskOff, minMarginOfSafety: 0.45, maxTotalExposure: 0.35,
                                 maxPositionPct: 0.07, maxSectorPct: 0.20, maxNames: 6,
                                 weightTilt: ["Quality": 1.4, "EarningsQuality": 1.4, "GrowthLynch": 0.7])),
        bank: .init(minEquityToAssets: 0.06,
                    riskFreeRate: 0.065, equityRiskPremium: 0.07, beta: 1.1,
                    pbDiscountFullCreditAt: 0.5,
                    roeFloor: 0.10, roeSpan: 0.15, roeSubWeight: 0.5,
                    roaFloor: 0.005, roaSpan: 0.02, roaSubWeight: 0.3,
                    earningsYears: 5, stabilitySubWeight: 0.5, payoutCeiling: 0.8, payoutSubWeight: 0.5),
        relativeValue: .init(cap: 0.03, cheaperMetricNames: [
            "Current PE Ratio (Annualised)", "Current Price to Book Value", "EV to EBITDA (TTM)"]),
        seasonality: .init(cap: 0.02, avgReturnSpanPct: 5.0),
        accumulation: .init(cap: 0.03, topConcentrationN: 3))

    /// Stricter on quality/trust, lower exposure, fewer names.
    static var defensive: SelectionConfig {
        var c = balanced
        c.liquidity.minAvgDailyValue = 10_000_000_000
        c.liquidity.minFreeFloat = 0.20
        c.forensic.cfoToNiFloor = 0.7
        c.forensic.accrualsMax = 0.10
        c.solvency.maxDebtToEquity = 1.0
        c.weights = .init(grahamValue: 0.30, quality: 0.30, growthLynch: 0.10, earningsQuality: 0.30)
        c.regime.riskOnPolicy.maxTotalExposure = 0.70
        c.regime.neutralPolicy.maxTotalExposure = 0.50
        c.regime.riskOffPolicy.maxTotalExposure = 0.20
        c.regime.riskOnPolicy.minMarginOfSafety = 0.30
        c.regime.neutralPolicy.minMarginOfSafety = 0.40
        c.regime.riskOffPolicy.minMarginOfSafety = 0.55
        c.regime.riskOnPolicy.maxNames = 8; c.regime.neutralPolicy.maxNames = 7; c.regime.riskOffPolicy.maxNames = 4
        return c
    }

    /// Graham deep-value tilt: statistical cheapness + NCAV floor over growth.
    static var deepValue: SelectionConfig {
        var c = balanced
        c.weights = .init(grahamValue: 0.45, quality: 0.20, growthLynch: 0.05, earningsQuality: 0.30)
        c.grahamValue.pbTarget = 1.0
        c.grahamValue.mosFullCreditAt = 0.6
        c.valuation.useNCAV = true
        c.regime.neutralPolicy.minMarginOfSafety = 0.35
        c.regime.riskOnPolicy.weightTilt = [:]   // don't reward growth even when risk-on
        return c
    }

    /// Lynch/Fisher growth-at-reasonable-price tilt: looser MoS, higher PEG ceiling.
    static var growth: SelectionConfig {
        var c = balanced
        c.weights = .init(grahamValue: 0.15, quality: 0.30, growthLynch: 0.40, earningsQuality: 0.15)
        c.growth.pegFullCreditCeiling = 2.0
        c.solvency.maxDebtToEquity = 2.5
        c.regime.riskOnPolicy.minMarginOfSafety = 0.10
        c.regime.neutralPolicy.minMarginOfSafety = 0.20
        c.regime.riskOnPolicy.maxNames = 15
        c.regime.riskOnPolicy.weightTilt = ["GrowthLynch": 1.4, "Quality": 1.1]
        return c
    }
}

// MARK: - 2. Input data (unchanged)

struct SecurityData: Sendable {
    let ticker: Ticker
    let sector: String
    let price: Rupiah
    let sharesOutstanding: Decimal
    let freeFloatPct: Ratio
    let financials: [AnnualFinancials]
    let ttm: TTMFinancials
    let dailyBars: [OHLCV]
    let foreignNetFlow: [Rupiah]
    let brokerAccumulationSignal: Double
    let sectorIndexBars: [OHLCV]
    let marketIndexBars: [OHLCV]
    // Captured-endpoint overlays (Slice 4) — best-effort, carried context only. No gate or scorer
    // reads them yet; feeding them into scoring is a separate, tested calibration pass. Absent
    // (paywall / no coverage / fetch failure) ⇒ nil, which never blocks or mis-scores a pick.
    var peerComparison: PeerComparison? = nil        // comparison/v2/ratios — vs INDUSTRY/SECTOR
    var seasonality: Seasonality? = nil              // seasonality/{SYM} — monthly win-rate overlay
    var brokerDistribution: BrokerDistribution? = nil // order-trade/broker/distribution — bandar concentration
}

struct AnnualFinancials: Sendable {
    let year: Int
    let revenue, netIncome, operatingCashFlow, totalAssets, totalLiabilities: Rupiah
    let currentAssets, currentLiabilities, shareholderEquity, receivables: Rupiah
    let sharesOutstanding: Decimal
}
struct TTMFinancials: Sendable {
    let eps, bookValuePerShare: Decimal
    let netIncome, operatingCashFlow, totalAssets: Rupiah
    let epsGrowthPct, currentRatio, debtToEquity, returnOnEquity: Double
    // Universal fundamentals the financial profile consumes (industrial path ignores them):
    // payout drives the bank valuator's growth g = (1−payout)·ROE; ROA feeds the bank quality scorer.
    var payoutRatio: Double = 0
    var returnOnAssets: Double = 0
}
struct OHLCV: Sendable {
    let date: Date
    let open, high, low, close, volume: Decimal
    let value: Rupiah
}

// MARK: - 3. Stage protocols (now config-driven)

protocol Gate: Sendable {
    var name: String { get }
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict
}
protocol Scorer: Sendable {
    var id: ScorerID { get }
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent
}

// MARK: - 4. Regime assessment

struct MarketContext: Sendable {
    let indexValuationPercentile: Double
    let breadthAbove200dma: Double
    let indexAbove200dma: Bool
    let idrWeakeningTrend: Bool
    let biRateRising: Bool
    let marketForeignFlowNet: Rupiah
    let commodityTailwind: Bool
    // Market-wide accumulation leaderboard (Slice 4, order-trade/top-stock). Carried context only —
    // no regime input reads it yet; absent ⇒ nil.
    var flowLeaders: FlowLeaderboard? = nil
}

enum RegimeAssessor {
    static func assess(_ c: MarketContext, config: SelectionConfig) -> RegimePolicy {
        let w = config.regime.riskWeights
        var risk = 0.0
        risk += c.indexValuationPercentile * w.valuationPercentile
        risk += c.indexAbove200dma ? 0 : w.belowTrend
        risk += (1.0 - c.breadthAbove200dma) * w.breadthInverse
        risk += c.idrWeakeningTrend ? w.idrWeakening : 0
        risk += c.biRateRising ? w.biRateRising : 0
        risk += (c.marketForeignFlowNet < 0) ? w.foreignOutflow : 0
        risk += c.commodityTailwind ? 0 : w.noCommodityTailwind

        if risk < config.regime.riskOnMax { return config.regime.riskOnPolicy }
        if risk < config.regime.neutralMax { return config.regime.neutralPolicy }
        return config.regime.riskOffPolicy
    }
}

// MARK: - 5. Hard gates

struct DataIntegrityGate: Gate {
    let name = "DataIntegrity"
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict {
        if s.financials.count < config.dataIntegrity.minYearsFinancials { return .fail(reason: "<\(config.dataIntegrity.minYearsFinancials)y financials") }
        if s.dailyBars.count < config.dataIntegrity.minTradingDays { return .fail(reason: "<\(config.dataIntegrity.minTradingDays) bars") }
        return .pass
    }
}
struct LiquidityGate: Gate {
    let name = "Liquidity"
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict {
        let w = s.dailyBars.suffix(config.liquidity.advWindow)
        guard !w.isEmpty else { return .fail(reason: "no price history") }
        let adv = w.map(\.value).reduce(0, +) / Decimal(w.count)
        if adv < config.liquidity.minAvgDailyValue { return .fail(reason: "thin ADV") }
        if s.freeFloatPct < config.liquidity.minFreeFloat { return .fail(reason: "low free float") }
        return .pass
    }
}
struct ForensicGate: Gate {
    let name = "Forensic"
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict {
        let f = config.forensic
        let recent = s.financials.suffix(f.recentYears)
        if recent.allSatisfy({ $0.operatingCashFlow < ($0.netIncome * Decimal(f.cfoToNiFloor)) }) {
            return .fail(reason: "CFO persistently << NI")
        }
        if let a = recent.first, let b = recent.last, a.revenue > 0, a.receivables > 0 {
            if pctChange(b.receivables, a.receivables) > pctChange(b.revenue, a.revenue) + f.receivablesVsRevenueGap {
                return .fail(reason: "receivables outpacing revenue")
            }
        }
        if let last = recent.last, last.totalAssets > 0 {
            let accruals = nsDouble(last.netIncome - last.operatingCashFlow) / nsDouble(last.totalAssets)
            if accruals > f.accrualsMax { return .fail(reason: "high accruals \(round2(accruals))") }
        }
        return .pass
    }
}
struct SolvencyGate: Gate {
    let name = "Solvency"
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict {
        if s.ttm.currentRatio < config.solvency.minCurrentRatio { return .fail(reason: "current ratio low") }
        if s.ttm.debtToEquity > config.solvency.maxDebtToEquity { return .fail(reason: "D/E high") }
        return .pass
    }
}
/// Capital-strength gate for financials (§14): the available CAR proxy — Common Equity ÷ Total Assets
/// ≥ a floor. Common Equity is reconstructed as BVPS × shares outstanding, so no extra field is
/// needed. Replaces `SolvencyGate` on the financial profile (a bank's current ratio / D/E are "-");
/// audit-trailed as a proxy so it is never mistaken for a true regulatory CAR.
struct CapitalStrengthGate: Gate {
    let name = "CapitalStrength"
    func evaluate(_ s: SecurityData, config: SelectionConfig, policy: RegimePolicy) -> Verdict {
        let assets = nsDouble(s.ttm.totalAssets)
        guard assets > 0 else { return .fail(reason: "no asset base") }
        let equity = nsDouble(s.ttm.bookValuePerShare * s.sharesOutstanding)
        let ratio = equity / assets
        if ratio < config.bank.minEquityToAssets { return .fail(reason: "thin capital \(pct(ratio))") }
        return .pass
    }
}

// MARK: - 6. Scorers

struct GrahamValueScorer: Scorer {
    let id = ScorerID.grahamValue
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let p = config.grahamValue
        let price = nsDouble(s.price), eps = nsDouble(s.ttm.eps), bvps = nsDouble(s.ttm.bookValuePerShare)
        var v: Score = 0; var why: [String] = []
        if eps > 0, bvps > 0 {
            let graham = (config.valuation.grahamConstant * eps * bvps).squareRoot()
            let mos = (graham - price) / graham
            v += clamp01(mos / p.mosFullCreditAt) * p.mosSubWeight
            why.append("GrahamNo \(Int(graham)) MoS \(pct(mos))")
        }
        let pb = bvps > 0 ? price / bvps : .infinity
        v += clamp01((p.pbTarget - pb) / p.pbTarget) * p.pbSubWeight; why.append("P/B \(round2(pb))")
        v += clamp01((s.ttm.currentRatio - 1.0) / p.currentRatioSpan) * p.currentRatioSubWeight
        return .init(id: id, value: clamp01(v), rationale: why.joined(separator: " · "))
    }
}
struct QualityScorer: Scorer {
    let id = ScorerID.quality
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let p = config.quality
        var v: Score = 0
        v += clamp01((s.ttm.returnOnEquity - p.roeFloor) / p.roeSpan) * p.roeSubWeight
        let margins = s.financials.suffix(p.marginYears).map { $0.revenue > 0 ? nsDouble($0.netIncome)/nsDouble($0.revenue) : 0 }
        v += clamp01(consistency(margins)) * p.marginConsistencySubWeight
        let earnings = s.financials.suffix(p.marginYears).map { nsDouble($0.netIncome) }
        v += monotoneUp(earnings) ? p.earningsTrendSubWeight : 0
        return .init(id: id, value: clamp01(v), rationale: "ROE \(pct(s.ttm.returnOnEquity)) · margin-stable")
    }
}
struct GrowthLynchScorer: Scorer {
    let id = ScorerID.growthLynch
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let price = nsDouble(s.price), eps = nsDouble(s.ttm.eps)
        let pe = eps > 0 ? price / eps : .infinity
        let g = max(s.ttm.epsGrowthPct, 0.01)
        let peg = pe / g
        let ceil = config.growth.pegFullCreditCeiling
        return .init(id: id, value: clamp01((ceil - peg) / ceil),
                     rationale: "PEG \(round2(peg)) (P/E \(round2(pe)) g \(g)%)")
    }
}
struct EarningsQualityScorer: Scorer {
    let id = ScorerID.earningsQuality
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let p = config.earningsQuality
        let r = s.financials.suffix(p.recentYears)
        let cover = r.map { $0.netIncome > 0 ? nsDouble($0.operatingCashFlow)/nsDouble($0.netIncome) : 1 }
        let avg = cover.reduce(0,+) / Double(max(cover.count,1))
        return .init(id: id, value: clamp01((avg - p.cfoNiFloor) / p.cfoNiSpan),
                     rationale: "CFO/NI \(round2(avg))")
    }
}

// MARK: - 6b. Financial-archetype scorers (§14)

/// Bank "value": cheapness *given ROE* — how far the actual P/B sits below the ROE-justified P/B
/// (Damodaran's P/B↔ROE companion-variable framing). 0 when fairly/richly priced or unscoreable.
struct BankValueScorer: Scorer {
    let id = ScorerID.bankValue
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let bvps = nsDouble(s.ttm.bookValuePerShare)
        guard bvps > 0, s.ttm.returnOnEquity > 0,
              let justified = BankValuation.justifiedPriceToBook(roe: s.ttm.returnOnEquity,
                                                                 payout: s.ttm.payoutRatio,
                                                                 bank: config.bank),
              justified > 0
        else { return .init(id: id, value: 0, rationale: "P/B not scoreable") }
        let actual = nsDouble(s.price) / bvps
        let discount = (justified - actual) / justified
        let v = clamp01(discount / config.bank.pbDiscountFullCreditAt)
        return .init(id: id, value: v, rationale: "P/B \(round2(actual)) vs justified \(round2(justified))")
    }
}

/// Bank "quality": return on equity + return on assets (efficiency / cost-to-income skipped in v1 —
/// not available as structured data, §14). The two sub-scores are weighted and clamped.
struct BankQualityScorer: Scorer {
    let id = ScorerID.bankQuality
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let b = config.bank
        var v: Score = 0
        v += clamp01((s.ttm.returnOnEquity - b.roeFloor) / b.roeSpan) * b.roeSubWeight
        v += clamp01((s.ttm.returnOnAssets - b.roaFloor) / b.roaSpan) * b.roaSubWeight
        return .init(id: id, value: clamp01(v),
                     rationale: "ROE \(pct(s.ttm.returnOnEquity)) · ROA \(pct(s.ttm.returnOnAssets))")
    }
}

/// Bank "earnings quality": net-income-growth stability + payout sustainability (CFO/NI is noisy for
/// banks, §14). Stability is the consistency of the year-over-year net-income growth rates; payout is
/// sustainable up to a ceiling, fading to 0 as it approaches paying out every rupiah of earnings.
struct BankEarningsQualityScorer: Scorer {
    let id = ScorerID.bankEarningsQuality
    func score(_ s: SecurityData, config: SelectionConfig) -> ScoreComponent {
        let b = config.bank
        let nis = s.financials.suffix(b.earningsYears).map { nsDouble($0.netIncome) }
        let growths = zip(nis, nis.dropFirst()).map { $0 == 0 ? 0 : ($1 - $0) / $0 }
        let stability = consistency(growths)
        let payout = s.ttm.payoutRatio
        let payoutCredit = payout <= b.payoutCeiling
            ? 1.0
            : clamp01((1 - payout) / max(1 - b.payoutCeiling, 1e-9))
        let v = clamp01(b.stabilitySubWeight * stability + b.payoutSubWeight * payoutCredit)
        return .init(id: id, value: v, rationale: "NI-growth stable · payout \(pct(payout))")
    }
}

// MARK: - 7. Valuation & margin of safety

/// Computes per-share intrinsic value and the margin of safety against price. Behind a protocol
/// (DIP) so each `CompanyArchetype` can supply its own intrinsic-value model — the industrial
/// `GrahamValuator` below today, a P/B-vs-ROE bank valuator in Phase 3 — while the engine's MoS
/// gate, composite, and sizing stay archetype-agnostic.
protocol Valuator: Sendable {
    func intrinsicValue(_ s: SecurityData, config: SelectionConfig) -> Double
    func marginOfSafety(_ s: SecurityData, config: SelectionConfig) -> Ratio
}
extension Valuator {
    /// MoS is the same ratio for every archetype once intrinsic value is known, so it has a single
    /// shared definition; only `intrinsicValue` varies by profile.
    func marginOfSafety(_ s: SecurityData, config: SelectionConfig) -> Ratio {
        let iv = intrinsicValue(s, config: config); guard iv > 0 else { return -1 }
        return (iv - nsDouble(s.price)) / iv
    }
}

/// Industrial intrinsic value: min(Graham number, NCAV/share), gated by config. This is the
/// pre-Phase-2 `Valuator` logic verbatim — only its home changed (free enum → protocol witness).
struct GrahamValuator: Valuator {
    func intrinsicValue(_ s: SecurityData, config: SelectionConfig) -> Double {
        var candidates: [Double] = []
        let eps = nsDouble(s.ttm.eps), bvps = nsDouble(s.ttm.bookValuePerShare)
        if config.valuation.useGrahamNumber, eps > 0, bvps > 0 {
            candidates.append((config.valuation.grahamConstant * eps * bvps).squareRoot())
        }
        if config.valuation.useNCAV, let f = s.financials.last, f.sharesOutstanding > 0 {
            let ncav = nsDouble(f.currentAssets - f.totalLiabilities) / nsDouble(f.sharesOutstanding)
            if ncav > 0 { candidates.append(ncav) }
        }
        return candidates.min() ?? 0
    }
}

/// Pure ROE-justified price-to-book math (§14), shared by the bank valuator and the bank value scorer
/// (DRY). P/B's companion variable is ROE (Damodaran): a bank is cheap only relative to the multiple
/// its return on equity justifies.
enum BankValuation {
    /// Stable-growth justified P/B = (ROE − g) / (Ke − g), or nil when the inputs degenerate (Ke ≤ g).
    /// g = (1 − payout) · ROE capped at ≤ Rf (terminal discipline); Ke = Rf + β·ERP (cost of equity).
    /// Callers guard ROE > 0 and BVPS > 0.
    static func justifiedPriceToBook(roe: Double, payout: Double, bank: SelectionConfig.BankParams) -> Double? {
        let retention = 1 - max(0, min(1, payout))
        let g = min(retention * roe, bank.riskFreeRate)
        let ke = bank.riskFreeRate + bank.beta * bank.equityRiskPremium
        guard ke > g else { return nil }
        return (roe - g) / (ke - g)
    }
}

/// Financial-firm intrinsic value (§14): value equity directly off the ROE-justified P/B multiple
/// (IV = justified P/B × BVPS), not Graham/NCAV — a bank has no meaningful current/non-current split
/// and WACC is meaningless for it. MoS reuses the protocol default. Returns 0 (no value, so the MoS
/// gate screens it out) for a loss-maker, a non-positive book value, or a degenerate Ke ≤ g.
struct JustifiedPBValuator: Valuator {
    func intrinsicValue(_ s: SecurityData, config: SelectionConfig) -> Double {
        let bvps = nsDouble(s.ttm.bookValuePerShare)
        guard s.ttm.returnOnEquity > 0, bvps > 0,
              let pb = BankValuation.justifiedPriceToBook(roe: s.ttm.returnOnEquity,
                                                          payout: s.ttm.payoutRatio,
                                                          bank: config.bank)
        else { return 0 }
        return pb * bvps
    }
}

// MARK: - 8. Capped modifiers

enum Modifiers {
    static func flow(_ s: SecurityData, config: SelectionConfig) -> (Double, String) {
        let cap = config.flow.cap
        let recent = s.foreignNetFlow.suffix(config.flow.foreignWindow).map(nsDouble).reduce(0,+)
        let sign = recent > 0 ? 1.0 : (recent < 0 ? -1.0 : 0.0)
        let raw = (sign + s.brokerAccumulationSignal) / 2.0
        return (max(-cap, min(cap, raw * cap)), "foreign \(recent >= 0 ? "+" : "-") · broker \(round2(s.brokerAccumulationSignal))")
    }
    static func timing(_ s: SecurityData, config: SelectionConfig) -> (Double, String) {
        let t = config.timing
        guard s.dailyBars.count > t.returnWindow, s.marketIndexBars.count > t.returnWindow,
              s.sectorIndexBars.count > t.returnWindow, let last = s.dailyBars.last
        else { return (0, "insufficient bars") }
        // §13-A2: measure the name's own betas by rolling regression; fall back to the configured
        // placeholders only when the bars are insufficient/degenerate. Surface which was used so the
        // audit trail is honest about whether the timing read is calibrated or approximate.
        let measured = FactorRegression.betas(stock: s.dailyBars, market: s.marketIndexBars,
                                              sector: s.sectorIndexBars, lookback: t.betaLookback)
        let bm = measured?.market ?? t.marketBeta
        let bs = measured?.sector ?? t.sectorBeta
        let stockR = ret(s.dailyBars, t.returnWindow)
        let mktR = ret(s.marketIndexBars, t.returnWindow)
        let secR = ret(s.sectorIndexBars, t.returnWindow)
        let idio = stockR - bm * mktR - bs * (secR - mktR)
        let ma = sma(s.dailyBars, t.maPeriod); let ext = (nsDouble(last.close) - ma) / ma
        var d = 0.0
        if idio > 0 { d += t.cap * 0.5 }
        if ext > 0, ext < t.healthyExtensionMax { d += t.cap * 0.5 }
        if ext > t.chasingExtensionMin { d -= t.cap }
        let betaSrc = "β \(round2(bm))/\(round2(bs)) \(measured != nil ? "measured" : "default")"
        return (max(-t.cap, min(t.cap, d)), "idio \(pct(idio)) · ext \(pct(ext)) · \(betaSrc)")
    }

    // Slice 6 captured-endpoint tilts. Each returns `(0, "")` — an EMPTY rationale — exactly when its
    // overlay is absent or unscoreable, which the engine reads as "don't apply, don't audit". A present
    // overlay always yields a non-empty rationale (even at a net-zero tilt), so the audit trail records
    // that the signal was considered. This keeps every overlay-less name byte-for-byte unchanged.

    /// Relative-value tilt from `peerComparison`: how cheap the subject is versus its INDUSTRY and
    /// SECTOR benchmark columns on lower-is-cheaper valuation metrics (PE / PBV / EV-EBITDA). Cheaper
    /// than BOTH benchmarks on a metric votes +1, richer than both −1, in-between 0; the mean vote
    /// across the metrics that are present and numeric scales the cap.
    static func relativeValue(_ s: SecurityData, config: SelectionConfig) -> (Double, String) {
        let p = config.relativeValue
        guard let peers = s.peerComparison, let subject = peers.subject else { return (0, "") }
        var votes: [Double] = []
        for name in p.cheaperMetricNames {
            guard let m = peers.metric(named: name),
                  let sv = m.numeric[subject],
                  let bench = m.numeric["INDUSTRY"] ?? m.numeric["SECTOR"] else { continue }
            let other = m.numeric["SECTOR"] ?? bench
            if sv < bench, sv < other { votes.append(1) }
            else if sv > bench, sv > other { votes.append(-1) }
            else { votes.append(0) }
        }
        guard !votes.isEmpty else { return (0, "") }
        let mean = votes.reduce(0, +) / Double(votes.count)
        return (max(-p.cap, min(p.cap, mean * p.cap)), "rel-value \(votes.count)m vote \(round2(mean))")
    }

    /// Seasonality timing tilt from `seasonality`: the current month's historical win-rate
    /// (`probabilityUpPct`, centred at 50) blended equally with its average return (`avgReturnPct`,
    /// normalised by `avgReturnSpanPct`). "Current month" is the latest daily bar's calendar month (UTC)
    /// — deterministic, no wall clock. A SOFT overlay only; never a gate (thin, survivorship-prone).
    static func seasonality(_ s: SecurityData, config: SelectionConfig) -> (Double, String) {
        let p = config.seasonality
        guard let seas = s.seasonality, let last = s.dailyBars.last?.date else { return (0, "") }
        let abbr = monthAbbrev(last)
        guard let m = seas.month(abbr) else { return (0, "") }
        let probSignal = clampSigned((m.probabilityUpPct - 50) / 50)
        let retSignal = clampSigned(m.avgReturnPct / max(p.avgReturnSpanPct, 1e-9))
        let blend = (probSignal + retSignal) / 2
        return (max(-p.cap, min(p.cap, blend * p.cap)),
                "\(abbr) P(up) \(Int(m.probabilityUpPct))% avg \(round2(m.avgReturnPct))%")
    }

    /// Smart-money accumulation tilt: per-ticker broker distribution (net buy-vs-sell imbalance, with the
    /// top-N buy concentration surfaced for context) combined with market-wide leaderboard membership
    /// (in today's top net-buy ⇒ +1, top net-sell ⇒ −1). Each available source contributes a value in
    /// [−1, 1]; their mean scales the cap.
    static func accumulation(_ s: SecurityData, leaders: FlowLeaderboard?,
                             config: SelectionConfig) -> (Double, String) {
        let p = config.accumulation
        var parts: [Double] = []
        var why: [String] = []
        if let dist = s.brokerDistribution {
            let tb = dist.totalBuyValue, ts = dist.totalSellValue
            if tb + ts > 0 {
                let imbalance = clampSigned((tb - ts) / (tb + ts))
                parts.append(imbalance)
                let conc = dist.buyConcentration(topN: p.topConcentrationN).map { round2($0) } ?? "n/a"
                why.append("net \(round2(imbalance)) · top\(p.topConcentrationN)-conc \(conc)")
            }
        }
        if let lb = leaders {
            if lb.topBuy.contains(where: { $0.code == s.ticker }) { parts.append(1); why.append("top-buy") }
            else if lb.topSell.contains(where: { $0.code == s.ticker }) { parts.append(-1); why.append("top-sell") }
        }
        guard !parts.isEmpty else { return (0, "") }
        let mean = parts.reduce(0, +) / Double(parts.count)
        return (max(-p.cap, min(p.cap, mean * p.cap)), why.joined(separator: " · "))
    }
}

// MARK: - 8b. Company archetype & selection profile (Phase 2 seam, §14)

/// How a company is screened. The pipeline core (regime → MoS gate → composite → rank → sizing) is
/// archetype-agnostic; only the *producers* of scores differ — which gates run, which scorers score,
/// and which intrinsic-value model applies. Open for `insurer` / `reit` later (YAGNI).
enum CompanyArchetype: String, Sendable, Codable {
    case industrial, financial

    /// Classify by IDX-IC sector (`SecurityData.sector`, from `/emitten/{SYM}/info.sector`). IDX-IC's
    /// financial sector is "Keuangan" (capture-verified on BBCA, §14); everything else is industrial.
    /// Case- and whitespace-insensitive.
    static func classify(sector: String) -> CompanyArchetype {
        sector.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == "keuangan"
            ? .financial : .industrial
    }
}

/// The strategy the engine runs for one security: its gates, scorers, and valuator. Selected per
/// name via `StockSelectionEngine.profileSelector` (DIP). Phase 2 ships only `.industrial`; Phase 3
/// adds a financial profile (bank gates/scorers + P/B-vs-ROE valuator) without touching the core.
struct SelectionProfile: Sendable {
    let archetype: CompanyArchetype
    let gates: [Gate]
    let scorers: [Scorer]
    let valuator: any Valuator
}

extension SelectionProfile {
    /// Today's industrial path: the existing gate/scorer order and the Graham valuator. The gate and
    /// scorer ordering is preserved exactly so the audit trail and composite stay byte-for-byte equal.
    static func industrial(_ config: SelectionConfig) -> SelectionProfile {
        SelectionProfile(
            archetype: .industrial,
            gates: [DataIntegrityGate(), LiquidityGate(), ForensicGate(), SolvencyGate()],
            scorers: [GrahamValueScorer(), QualityScorer(), GrowthLynchScorer(), EarningsQualityScorer()],
            valuator: GrahamValuator())
    }

    /// The financial (bank) path (§14): SolvencyGate → CapitalStrengthGate (current ratio / D/E are
    /// "-" for banks); Forensic dropped (receivables/accruals meaningless); Graham value/MoS → the
    /// P/B-vs-ROE bank scorers and `JustifiedPBValuator`. Growth (Lynch PEG) is reused but
    /// de-emphasised via the bank weighting. DataIntegrity, Liquidity, and the flow/timing/regime/
    /// sizing layers are archetype-agnostic and shared with the industrial path.
    static func financial(_ config: SelectionConfig) -> SelectionProfile {
        SelectionProfile(
            archetype: .financial,
            gates: [DataIntegrityGate(), LiquidityGate(), CapitalStrengthGate()],
            scorers: [BankValueScorer(), BankQualityScorer(), GrowthLynchScorer(), BankEarningsQualityScorer()],
            valuator: JustifiedPBValuator())
    }
}

// MARK: - 9. Output

struct Recommendation: Sendable {
    let ticker: Ticker
    let compositeScore: Double
    let intrinsicValue: Double
    let marginOfSafety: Ratio
    let conviction: Double
    let suggestedWeight: Ratio
    let audit: [String]
}

// MARK: - 10. Engine

protocol DataProvider: Sendable {
    func universe() async throws -> [Ticker]
    func data(for t: Ticker) async throws -> SecurityData
    func marketContext() async throws -> MarketContext
}

struct StockSelectionEngine: Sendable {
    let provider: DataProvider
    let config: SelectionConfig                 // <- the calibration surface
    let profileSelector: @Sendable (SecurityData) -> SelectionProfile   // <- archetype seam (DIP)

    init(provider: DataProvider,
         config: SelectionConfig = .balanced,
         profileSelector: (@Sendable (SecurityData) -> SelectionProfile)? = nil) {
        self.provider = provider
        self.config = config
        self.profileSelector = profileSelector ?? { Self.defaultProfile(for: $0, config: config) }
    }

    /// Default DIP wiring: classify the security, then pick its profile. Each archetype routes to its
    /// own profile — industrials to the Graham path, financials to the P/B-vs-ROE bank path (§14).
    static func defaultProfile(for s: SecurityData, config: SelectionConfig) -> SelectionProfile {
        switch CompanyArchetype.classify(sector: s.sector) {
        case .industrial: return .industrial(config)
        case .financial: return .financial(config)
        }
    }

    /// One scored survivor of the gate + MoS pass, carrying the valuator chosen for it so `allocate`
    /// reports the right intrinsic value per archetype.
    private struct Scored {
        let data: SecurityData
        let composite: Double
        let marginOfSafety: Ratio
        let audit: [String]
        let valuator: any Valuator
    }

    func run() async throws -> [Recommendation] {
        let context = try await provider.marketContext()
        let policy = RegimeAssessor.assess(context, config: config)
        if policy.maxTotalExposure <= 0 { return [] }

        var scored: [Scored] = []
        for t in try await provider.universe() {
            let s = try await provider.data(for: t)
            let profile = profileSelector(s)
            var audit = ["regime=\(policy.regime.rawValue)"]

            var eliminated = false
            for g in profile.gates {
                if case let .fail(reason) = g.evaluate(s, config: config, policy: policy) {
                    audit.append("✗ \(g.name): \(reason)"); eliminated = true; break
                }
                audit.append("✓ \(g.name)")
            }
            if eliminated { continue }

            let mos = profile.valuator.marginOfSafety(s, config: config)
            audit.append("MoS \(pct(mos)) vs req \(pct(policy.minMarginOfSafety))")
            if mos < policy.minMarginOfSafety { continue }

            var num = 0.0, den = 0.0
            for sc in profile.scorers {
                let c = sc.score(s, config: config)
                let w = config.weights.base(c.id) * (policy.weightTilt[c.id.rawValue] ?? 1.0)
                num += c.value * w; den += w
                audit.append("\(c.id.rawValue) \(round2(c.value)) — \(c.rationale)")
            }
            var composite = den > 0 ? num / den : 0
            let f = Modifiers.flow(s, config: config); composite += f.0; audit.append("flow \(signed(f.0)) [\(f.1)]")
            let tm = Modifiers.timing(s, config: config); composite += tm.0; audit.append("timing \(signed(tm.0)) [\(tm.1)]")
            // Slice 6 captured-endpoint tilts — applied (and audited) only when the overlay contributed,
            // so a name without the data is byte-for-byte unchanged.
            let rv = Modifiers.relativeValue(s, config: config)
            if !rv.1.isEmpty { composite += rv.0; audit.append("relValue \(signed(rv.0)) [\(rv.1)]") }
            let se = Modifiers.seasonality(s, config: config)
            if !se.1.isEmpty { composite += se.0; audit.append("seasonality \(signed(se.0)) [\(se.1)]") }
            let ac = Modifiers.accumulation(s, leaders: context.flowLeaders, config: config)
            if !ac.1.isEmpty { composite += ac.0; audit.append("accumulation \(signed(ac.0)) [\(ac.1)]") }
            composite = clamp01(composite)
            scored.append(Scored(data: s, composite: composite, marginOfSafety: mos,
                                 audit: audit, valuator: profile.valuator))
        }

        scored.sort { $0.composite > $1.composite }
        return allocate(scored, policy: policy)
    }

    private func allocate(_ ranked: [Scored], policy: RegimePolicy) -> [Recommendation] {
        var out: [Recommendation] = []; var deployed: Ratio = 0; var perSector: [String: Ratio] = [:]
        for item in ranked {
            let s = item.data
            if out.count >= policy.maxNames || deployed >= policy.maxTotalExposure { break }
            let conviction = item.composite
            var weight = conviction * policy.maxPositionPct
            weight = min(weight, policy.maxTotalExposure - deployed)
            weight = min(weight, policy.maxSectorPct - perSector[s.sector, default: 0])
            weight = min(weight, liquidityCap(s))
            if weight <= config.sizing.minWeightFloor { continue }
            deployed += weight; perSector[s.sector, default: 0] += weight
            var trail = item.audit; trail.append("→ conviction \(round2(conviction)) weight \(pct(weight))")
            out.append(.init(ticker: s.ticker, compositeScore: item.composite,
                             intrinsicValue: item.valuator.intrinsicValue(s, config: config),
                             marginOfSafety: item.marginOfSafety, conviction: conviction,
                             suggestedWeight: weight, audit: trail))
        }
        return out
    }

    private func liquidityCap(_ s: SecurityData) -> Ratio {
        let z = config.sizing
        let adv = nsDouble(s.dailyBars.suffix(z.advWindow).map(\.value).reduce(0,+)) / Double(z.advWindow)
        let exitable = adv * z.liquidityParticipation * z.liquidityExitDays
        return clamp01(exitable / z.portfolioValue)
    }
}

// MARK: - 11. Helpers (pure)

private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
private func clampSigned(_ x: Double) -> Double { max(-1, min(1, x)) }
private let monthAbbrevs = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
/// Three-letter English month for a date in UTC — matches the seasonality table's row names ("Jan"…
/// "Dec"). UTC-pinned so the read is deterministic and timezone-independent (tests rely on this).
private func monthAbbrev(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let m = cal.component(.month, from: date)
    return (1...12).contains(m) ? monthAbbrevs[m - 1] : ""
}
private func nsDouble(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
private func pctChange(_ new: Decimal, _ old: Decimal) -> Double { old == 0 ? 0 : nsDouble(new - old) / nsDouble(old) }
private func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
private func round2(_ x: Double) -> String { x.isFinite ? String(format: "%.2f", x) : "∞" }
private func signed(_ x: Double) -> String { String(format: "%+.3f", x) }
private func consistency(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let m = xs.reduce(0,+) / Double(xs.count); guard m != 0 else { return 0 }
    let varr = xs.map { ($0 - m) * ($0 - m) }.reduce(0,+) / Double(xs.count)
    return clamp01(1 - varr.squareRoot() / abs(m))
}
private func monotoneUp(_ xs: [Double]) -> Bool { zip(xs, xs.dropFirst()).allSatisfy { $1 >= $0 } }
private func sma(_ bars: [OHLCV], _ n: Int) -> Double { let w = bars.suffix(n); return nsDouble(w.map(\.close).reduce(0,+)) / Double(max(w.count,1)) }
private func ret(_ bars: [OHLCV], _ n: Int) -> Double {
    guard bars.count > n else { return 0 }
    let a = nsDouble(bars[bars.count - 1 - n].close), b = nsDouble(bars.last!.close)
    return a == 0 ? 0 : (b - a) / a
}

// MARK: - 11b. Factor regression — measured betas (§13-A2)

/// Two-factor market-model betas, estimated by a no-intercept OLS over the most-recent `lookback`
/// daily close-to-close returns:
///
///     stockReturn ≈ βmarket · marketReturn + βsector · (sectorReturn − marketReturn)
///
/// This is exactly the factor decomposition `Modifiers.timing` applies to form its `idio` residual,
/// so the regression is fit through the origin (no alpha term — the residual return *is* what timing
/// keeps) to stay self-consistent with how the betas are then used. Replaces the hardcoded placeholder
/// betas with a value measured from each name's own price history (§13-A2).
///
/// Returns nil — caller falls back to the configured placeholder betas — when the data is insufficient
/// (fewer than `minObservations` overlapping returns) or degenerate: a factor with no variance (flat
/// prices) or two collinear factors (the sector index equals the market index) make the normal-
/// equations determinant vanish, leaving the betas unidentifiable.
enum FactorRegression {
    static func betas(stock: [OHLCV], market: [OHLCV], sector: [OHLCV],
                      lookback: Int, minObservations: Int = 30) -> (market: Double, sector: Double)? {
        let y = dailyReturns(stock), m = dailyReturns(market), s = dailyReturns(sector)
        let n = min(y.count, m.count, s.count, max(lookback, 0))
        guard n >= minObservations else { return nil }
        // Newest-aligned window: the most-recent `n` overlapping returns from each series.
        let yy = Array(y.suffix(n)), mm = Array(m.suffix(n)), ss = Array(s.suffix(n))
        var s11 = 0.0, s22 = 0.0, s12 = 0.0, s1y = 0.0, s2y = 0.0
        for i in 0..<n {
            let x1 = mm[i]                 // market factor
            let x2 = ss[i] - mm[i]         // sector-excess factor
            s11 += x1 * x1; s22 += x2 * x2; s12 += x1 * x2
            s1y += x1 * yy[i]; s2y += x2 * yy[i]
        }
        let det = s11 * s22 - s12 * s12
        // Degenerate if either factor is ~flat or the two are collinear (det → 0 by Cauchy–Schwarz).
        guard s11 > 1e-12, s22 > 1e-12, det > 1e-12 * s11 * s22 else { return nil }
        let bm = (s1y * s22 - s2y * s12) / det
        let bs = (s2y * s11 - s1y * s12) / det
        guard bm.isFinite, bs.isFinite else { return nil }
        return (bm, bs)
    }

    /// Close-to-close simple returns, oldest→newest. A non-positive prior close yields a 0 return (no
    /// valid percentage change) rather than an infinity/NaN that would poison the regression.
    private static func dailyReturns(_ bars: [OHLCV]) -> [Double] {
        guard bars.count > 1 else { return [] }
        let closes = bars.map { nsDouble($0.close) }
        return zip(closes, closes.dropFirst()).map { prev, cur in prev > 0 ? (cur - prev) / prev : 0 }
    }
}
