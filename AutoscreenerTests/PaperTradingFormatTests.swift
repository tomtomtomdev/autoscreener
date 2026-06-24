import Foundation
import Testing
@testable import Autoscreener

/// Pins the paper-trading display formatters: IDR and lot counts render as full numbers with
/// Indonesian "." thousands separators (no K/M/B/T abbreviation), and share counts are shown in
/// IDX lots (1 lot = 100 shares).
@Suite struct PaperTradingFormatTests {

    // MARK: - Currency: full number, "." grouping, no abbreviation

    @Test func idrGroupsWithDotsAndNoAbbreviation() {
        #expect(PaperTradingView.idr(100_000_000) == "Rp 100.000.000")
        #expect(PaperTradingView.idr(9_500) == "Rp 9.500")
        #expect(PaperTradingView.idr(11_875_000) == "Rp 11.875.000")
        #expect(PaperTradingView.idr(0) == "Rp 0")
    }

    @Test func idrHasNoMagnitudeSuffix() {
        for s in ["K", "M", "B", "T"] {
            #expect(!PaperTradingView.idr(1_500_000_000).contains(s))
        }
    }

    @Test func signedIdrKeepsSignAndGrouping() {
        #expect(PaperTradingView.signedIdr(1_250_000) == "+Rp 1.250.000")
        #expect(PaperTradingView.signedIdr(-1_250_000) == "−Rp 1.250.000")
        #expect(PaperTradingView.signedIdr(0) == "+Rp 0")
    }

    // MARK: - Lots: shares / 100, grouped with dots

    @Test func lotsDivideSharesByOneHundred() {
        #expect(PaperTradingView.lots(50_000) == "500")
        #expect(PaperTradingView.lots(125_000) == "1.250")
        #expect(PaperTradingView.lots(100) == "1")
        #expect(PaperTradingView.lots(0) == "0")
    }
}
