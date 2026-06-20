import Foundation
import Testing
@testable import Autoscreener

/// The worldgovernmentbonds.com country-API parser — the on-device sovereign-risk leg. The fixtures
/// mirror the real `wp-json/country/v1/main` payload shape (Indonesia capture): the two levels are
/// string-typed top-level fields and the CDS change lives only inside the rendered table HTML.
@Suite struct IndonesiaSovereignParsingTests {
    /// The CDS table markup, parameterised so a test can vary the 1W/1M/1Y/PD cells. Matches the
    /// captured structure: the row label "5 Years CDS", the value cell, then the three Var% spans
    /// and the implied-PD cell — each percent rendered inside its own `<span>`.
    private func cdsTable(value: String, w1: String, m1: String, y1: String, pd: String) -> String {
        """
        <div class="w3-responsive"><table><thead><tr>
          <th></th><th>Credit Default Swap</th><th>CDS Value</th>
          <th>Var % 1W</th><th>Var % 1M</th><th>Var % 1Y</th><th>Implied PD</th>
        </tr></thead><tbody><tr>
          <td><span class="flag id"></span></td>
          <td><b>5 Years CDS</b></td>
          <td><a href="...">\(value)</a></td>
          <td><span class="w3-text-teal">\(w1)</span></td>
          <td><span class="w3-text-teal">\(m1)</span></td>
          <td><span class="w3-text-red">\(y1)</span></td>
          <td>\(pd)</td>
        </tr></tbody></table></div>
        """
    }

    /// A full country payload with the three figures we read plus a few of the real sibling fields
    /// (ignored by the parser) so the fixture exercises selective decoding, not a hand-picked struct.
    private func payload(bond10y: String, lastCds: String, cdsTable: String) -> String {
        """
        {"success":true,"lastDataValDesc":"20 June 2026","bond10y":"\(bond10y)",
         "bond10ySimulated":false,"cbRateNumber":"5.75","lastCds":"\(lastCds)",
         "lastCdsDefaultProb":"1.44","cdsTableHtml":\(jsonString(cdsTable))}
        """
    }

    /// JSON-encode a string (the HTML blob) so it can be embedded as a value.
    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        // strip the surrounding [ ] to get the bare quoted string
        return String(array.dropFirst().dropLast())
    }

    @Test func parsesTheTwoLevelsAndTheOneMonthCdsChange() {
        let json = payload(
            bond10y: "7.070", lastCds: "86.48",
            cdsTable: cdsTable(value: "86.48", w1: "-7.26 %", m1: "-7.39 %", y1: "+4.87 %", pd: "1.44 %"))

        let reading = MacroParsing.parseWorldGovBonds(json)

        #expect(reading?.bond10yPercent == 7.07)
        #expect(reading?.cds5y == 86.48)
        #expect(reading?.cdsChange1MPercent == -7.39)   // the 2nd Var% column (1M), not 1W or 1Y
    }

    @Test func readsAWideningOneMonthChangeWithItsSign() {
        let json = payload(
            bond10y: "7.200", lastCds: "120.00",
            cdsTable: cdsTable(value: "120.00", w1: "+3.10 %", m1: "+11.40 %", y1: "-2.00 %", pd: "2.00 %"))
        #expect(MacroParsing.parseWorldGovBonds(json)?.cdsChange1MPercent == 11.40)
    }

    @Test func nilWhenBodyIsNotTheExpectedJson() {
        #expect(MacroParsing.parseWorldGovBonds("<html>blocked</html>") == nil)
        // FRED-style error JSON (a stand-in for any unexpected payload) also parses to nil.
        #expect(MacroParsing.parseWorldGovBonds(#"{"error_code":400,"error_message":"Bad Request."}"#) == nil)
    }

    @Test func nilWhenALevelIsMissing() {
        // bond10y absent → the whole reading drops (selective decode fails on the required field).
        let json = """
        {"success":true,"lastCds":"86.48","cdsTableHtml":\(jsonString(cdsTable(
            value: "86.48", w1: "-7.26 %", m1: "-7.39 %", y1: "+4.87 %", pd: "1.44 %")))}
        """
        #expect(MacroParsing.parseWorldGovBonds(json) == nil)
    }

    @Test func nilWhenTheCdsTableHasTooFewChangeColumns() {
        // Only one percent token (no 1M column) → no monthly change → factor drops rather than
        // misreading the 1W or implied-PD cell as the 1-month move.
        let oneCol = """
        <table><tbody><tr><td><b>5 Years CDS</b></td>
        <td>86.48</td><td><span>-7.26 %</span></td></tr></tbody></table>
        """
        let json = payload(bond10y: "7.070", lastCds: "86.48", cdsTable: oneCol)
        #expect(MacroParsing.parseWorldGovBonds(json) == nil)
    }
}
