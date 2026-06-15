import Foundation
import Testing
@testable import Autoscreener

// Phase 1.1 (§8 / §11): keystats field map → engine TTMFinancials. The fiddly part is per-field
// unit handling, so it's pinned against the verbatim WIFI capture values.

private func nsd(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }

/// The TTM-relevant slice of the WIFI keystats payload (field id → display value), verbatim.
private let wifiKeystatsFields: [String: String] = [
    "13200": "92.39",        // EPS (TTM)
    "15718": "1,406.02",     // Book Value Per Share
    "1498": "1.91",          // Current Ratio
    "1508": "0.51",          // Debt/Equity
    "1461": "6.57%",         // ROE (TTM)  — a PERCENT
    "1471": "-11.46%",       // EPS Annual YoY Growth — a percent-NUMBER
    "1555": "490 B",         // Net Income (TTM) — scaled
    "2545": "(1,899 B)",     // Cash From Operations (TTM) — negative + scaled
    "1559": "16,196 B",      // Total Assets (Quarter) — scaled
    "2916": "1.61%",         // Payout Ratio — a PERCENT → ratio
    "1460": "3.03%",         // Return on Assets (TTM) — a PERCENT → ratio
]

@Suite struct KeystatsTTMAdapterTests {

    @Test func mapsPlainPerShareAndSolvencyFields() throws {
        let ttm = try SelectionFundamentals.ttm(fromKeystats: wifiKeystatsFields)
        #expect(abs(nsd(ttm.eps) - 92.39) < 1e-6)
        #expect(abs(nsd(ttm.bookValuePerShare) - 1406.02) < 1e-6)
        #expect(ttm.currentRatio == 1.91)
        #expect(ttm.debtToEquity == 0.51)
    }

    @Test func storesROEAsRatioButEpsGrowthAsPercentNumber() throws {
        // The asymmetry that's easy to get wrong: engine roeFloor is 0.10 (a ratio), while PEG
        // divides by g as a percent-number (g≈15). So ROE "6.57%" → 0.0657 but EPS growth stays −11.46.
        let ttm = try SelectionFundamentals.ttm(fromKeystats: wifiKeystatsFields)
        #expect(abs(ttm.returnOnEquity - 0.0657) < 1e-9)
        #expect(abs(ttm.epsGrowthPct - (-11.46)) < 1e-9)
    }

    @Test func parsesPayoutAndReturnOnAssetsAsRatios() throws {
        // Phase 3.0: two universal TTM fields the financial profile consumes (g = (1−payout)·ROE; the
        // bank quality scorer reads ROA). Stored as RATIOS like ROE — "1.61%" → 0.0161, "3.03%" → 0.0303.
        let ttm = try SelectionFundamentals.ttm(fromKeystats: wifiKeystatsFields)
        #expect(abs(ttm.payoutRatio - 0.0161) < 1e-9)
        #expect(abs(ttm.returnOnAssets - 0.0303) < 1e-9)
    }

    @Test func degradesPayoutAndReturnOnAssetsToZeroWhenMissing() throws {
        // Unlike the six industrial-essential fields, payout / ROA are NOT required: a non-dividend
        // payer legitimately reports payout "-", so an absent value degrades to 0 (no throw).
        var fields = wifiKeystatsFields
        fields["2916"] = "-"
        fields["1460"] = nil
        let ttm = try SelectionFundamentals.ttm(fromKeystats: fields)
        #expect(ttm.payoutRatio == 0)
        #expect(ttm.returnOnAssets == 0)
    }

    @Test func scalesAbsoluteRupiahFieldsWithMagnitudeSuffixes() throws {
        let ttm = try SelectionFundamentals.ttm(fromKeystats: wifiKeystatsFields)
        #expect(nsd(ttm.netIncome) == 490_000_000_000)
        #expect(nsd(ttm.operatingCashFlow) == -1_899_000_000_000)   // parens + B suffix
        #expect(nsd(ttm.totalAssets) == 16_196_000_000_000)
    }

