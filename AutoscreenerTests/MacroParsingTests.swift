import Foundation
import Testing
@testable import Autoscreener

/// Swift port of `tools/idx-regime-scraper/tests/test_bi_rate.py` + `test_macro.py` —
/// the same offline assertions over the pure parsing logic, now in `MacroParsing`.
@Suite struct MacroParsingTests {

    // MARK: - Rates & values

    @Test func parseRateHandlesCommaPercentAndRejectsImplausible() {
        #expect(MacroParsing.parseRate("4,75 %") == 4.75)
        #expect(MacroParsing.parseRate("5.00%") == 5.00)
        #expect(MacroParsing.parseRate("-") == nil)
        #expect(MacroParsing.parseRate("100") == nil)   // not a plausible policy rate
    }

    @Test func parseFREDValueIsPermissiveAboutMagnitude() {
        // The broad-dollar index trades around 120 — the policy-rate bound (0…50) would
        // wrongly reject it, which is exactly why the macro series needs its own parser.
        #expect(MacroParsing.parseFREDValue("121.5") == 121.5)
        #expect(MacroParsing.parseRate("121.5") == nil)  // contrast: rejected by the bound
        #expect(MacroParsing.parseFREDValue("4.30") == 4.30)
        #expect(MacroParsing.parseFREDValue(".") == nil)  // FRED's missing marker
        #expect(MacroParsing.parseFREDValue("") == nil)
    }

    // MARK: - Dates

    @Test func parseDateUnderstandsISOEnglishAndBahasa() {
        #expect(iso("2026-01-15") == "2026-01-15")
        #expect(iso("15 January 2026") == "2026-01-15")
        #expect(iso("15 Januari 2026") == "2026-01-15")
        #expect(iso("15/01/2026") == "2026-01-15")
        #expect(MacroParsing.parseDate("not a date") == nil)
    }

    private func iso(_ s: String) -> String? {
        MacroParsing.parseDate(s).map(MacroParsing.isoString)
    }

    // MARK: - CSV

    @Test func fredCSVParsesAndDropsMissingDots() {
        let text = "observation_date,IRSTCB01IDM156N\n2025-11-01,5.75\n2025-12-01,.\n2026-01-01,4.75\n"
        let obs = MacroParsing.parseFREDCSV(text)
        #expect(obs.map(\.raw) == ["2025-11-01", "2026-01-01"])
        #expect(obs.map(\.value) == [5.75, 4.75])
    }

    @Test func fredSeriesKeepsDatedValuesAndDropsMissing() {
        let text = "observation_date,DGS10\n2026-06-01,4.30\n2026-06-02,.\n2026-06-03,4.35\n"
        let obs = MacroParsing.parseFREDSeries(text)
        #expect(obs.map(\.raw) == ["2026-06-01", "2026-06-03"])
        #expect(obs.map(\.value) == [4.30, 4.35])
    }

    // MARK: - JSON (FRED API)

    @Test func fredJSONParsesObservationsAndDropsMissing() {
        // String values, `"."` = missing — exactly the API's shape.
        let json = #"{"observations":[{"date":"2026-06-01","value":"4.30"},{"date":"2026-06-02","value":"."},{"date":"2026-06-03","value":"4.35"}]}"#
        let obs = MacroParsing.parseFREDJSON(json)
        #expect(obs.map(\.raw) == ["2026-06-01", "2026-06-03"])
        #expect(obs.map(\.value) == [4.30, 4.35])
    }

    @Test func fredJSONIsEmptyOnErrorBody() {
        // FRED's bad-key response has no `observations` key → empty, never throws.
        let err = #"{"error_code":400,"error_message":"Bad Request. The value for variable api_key is not registered."}"#
        #expect(MacroParsing.parseFREDJSON(err).isEmpty)
        #expect(MacroParsing.parseFREDJSON("not json").isEmpty)
    }

    // MARK: - Direction & trend

