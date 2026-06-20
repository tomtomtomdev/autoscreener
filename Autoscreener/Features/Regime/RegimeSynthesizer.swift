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
///   • **The confirmed-downtrend guard (its mirror):** when IHSG trend *and* LQ45
///     breadth are both risk-off the domestic tape is in a broad markdown, so the
///     read is forced to risk-off — cheap valuation and a green US tape must not net
///     it up to neutral (Zweig: don't fight the tape; the falling-knife / value-trap
///     zone where cheap doesn't yet mean going up).
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
        /// ±1.5% dead-band on the export-basket daily move. Commodities are noisier than FX,
        /// so a basket swing must clear this band to register as a terms-of-trade signal.
        static let commodityBand = 0.015
        /// ±1.5% dead-band on the Asia-EM equity read — the EM-vs-DM 200dma spread (or the absolute
        /// regional trend in fallback). The basket must lead/lag the developed-market tape by more
        /// than this to register as a rotation signal, filtering a small or noisy gap to neutral.
        static let asiaEMBand = 0.015
        /// ±5% dead-band on the 1-month 5y-CDS move. Sovereign CDS is noisier than a yield level,
        /// so the spread must move more than this over the month to register as a genuine shift in
        /// the country risk premium rather than day-to-day chop.
        static let sovereignCdsBand = 0.05
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

    /// Indonesia's commodity export terms of trade — the "China channel". `change` is the
    /// fractional daily move of the export basket (coal/CPO/nickel); rising = an external-demand
    /// tailwind = risk-on, falling = headwind = risk-off, within the band = neutral. The sign is
    /// the *opposite* of the rupiah leg by design: a higher export price helps Indonesia, a higher
    /// dollar hurts it. (Oil is excluded from the basket upstream — Indonesia is a net oil importer,
    /// so a higher oil price is an import-cost drag, wrong-signed as a terms-of-trade input.)
    static func commodityChannelSignal(basketChange change: Double?) -> RegimeSignal? {
        guard let c = change else { return nil }
        if c > Threshold.commodityBand { return .riskOn }
        if c < -Threshold.commodityBand { return .riskOff }
        return .neutral
    }

    /// The Asia-EM equity-appetite leg. `strength` is the EM-vs-developed-market 200dma spread
    /// (Asia-EM basket distance − S&P 500 distance) when the benchmark is available, otherwise the
    /// absolute regional 200dma trend. Positive (Asia-EM leading the DM tape) = the EM periphery is
    /// being bid = risk-on; negative (lagging a DM-led advance) = appetite isn't reaching IDX =
    /// risk-off; within the band = neutral. Voting the *relative* spread keeps this from echoing the
    /// US 10y / dollar / S&P legs that already count the one global cycle (see `AsiaEMReading`).
    static func asiaEMSignal(strength value: Double?) -> RegimeSignal? {
        guard let v = value else { return nil }
        if v > Threshold.asiaEMBand { return .riskOn }
        if v < -Threshold.asiaEMBand { return .riskOff }
        return .neutral
    }

    /// Indonesia's sovereign-risk premium, read off the 5y CDS trend. `change` is the fractional
    /// 1-month move in the CDS spread; *widening* (positive) lifts the country risk premium —
    /// foreign holders demand more to carry IDR assets, a headwind to flow and multiples — so it is
    /// risk-off, while *tightening* (negative) is improving credit = risk-on, within the band =
    /// neutral. The sign matches the rupiah leg (a rising risk gauge is risk-off) and is the
    /// opposite of the commodity-tailwind leg (a rising export price helps Indonesia).
    static func sovereignCreditSignal(cdsChange change: Double?) -> RegimeSignal? {
        guard let c = change else { return nil }
        if c > Threshold.sovereignCdsBand { return .riskOff }
        if c < -Threshold.sovereignCdsBand { return .riskOn }
        return .neutral
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

        // Confirmed-downtrend guard (the mirror of the late-cycle guard). When the
        // domestic tape is in a *broad, confirmed* markdown — IHSG below its 200-day
        // AND LQ45 breadth collapsed (both risk-off) — the posture is defence, full
        // stop. Cheap valuation and a green US tape must not net it up to neutral:
        // that is the falling-knife / value-trap zone (Zweig: don't fight the tape;
        // Marks: cheap doesn't mean going up soon). Requires *both* legs so a single
        // weak leg — the basing turn where cheapness should lead — doesn't trip it.
        var tapeFloored = false
        let trendSignal = factors.first { $0.kind == .trend }?.signal
        let breadthSignal = factors.first { $0.kind == .breadth }?.signal
        if trendSignal == .riskOff, breadthSignal == .riskOff, stance != .riskOff {
            stance = .riskOff
            tapeFloored = true
        }
        return RegimeRead(stance: stance, score: score, factors: factors, asOf: asOf,
                          valuationCapped: capped, tapeFloored: tapeFloored)
    }
}
