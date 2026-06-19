import Foundation

/// Turns the raw regime inputs (server snapshot + live feeds) into the `[RegimeFactor]`
/// the synthesiser scores. Pure and isolated from I/O so the signal mapping *and* the
/// human rationale strings are unit-testable without touching the network. Only the
/// inputs that are actually present produce a factor (absence = the factor is dropped,
/// and the read degrades gracefully — see `RegimeSynthesizer.read`).
nonisolated enum RegimeFactorBuilder {
    static func factors(
        snapshot: RegimeSnapshot?,
        netForeignRaw: Double?,
        netForeignText: String?,
        ihsgDistanceFrom200dma: Double?,
        sp500DistanceFrom200dma: Double? = nil,
        usdIdrChangePercent: Double?,
        breadth: BreadthReading?
    ) -> [RegimeFactor] {
        var factors: [RegimeFactor] = []

        // Valuation — the dominant driver (weighted 2× in the synthesiser).
        if let percentile = snapshot?.composite?.valuationPercentile,
           let signal = RegimeSynthesizer.valuationSignal(percentile: percentile) {
            factors.append(RegimeFactor(
                kind: .valuation, signal: signal,
                detail: "IHSG P/E·P/B at \(pct0(percentile)) of its 10-year range (\(valuationWord(signal)))"))
        }

        // BI policy rate direction.
        if let rate = snapshot?.biRate,
           let signal = RegimeSynthesizer.policyRateSignal(direction: rate.direction) {
            factors.append(RegimeFactor(
                kind: .policyRate, signal: signal,
                detail: "BI rate \(rateText(rate.value)), last move: \(rate.direction.rawValue)"))
        }

        // US rates — the 10y Treasury yield trend, the global discount-rate / EM-flow
        // anchor. Fed funds rides along in the detail for context (it's the policy rate
        // behind the 10y), but the vote is the 10y to avoid double-counting the US leg.
        if let series = snapshot?.macro?.us10y,
           let signal = RegimeSynthesizer.globalHeadwindSignal(trend: series.trend) {
            factors.append(RegimeFactor(
                kind: .usRates, signal: signal,
                detail: "US 10y \(rateText(series.value)) \(trendWord(series.trend))\(fedFundsContext(snapshot?.macro?.usFedFunds))"))
        }

        // Global dollar — the broad trade-weighted USD trend (rupiah/flow pressure).
        if let series = snapshot?.macro?.broadDollar,
           let signal = RegimeSynthesizer.globalHeadwindSignal(trend: series.trend) {
            factors.append(RegimeFactor(
                kind: .globalDollar, signal: signal,
                detail: "Broad USD \(trendWord(series.trend)) (index \(indexText(series.value)))"))
        }

        // Global equities — the S&P 500 vs. its 200-day average, the live global
        // risk-appetite leg (Murphy intermarket: US equities lead EM flows). Above its
        // 200dma → risk-on, below → risk-off; same trend semantics as the IHSG leg, so
        // it reuses `trendSignal`.
        if let distance = sp500DistanceFrom200dma,
           let signal = RegimeSynthesizer.trendSignal(distanceFrom200dma: distance) {
            let position = distance >= 0 ? "above" : "below"
            factors.append(RegimeFactor(
                kind: .globalEquities, signal: signal,
                detail: "S&P 500 \(pct1(abs(distance))) \(position) its 200-day average"))
        }

        // Aggregate net foreign flow.
        if let raw = netForeignRaw,
           let signal = RegimeSynthesizer.foreignFlowSignal(netForeign: raw) {
            let side = raw >= 0 ? "buy" : "sell"
            let magnitude = (netForeignText.map(stripLeadingMinus)) ?? "—"
            factors.append(RegimeFactor(
                kind: .foreignFlow, signal: signal,
                detail: "Net foreign \(side) \(magnitude)"))
        }

        // IHSG trend vs. its 200-day average.
        if let distance = ihsgDistanceFrom200dma,
           let signal = RegimeSynthesizer.trendSignal(distanceFrom200dma: distance) {
            let position = distance >= 0 ? "above" : "below"
            factors.append(RegimeFactor(
                kind: .trend, signal: signal,
                detail: "IHSG \(pct1(abs(distance))) \(position) its 200-day average"))
        }

        // Rupiah (USD/IDR daily move). A *rising* USD/IDR = weaker rupiah = risk-off.
        if let changePercent = usdIdrChangePercent,
           let signal = RegimeSynthesizer.rupiahSignal(usdIdrChange: changePercent / 100) {
            factors.append(RegimeFactor(
                kind: .rupiah, signal: signal,
                detail: "USD/IDR \(signedPct(changePercent)) today — rupiah \(rupiahWord(signal))"))
        }

        // LQ45 breadth.
        if let reading = breadth, let fraction = reading.fraction,
           let signal = RegimeSynthesizer.breadthSignal(fractionAbove200dma: fraction) {
            factors.append(RegimeFactor(
                kind: .breadth, signal: signal,
                detail: "\(pct0(fraction)) of \(reading.measured) LQ45 names above their 200-day average"))
        }

        return factors
    }

    // MARK: - Formatting

    private static func pct0(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
    private static func pct1(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
    /// A figure that is already a percentage (e.g. a `changePercent` of −1.96), with sign.
    private static func signedPct(_ percent: Double) -> String { String(format: "%+.2f%%", percent) }
    private static func rateText(_ value: Double) -> String { String(format: "%.2f%%", value) }
    /// A bare index level (the dollar index has no unit), one decimal.
    private static func indexText(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func stripLeadingMinus(_ s: String) -> String { s.hasPrefix("-") ? String(s.dropFirst()) : s }

    private static func trendWord(_ trend: MacroTrend) -> String {
        switch trend {
        case .up: "rising"
        case .down: "falling"
        case .flat: "flat"
        }
    }

    /// Fed-funds context appended to the US-rates detail, e.g. " (Fed funds rising)".
    /// Names its own subject so it can't be misread as describing the 10y: the two
    /// rates routinely diverge (a falling 10y while the Fed still hikes = a flattening
    /// curve), and the old "(Fed tightening)" jargon contradicted the yield's own
    /// trend word on the same line. Empty when fed funds is unavailable.
    private static func fedFundsContext(_ series: RegimeSnapshot.MacroSeries?) -> String {
        guard let series else { return "" }
        return " (Fed funds \(trendWord(series.trend)))"
    }

    private static func valuationWord(_ signal: RegimeSignal) -> String {
        switch signal {
        case .riskOn: "cheap vs. history"
        case .neutral: "mid-range"
        case .riskOff: "stretched"
        }
    }

    private static func rupiahWord(_ signal: RegimeSignal) -> String {
        switch signal {
        case .riskOff: "weakening"
        case .riskOn: "strengthening"
        case .neutral: "steady"
        }
    }
}
