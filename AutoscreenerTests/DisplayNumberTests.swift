import Foundation
import Testing
@testable import Autoscreener

// Phase 0.3 of INTEGRATION.md: confirm DisplayNumber.parseDecimal covers every value path the
// engine adapters will feed it. It handles thousands separators, parenthesised negatives, a
// trailing %, and "-"/blank → nil. It does NOT yet handle magnitude suffixes (B/T), which the
// §1.3 industrial balance-sheet extractor will need ("223 B"). Those cases are pinned as `nil`
// here so that extension is a deliberate, test-driven change rather than a silent behaviour shift.
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

    // --- Known gap (pinned): magnitude suffixes are NOT handled today. ---
    @Test func magnitudeSuffixesAreNotYetSupported() {
        #expect(DisplayNumber.parseDecimal("223 B") == nil)
        #expect(DisplayNumber.parseDecimal("8,688 B") == nil)
        #expect(DisplayNumber.parseDecimal("1.2T") == nil)
    }
}
