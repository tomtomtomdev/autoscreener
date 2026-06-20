import Foundation
import Testing
@testable import Autoscreener

/// The DJPPR SBN-ownership parser — the on-device bond-flow leg. The PDF fixture mirrors the real
/// PDFKit text extraction of the daily "Kepemilikan SBN" file: the page-1 "Non Residen" row appears
/// once in the Triliun-Rupiah table and once in the Persentase table, each as a single line of
/// chronological value-triples (SUN, SBSN, TOTAL) — plus the footnote and the English label, which
/// the parser must ignore.
@Suite struct BondFlowParsingTests {
    /// Real page-1 extraction: the two "Non Residen" data rows (2–11 Jun 2026), a BANK row and a
    /// TOTAL row as noise, the footnote, and the English continuation label.
    private let pageOneExtract = """
    A. Dalam Triliun Rupiah
    BANK* 925,90 285,86 1.211,76 933,15 283,68 1.216,82
    Non Residen 849,70 18,22 867,92 853,00 18,18 871,18 853,87 18,20 872,07 851,64 18,28 869,92 850,67 18,28 868,95 850,31 18,58 868,89 849,40 18,58 867,98 847,31 18,58 865,89
    TOTAL 5.606,28 1.271,16 6.877,44
    B. Dalam Persentase
    Non Residen 15,16 1,43 12,62 15,22 1,43 12,67 15,24 1,42 12,67 15,20 1,43 12,64 15,19 1,43 12,63 15,18 1,45 12,63 15,16 1,45 12,61 15,05 1,45 12,53
    1) Non Residen terdiri dari Private Bank , Fund/Asset Manager , Perusahaan
    Non Resident
    """

    @Test func parsesHoldingsShareAndMonthToDateChangeFromThePageOneRow() {
        let reading = MacroParsing.parseSBNOwnership(pageOneExtract)

        // Latest TOTAL of the trillions row (11 Jun) and the percentage row.
        #expect(reading?.foreignHoldingsTrillions == 865.89)
        #expect(reading?.foreignSharePercent == 12.53)
        // MTD = (865.89 − 867.92) / 867.92 × 100 ≈ −0.234% — a flat-to-slightly-distributing window.
        #expect(abs((reading?.mtdChangePercent ?? 0) - (-0.23389)) < 0.0001)
    }

    @Test func nilWhenTheTrillionsRowIsAbsent() {
        // Only the percentage row present (no Triliun figures > 100) → no level to vote on.
        let onlyPercent = "Non Residen 15,16 1,43 12,62 15,05 1,45 12,53"
        #expect(MacroParsing.parseSBNOwnership(onlyPercent) == nil)
    }

    @Test func nilWhenTheBodyHasNoNonResidenRow() {
        #expect(MacroParsing.parseSBNOwnership("<html>blocked</html>") == nil)
        #expect(MacroParsing.parseSBNOwnership("") == nil)
    }

    @Test func dropsToNilWhenTheHoldingIsImplausible() {
        // A layout change that yields an out-of-range holding (≫ 2 000 trn) degrades to nil rather
        // than feeding the factor a fabricated figure.
        let implausible = "Non Residen 9.000,00 9.000,00 9000,00 9.000,00 9.000,00 9100,00"
        #expect(MacroParsing.parseSBNOwnership(implausible) == nil)
    }

    @Test func keepsTheHoldingButDropsAnImplausibleShare() {
        // Trillions row valid; the percentage row reads an out-of-range share (99%) → share is
        // dropped (nil) but the level and MTD still drive the factor.
        let text = """
        Non Residen 849,70 18,22 867,92 847,31 18,58 865,89
        Non Residen 99,00 99,00 99,00 99,00 99,00 99,00
        """
        let reading = MacroParsing.parseSBNOwnership(text)
        #expect(reading?.foreignHoldingsTrillions == 865.89)
        #expect(reading?.foreignSharePercent == nil)
    }

    @Test func latestFileLinkIsTheFirstMediaRecordNotThePageLogo() {
        // The page payload carries the site logo as an `imageUrl` media link before the file
        // records; `latestSBNFile` keys on the `@link` field so it returns the newest file, not the
        // logo.
        let json = """
        {"imageUrl":"https://api-djppr.kemenkeu.go.id/web/api/v1/media/LOGO-1",
         "rows":[
          {"@judul":"Kepemilikan SBN Domestik 2026","@deskripsi":"Data Harian s.d. 18 Juni 2026",
           "@link":"https://api-djppr.kemenkeu.go.id/web/api/v1/media/D6D21401"},
          {"@deskripsi":"s.d. 29 Mei 2026",
           "@link":"https://api-djppr.kemenkeu.go.id/web/api/v1/media/9ACE7315"}]}
        """
        #expect(MacroParsing.latestSBNFile(json)
            == "https://api-djppr.kemenkeu.go.id/web/api/v1/media/D6D21401")
    }

    @Test func latestFileNilWhenNoMediaLinkPresent() {
        #expect(MacroParsing.latestSBNFile(#"{"error":"blocked"}"#) == nil)
    }
}