    @Test func throwsMissingFieldWhenAnEssentialFieldIsAbsent() {
        // A bank returns "-" for current ratio / D/E / ROE; on the industrial path that's unscoreable.
        for id in ["13200", "15718", "1498", "1508", "1461", "1471"] {
            var fields = wifiKeystatsFields
            fields[id] = nil
            #expect(throws: SelectionFundamentals.AdapterError.self) {
                _ = try SelectionFundamentals.ttm(fromKeystats: fields)
            }
        }
    }

    @Test func treatsDashAsMissingForEssentialFields() {
        var fields = wifiKeystatsFields
        fields["1461"] = "-"   // ROE not applicable
        #expect(throws: SelectionFundamentals.AdapterError.missingField(id: "1461", name: "ROE (TTM)")) {
            _ = try SelectionFundamentals.ttm(fromKeystats: fields)
        }
    }

    @Test func degradesAbsoluteFieldsToZeroWhenMissing() throws {
        // Net Income / CFO / Total Assets are unread by today's gates/scorers (they only seed §1.4
        // share derivation), so a missing one degrades to 0 rather than failing the whole name.
        var fields = wifiKeystatsFields
        fields["1555"] = nil
        fields["2545"] = "-"
        let ttm = try SelectionFundamentals.ttm(fromKeystats: fields)
        #expect(ttm.netIncome == 0)
        #expect(ttm.operatingCashFlow == 0)
        #expect(nsd(ttm.totalAssets) == 16_196_000_000_000)   // still present
    }

    @Test func buildsFromKeystatsFieldMapEndToEnd() throws {
        // Prove the real keystats codec (fieldMap) feeds the adapter: flatten a grouped payload,
        // then build the TTM block from the result.
        let json = Data(#"""
        {"data":{"closure_fin_items_results":[
          {"keystats_name":"Per Share","fin_name_results":[
            {"fitem":{"id":"13200","name":"Current EPS (TTM)","value":"92.39"}},
            {"fitem":{"id":"15718","name":"Current Book Value Per Share","value":"1,406.02"}}
          ]},
          {"keystats_name":"Solvency","fin_name_results":[
            {"fitem":{"id":"1498","name":"Current Ratio (Quarter)","value":"1.91"}},
            {"fitem":{"id":"1508","name":"Debt to Equity Ratio (Quarter)","value":"0.51"}}
          ]},
          {"keystats_name":"Profitability","fin_name_results":[
            {"fitem":{"id":"1461","name":"Return on Equity (TTM)","value":"6.57%"}}
          ]},
          {"keystats_name":"Growth","fin_name_results":[
            {"fitem":{"id":"1471","name":"EPS (Annual YoY Growth)","value":"-11.46%"}}
          ]},
          {"keystats_name":"Income Statement","fin_name_results":[
            {"fitem":{"id":"1555","name":"Net Income (TTM)","value":"490 B"}}
          ]},
          {"keystats_name":"Cash Flow Statement","fin_name_results":[
            {"fitem":{"id":"2545","name":"Cash From Operations (TTM)","value":"(1,899 B)"}}
          ]},
          {"keystats_name":"Balance Sheet","fin_name_results":[
            {"fitem":{"id":"1559","name":"Total Assets (Quarter)","value":"16,196 B"}}
          ]}
        ]}}
        """#.utf8)
        let fields = try KeystatsRatioService.fieldMap(json)
        let ttm = try SelectionFundamentals.ttm(fromKeystats: fields)
        #expect(abs(ttm.returnOnEquity - 0.0657) < 1e-9)
        #expect(nsd(ttm.netIncome) == 490_000_000_000)
    }
}

// Phase 3.6 (§14): the financial-archetype path. A bank legitimately reports "-" for current ratio /
// D-E / EPS-growth, so on the industrial path `ttm(fromKeystats:)` throws `missingField` before a
// SecurityData is ever built. The archetype-aware overload relaxes the required set to {eps, bvps,
// roe} — the bank valuator/scorers' inputs — and degrades the three "-" fields to 0 (SolvencyGate is
// replaced by CapitalStrengthGate; Lynch growth is reused but guards g). Anchored to the BBCA capture.
private let bbcaKeystatsFields: [String: String] = [
    "13200": "471.10",       // EPS (TTM)
    "15718": "2,102.07",     // Book Value Per Share
    "1498": "-",             // Current Ratio — banks report "-"
    "1508": "-",             // Debt/Equity — banks report "-"
    "1461": "22.41%",        // ROE (TTM)
    "1471": "-",             // EPS Annual YoY Growth — banks report "-"
    "1555": "58,075 B",      // Net Income (TTM)
    "1559": "1,640,831 B",   // Total Assets (Quarter)
    "15883": "259,132 B",    // Common Equity
    "2916": "63.17%",        // Payout Ratio
    "1460": "3.54%",         // Return on Assets (TTM)
]

@Suite struct KeystatsTTMArchetypeTests {

    @Test func financialArchetypeDegradesSolvencyAndGrowthFieldsToZero() throws {
        let ttm = try SelectionFundamentals.ttm(fromKeystats: bbcaKeystatsFields, archetype: .financial)
        // The bank's required inputs are present…
        #expect(abs(nsd(ttm.eps) - 471.10) < 1e-6)
        #expect(abs(nsd(ttm.bookValuePerShare) - 2102.07) < 1e-6)
        #expect(abs(ttm.returnOnEquity - 0.2241) < 1e-9)
        // …and the three fields banks report as "-" degrade to 0 rather than throwing.
        #expect(ttm.currentRatio == 0)
        #expect(ttm.debtToEquity == 0)
        #expect(ttm.epsGrowthPct == 0)
        // The universal financial fields still parse as ratios (§3.0).
        #expect(abs(ttm.payoutRatio - 0.6317) < 1e-9)
        #expect(abs(ttm.returnOnAssets - 0.0354) < 1e-9)
    }

    @Test func financialArchetypeStillRequiresPerShareAndROE() {
        // Relaxing the solvency/growth fields does NOT relax the bank's own inputs: a name with no
        // EPS / book value / ROE can't be valued by the P/B-vs-ROE model, so it still throws.
        for id in ["13200", "15718", "1461"] {
            var fields = bbcaKeystatsFields
            fields[id] = "-"
            #expect(throws: SelectionFundamentals.AdapterError.self) {
                _ = try SelectionFundamentals.ttm(fromKeystats: fields, archetype: .financial)
            }
        }
    }

    @Test func bankShapedMapIsUnscoreableOnTheDefaultIndustrialPath() {
        // The contrast that motivates the archetype parameter: the same BBCA map that builds fine as a
        // financial throws on the default (industrial) path, because "-" current ratio / D-E are required.
        #expect(throws: SelectionFundamentals.AdapterError.self) {
            _ = try SelectionFundamentals.ttm(fromKeystats: bbcaKeystatsFields)   // default = .industrial
        }
    }

    @Test func adapterErrorIsLegibleNotErrorZero() {
        // Regression: `AdapterError` must be `LocalizedError` so the Recommendations screen (and the
        // skip note) shows the offending field — never the raw "…AdapterError error 0" enum index.
        let error = SelectionFundamentals.AdapterError.missingField(id: "1498", name: "Current Ratio")
        #expect(error.localizedDescription.contains("Current Ratio"))
        #expect(!error.localizedDescription.contains("error 0"))
    }
}
