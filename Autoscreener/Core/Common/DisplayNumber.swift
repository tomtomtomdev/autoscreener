import Foundation

/// Parses Stockbit's display-string numbers into a `Double`.
///
/// The `exodus` endpoints return figures pre-formatted for display, not as JSON
/// numbers: thousands separators, parentheses for negatives, a trailing `%`, and
/// `"-"` for "not applicable". Every service that reads those payloads needs the same
/// parse, so it lives here once and is shared (`KeystatsRatioService`, `GovernanceService`, …).
nonisolated enum DisplayNumber {
    /// `"1,688.51"` → 1688.51, `"-22.24"` → −22.24, `"(5,349)"` → −5349,
    /// `"31.87%"` → 31.87, and `"-"` / `""` / whitespace → `nil` (field not applicable).
    ///
    /// A trailing magnitude suffix is **not** scaled here — `"490 B"` → `nil`. Ratios and
    /// percentages (the only things this overload's callers read) never carry one; use
    /// `parseScaledDecimal` for absolute money amounts that do.
    static func parseDecimal(_ raw: String) -> Double? {
        parse(raw, scaleMagnitudeSuffix: false)
    }

    /// Like `parseDecimal`, but also applies a trailing magnitude suffix:
    /// `K`/`M`/`B`/`T` → ×10³ / ×10⁶ / ×10⁹ / ×10¹². Stockbit prints large rupiah
    /// amounts this way — `"490 B"` → 490_000_000_000, `"16,196 B"` → 16_196e9,
    /// `"(1,899 B)"` → −1_899e9, `"1.2T"` → 1.2e12. The selection engine's absolute
    /// fields (keystats Net Income / CFO / Total Assets, balance-sheet line items) need it;
    /// `parseDecimal` deliberately does not, so ratio/percent callers are unaffected.
    static func parseScaledDecimal(_ raw: String) -> Double? {
        parse(raw, scaleMagnitudeSuffix: true)
    }

    /// Shared normalization. Trims, unwraps a parenthesised negative, strips a trailing
    /// `%`, optionally consumes a magnitude suffix, removes thousands separators, then
    /// parses. Magnitude scaling lives behind a flag so `parseDecimal`'s contract — and
    /// thus its existing callers — stay byte-for-byte unchanged.
    private static func parse(_ raw: String, scaleMagnitudeSuffix: Bool) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "-" else { return nil }

        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if s.hasSuffix("%") { s = String(s.dropLast()) }

        var scale = 1.0
        if scaleMagnitudeSuffix, let last = s.last, let magnitude = magnitude(of: last) {
            scale = magnitude
            s = String(s.dropLast())
        }

        s = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(s) else { return nil }
        return (negative ? -value : value) * scale
    }

    private static func magnitude(of c: Character) -> Double? {
        switch c {
        case "K", "k": return 1_000
        case "M", "m": return 1_000_000
        case "B", "b": return 1_000_000_000
        case "T", "t": return 1_000_000_000_000
        default: return nil
        }
    }
}