    @Test func directionClassifiesLastMove() {
        #expect(MacroParsing.direction([("a", 4.5), ("b", 4.75)]) == .hike)
        #expect(MacroParsing.direction([("a", 5.0), ("b", 4.75)]) == .cut)
        #expect(MacroParsing.direction([("a", 5.0), ("b", 5.0)]) == .hold)
        #expect(MacroParsing.direction([("a", 5.0)]) == .hold)
    }

    @Test func trendClassifiesOverALookbackWindow() {
        let rising: [MacroParsing.Observation] = [("a", 4.0), ("b", 4.1), ("c", 4.3)]
        let falling: [MacroParsing.Observation] = [("a", 4.3), ("b", 4.1), ("c", 4.0)]
        let flat: [MacroParsing.Observation] = [("a", 4.2), ("b", 4.2)]
        #expect(MacroParsing.trend(rising, lookback: 2) == .up)
        #expect(MacroParsing.trend(falling, lookback: 2) == .down)
        #expect(MacroParsing.trend(flat) == .flat)
        #expect(MacroParsing.trend([("a", 4.0)]) == .flat)        // too short
        #expect(MacroParsing.trend(rising, lookback: 99) == .up)  // clamps to oldest
    }

    // MARK: - Builders

    @Test func toMacroSeriesTakesLatestValueTrendAndISODate() {
        let text = "observation_date,DGS10\n2026-06-01,4.30\n2026-06-03,4.35\n"
        let series = MacroParsing.toMacroSeries(MacroParsing.parseFREDSeries(text))
        #expect(series?.value == 4.35)
        #expect(series?.trend == .up)
        #expect(series?.asOf == "2026-06-03")
    }

    @Test func toMacroSeriesNilOnEmpty() {
        #expect(MacroParsing.toMacroSeries([]) == nil)
    }

    @Test func fredFallbackBuildsBIRate() {
        let text = "observation_date,IRSTCB01IDM156N\n2025-12-01,5.00\n2026-01-01,4.75\n"
        let bi = MacroParsing.toBIRate(MacroParsing.parseFREDCSV(text))
        #expect(bi?.value == 4.75)
        #expect(bi?.direction == .cut)
        #expect(bi?.asOf == "2026-01-01")
    }

    // MARK: - BI-rate HTML

    @Test func biHTMLIgnoresNoColumnAndReadsTheRate() {
        // Regression: the live table leads with a "No" index column whose integers
        // (1, 2, …) also parse as plausible rates. The parser must read the BI-Rate
        // column (the '%' cell), not the row number — and normalise the Bahasa date.
        let bi = MacroParsing.toBIRate(MacroParsing.parseBIRateHTML(Self.biRateHTML))
        #expect(bi?.value == 5.25)            // BI-Rate column, not the leading "No" (=1)
        #expect(bi?.direction == .hike)       // 4.75 (Apr) → 5.25 (May)
        #expect(bi?.asOf == "2026-05-20")     // normalised to ISO, not "20 Mei 2026"
    }

    /// Mirrors `tests/fixtures/bi_rate.html`: a leading "No" index column, Bahasa dates,
    /// `%`-bearing rate cells, newest row first.
    static let biRateHTML = """
    <html><body>
      <table class="table table-striped">
        <thead><tr><th>No</th><th>Tanggal</th><th>BI-Rate</th><th>Pranala Siaran Pers</th></tr></thead>
        <tbody>
          <tr><td>1</td><td>20 Mei 2026</td><td>5.25 %</td><td><a href="#">Lihat</a></td></tr>
          <tr><td>2</td><td>22 April 2026</td><td>4,75 %</td><td><a href="#">Lihat</a></td></tr>
          <tr><td>3</td><td>17 Maret 2026</td><td>4,75 %</td><td><a href="#">Lihat</a></td></tr>
          <tr><td>4</td><td>19 Februari 2026</td><td>4,75 %</td><td><a href="#">Lihat</a></td></tr>
          <tr><td>5</td><td>21 Januari 2026</td><td>4,75 %</td><td><a href="#">Lihat</a></td></tr>
        </tbody>
      </table>
    </body></html>
    """
}
