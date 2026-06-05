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
    static func parseDecimal(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "-" else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: ",", with: "")
        if s.hasSuffix("%") { s = String(s.dropLast()) }
        guard let value = Double(s) else { return nil }
        return negative ? -value : value
    }
}
