import Foundation

/// Indonesia's own sovereign-risk read — the leg the regime map was missing on the bond side.
/// Two market quotes drive it: the **5-year sovereign CDS spread** (the purest market price of
/// Indonesia default risk) and the **INDOGB 10-year government bond yield** (and, against the UST
/// 10y the macro leg already carries, the EM sovereign *spread*).
///
/// **The vote is the 5y CDS trend** — its 1-month move. A *widening* CDS lifts the country risk
/// premium (foreign capital demands more to hold IDR assets, pressuring equity multiples and flow)
/// = risk-off; a *tightening* CDS = improving credit = risk-on. The INDOGB 10y level and its spread
/// over the UST 10y ride along as detail qualifiers, not a second vote: the CDS and the bond yield
/// co-move in EM stress, so scoring both would over-count one underlying risk (the same
/// "don't double-count correlated factors" discipline that keeps CNY context-only in the China
/// channel and the S&P leg from echoing the dollar/10y legs).
nonisolated struct IndonesiaSovereignReading: Sendable, Equatable {
    /// Indonesia 10-year government bond yield, in percent (e.g. `7.070`).
    let bond10yPercent: Double
    /// Indonesia 5-year sovereign CDS spread, in basis points (e.g. `86.48`).
    let cds5y: Double
    /// 1-month change in the 5y CDS spread, in percent (e.g. `-7.39` = the spread tightened 7.39%
    /// over the month). **This is the vote driver**: positive (widening) = risk-off, negative
    /// (tightening) = risk-on.
    let cdsChange1MPercent: Double
}

/// Fetches the Indonesia sovereign-risk reading. Kept behind a protocol so the coordinator can be
/// driven with a stub (fixtures/tests) and the live network path is swapped in only in production —
/// the same seam `FREDMacroProviding` / `BIRateProviding` use.
nonisolated protocol IndonesiaSovereignProviding: Sendable {
    /// The current sovereign-risk reading, or `nil` when the fetch fails or parses empty — the
    /// factor then drops, exactly like a missing macro series.
    func sovereign() async -> IndonesiaSovereignReading?
}

/// Fetches the Indonesia sovereign-risk leg on-device from worldgovernmentbonds.com's public
/// country API — a single `POST` whose body selects Indonesia (country symbol `39`). Like the FRED
/// and BI-rate legs it is public, unauthenticated data off its own host, so it rides a plain
/// `HTTPSession` (never the Stockbit client) and stays outside the Stockbit anti-burst throttle.
/// Parsing lives in `MacroParsing.parseWorldGovBonds` (offline-testable); this type only does the
/// one request and hands the body off.
nonisolated final class IndonesiaSovereignService: IndonesiaSovereignProviding {
    private static let endpoint = "https://www.worldgovernmentbonds.com/wp-json/country/v1/main"
    private static let origin = "https://www.worldgovernmentbonds.com"

    /// The POST body that selects Indonesia, captured verbatim from the site. `SYMBOL` `39` is
    /// Indonesia's country id; the `ENDPOINT`/`DATE_RIF` fields are the page's own historical-API
    /// wiring and are echoed unchanged. The host gates the API on the `Origin` header (a bare POST
    /// returns an empty body), so the request sets it.
    private static let indonesiaBody = """
    {"GLOBALVAR":{"JS_VARIABLE":"jsGlobalVars","FUNCTION":"Country","DOMESTIC":true,\
    "ENDPOINT":"https://www.worldgovernmentbonds.com/wp-json/country/v1/historical",\
    "DATE_RIF":"2099-12-31","OBJ":null,\
    "COUNTRY1":{"SYMBOL":"39","PAESE":"Indonesia","PAESE_UPPERCASE":"INDONESIA",\
    "BANDIERA":"id","URL_PAGE":"indonesia"},"COUNTRY2":null,"OBJ1":null,"OBJ2":null}}
    """

    private let session: any HTTPSession

    init(session: any HTTPSession) {
        self.session = session
    }

    func sovereign() async -> IndonesiaSovereignReading? {
        guard let url = URL(string: Self.endpoint),
              let json = await MacroHTTP.postJSON(
                Self.indonesiaBody, to: url,
                headers: ["Origin": Self.origin, "Referer": Self.origin + "/country/indonesia/"],
                session: session)
        else { return nil }
        return MacroParsing.parseWorldGovBonds(json)
    }
}
