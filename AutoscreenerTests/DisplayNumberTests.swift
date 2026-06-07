import Foundation
import Testing
@testable import Autoscreener

// Phase 0.3 of INTEGRATION.md: confirm DisplayNumber covers every value path the engine adapters
// feed it. `parseDecimal` handles thousands separators, parenthesised negatives, a trailing %, and
// "-"/blank → nil — but deliberately does NOT scale magnitude suffixes (B/T), since its callers
// (keystats ratios, governance) only read ratios/percents. Phase 1.1 (keystats Net Income / CFO /
// Total Assets) and §1.3 (balance-sheet line items) need scaling, so it lives in the sibling
// `parseScaledDecimal` — keeping `parseDecimal`'s contract unchanged for its existing callers.
@Suite struct DisplayNumberTests {

    @Test func parsesThousandsSeparatorsAndDecimals() {
        #expect(DisplayNumber.parseDecimal("1,688.51") == 1688.51)
    }
    @Test func parsesPlainNegatives() {
        #expect(DisplayNumber.parseDecimal("-22.24") == -22.24)
    }
    @Test func parsesParenthesisedNegatives() {
        #expect(DisplayNumber.parseDecimal("(5,349)") == -5349)
    }
    @Test func stripsTrailingPercent() {
        #expect(DisplayNumber.parseDecimal("31.87%") == 31.87)
    }
    @Test func treatsDashAndBlankAsNotApplicable() {
        #expect(DisplayNumber.parseDecimal("-") == nil)
        #expect(DisplayNumber.parseDecimal("") == nil)
        #expect(DisplayNumber.parseDecimal("   ") == nil)
    }

    // --- parseDecimal deliberately does NOT scale magnitude suffixes (that's parseScaledDecimal). ---
    @Test func parseDecimalDoesNotScaleMagnitudeSuffixes() {
        #expect(DisplayNumber.parseDecimal("223 B") == nil)
        #expect(DisplayNumber.parseDecimal("8,688 B") == nil)
        #expect(DisplayNumber.parseDecimal("1.2T") == nil)
    }
}

// MARK: - Magnitude scaling (Phase 1.1 / §1.3) — parseScaledDecimal

@Suite struct DisplayNumberScaledTests {

    @Test func scalesBillionsAndTrillions() {
        #expect(DisplayNumber.parseScaledDecimal("223 B") == 223_000_000_000)
        #expect(DisplayNumber.parseScaledDecimal("8,688 B") == 8_688_000_000_000)
        #expect(DisplayNumber.parseScaledDecimal("1.2T") == 1_200_000_000_000)
    }

    @Test func scalesRealKeystatsAbsolutes() {
        // Verbatim from the WIFI keystats capture: Net Income / CFO / Total Assets (TTM/Quarter).
        #expect(DisplayNumber.parseScaledDecimal("490 B") == 490_000_000_000)
        #expect(DisplayNumber.parseScaledDecimal("(1,899 B)") == -1_899_000_000_000)   // parens + suffix
        #expect(DisplayNumber.parseScaledDecimal("16,196 B") == 16_196_000_000_000)
    }

    @Test func supportsThousandsAndMillions() {
        #expect(DisplayNumber.parseScaledDecimal("5K") == 5_000)
        #expect(DisplayNumber.parseScaledDecimal("12.5M") == 12_500_000)
    }

    @Test func leavesSuffixlessValuesUnscaled() {
        // Ratios/percentages flowing through the scaled parser must be unaffected.
        #expect(DisplayNumber.parseScaledDecimal("1.91") == 1.91)
        #expect(DisplayNumber.parseScaledDecimal("6.57%") == 6.57)
        #expect(DisplayNumber.parseScaledDecimal("1,406.02") == 1406.02)
    }

    @Test func treatsDashAndBlankAsNotApplicable() {
        #expect(DisplayNumber.parseScaledDecimal("-") == nil)
        #expect(DisplayNumber.parseScaledDecimal("") == nil)
    }
}
