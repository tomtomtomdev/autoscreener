import Foundation

/// Combines the four-layer regime inputs (`idx-investing-research.md` §3) into a
/// single risk-on / neutral / risk-off posture.
///
/// Design follows Howard Marks (`most-important-thing` skill):
///   • **Valuation percentile is the dominant driver of *future* risk** — at high
///     prices the distribution of outcomes skews negative — so it is weighted 2×
///     the coincident sentiment/momentum factors (flow, trend, rupiah, breadth)
///     and the BI-rate macro signal.
///   • **The late-cycle guard:** an expensive market cannot read risk-on no matter
///     how strong the tape. That is the euphoric top where perceived risk is
///     lowest exactly when actual risk is highest — a naïve vote-counter would
///     call it offence, which is first-level thinking.
///   • Output is a *posture*, not a prediction.
///
/// Two pure layers, each independently testable: per-factor classifiers map a raw
/// figure → `RegimeSignal?` (nil = input unavailable, factor excluded), and
/// `read(factors:asOf:)` does the weighted aggregation + the guard.
nonisolated enum RegimeSynthesizer {
    enum Threshold {
        /// Valuation percentile vs. own history: cheap third / mid / expensive third.
        static let valuationCheap = 0.33
        static let valuationExpensive = 0.66
        /// ±1.5% dead-band around the IHSG 200-day average.
        static let trendBand = 0.015
        /// ±1% dead-band on the USD/IDR move over the window.
        static let rupiahBand = 0.01
        /// Classic breadth bands: >60% healthy, <40% weak.
        static let breadthStrong = 0.60
        static let breadthWeak = 0.40
        /// Normalised-score band that separates the three stances.
        static let stanceBand = 0.33
    }

    // MARK: - Per-factor classifiers (nil = input unavailable)

    /// Cheap vs. its own history → favourable distribution → risk-on; expensive → risk-off.
    static func valuationSignal(percentile: Double?) -> RegimeSignal? {
        guard let p = percentile else { return nil }
        if p < Threshold.valuationCheap { return .riskOn }
        if p > Threshold.valuationExpensive { return .riskOff }
        return .neutral
    }

    /// Easing supports multiples/liquidity (risk-on); tightening is the macro headwind (risk-off).
    static func policyRateSignal(direction: BIRateDirection?) -> RegimeSignal? {
        guard let d = direction else { return nil }
        switch d {
        case .cut: return .riskOn
        case .hold: return .neutral
        case .hike: return .riskOff
        }
    }

    /// Net foreign buying is the IDX's regime tailwind; net selling its classic risk-off tell.
    static func foreignFlowSignal(netForeign: Double?) -> RegimeSignal? {
        guard let net = netForeign else { return nil }
        if net > 0 { return .riskOn }
        if net < 0 { return .riskOff }
        return .neutral
    }

    /// IHSG above its 200-day average is risk-on; below is risk-off; within the band is neutral.
    /// `distance` is the fractional gap `(close − ma200) / ma200`.
    static func trendSignal(distanceFrom200dma distance: Double?) -> RegimeSignal? {
        guard let d = distance else { return nil }
        if d > Threshold.trendBand { return .riskOn }
        if d < -Threshold.trendBand { return .riskOff }
        return .neutral
    }

    /// `change` is the fractional USD/IDR move over the window; positive = more
    /// rupiah per dollar = rupiah *weakening* = risk-off (and vice versa).
    static func rupiahSignal(usdIdrChange change: Double?) -> RegimeSignal? {
        guard let c = change else { return nil }
        if c > Threshold.rupiahBand { return .riskOff }
        if c < -Threshold.rupiahBand { return .riskOn }
        return .neutral
    }

    /// Share of LQ45 constituents above their own 200-day average (0…1).
    static func breadthSignal(fractionAbove200dma fraction: Double?) -> RegimeSignal? {
        guard let b = fraction else { return nil }
        if b >= Threshold.breadthStrong { return .riskOn }
        if b <= Threshold.breadthWeak { return .riskOff }
        return .neutral
    }

    /// US yields and the broad dollar are both *headwinds when rising* (Murphy
    /// intermarket): a higher US discount rate and a stronger dollar pull capital out
    /// of EM, pressuring foreign flow and the rupiah → risk-off. Falling → the tailwind
    /// that brings money back. Shared by the `usRates` and `globalDollar` factors.
    static func globalHeadwindSignal(trend: MacroTrend?) -> RegimeSignal? {
        guard let t = trend else { return nil }
        switch t {
        case .up: return .riskOff
        case .down: return .riskOn
        case .flat: return .neutral
        }
    }

    // MARK: - Aggregation

    /// Maps a normalised weighted-vote score to a stance.
    static func stance(forScore score: Double) -> RegimeStance {
        if score >= Threshold.stanceBand { return .riskOn }
        if score <= -Threshold.stanceBand { return .riskOff }
        return .neutral
    }

    /// Weighted-vote aggregation over the *available* factors (absent factors carry
    /// no weight, so the read degrades gracefully when, say, the server snapshot is
    /// missing). Applies the Marks late-cycle guard before returning.
    static func read(factors: [RegimeFactor], asOf: String?) -> RegimeRead {
        let totalWeight = factors.reduce(0) { $0 + $1.kind.weight }
        guard totalWeight > 0 else {
            return RegimeRead(stance: .neutral, score: 0, factors: factors, asOf: asOf, valuationCapped: false)
        }
        let weighted = factors.reduce(0) { $0 + $1.signal.vote * $1.kind.weight }
        let score = Double(weighted) / Double(totalWeight)
        var stance = stance(forScore: score)

        // Late-cycle guard. Marks: "being too aggressive when prices are high is
        // just as dangerous as being too conservative when prices are cheap." A
        // stretched valuation caps the read at neutral however green the tape.
        // The guard is one-sided on purpose: a cheap-but-falling market reading
        // risk-off is the "don't catch a falling knife" zone, which is correct.
        var capped = false
        if let valuation = factors.first(where: { $0.kind == .valuation }),
           valuation.signal == .riskOff, stance == .riskOn {
            stance = .neutral
            capped = true
        }
        return RegimeRead(stance: stance, score: score, factors: factors, asOf: asOf, valuationCapped: capped)
    }
}
