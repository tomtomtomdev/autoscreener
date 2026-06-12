import Foundation

nonisolated protocol BIRateProviding: Sendable {
    /// The latest BI policy rate + last-move direction, or `nil` when neither the
    /// primary (bi.go.id) nor the fallback (FRED) source could be read. Absence is
    /// information — the regime read simply drops the policy-rate factor.
    func biRate() async -> RegimeSnapshot.BIRate?
}

/// Fetches Bank Indonesia's policy rate on-device — the leg that used to be patched into
/// `regime.json` by the daily Python job (`refresh_bi.py`). The BI-Rate page is plain,
/// server-rendered HTML (no Cloudflare, no auth), so — like `RegimeSnapshotService` — it
/// goes over a plain `HTTPSession`, *not* the authenticated Stockbit `APIClient`.
///
/// Primary source is bi.go.id (fresh — BI moves its rate mid-month); on any failure or an
/// unparseable table it falls back to the FRED CSV (`IRSTCB01IDM156N`, monthly, lags ~1
/// month but never blanks the factor). All parsing lives in `MacroParsing` so it's
/// unit-testable offline.
nonisolated final class BIRateService: BIRateProviding {
    /// bi.go.id BI-Rate history (server-rendered HTML).
    static let biRateURL = URL(string: "https://www.bi.go.id/id/statistik/indikator/BI-Rate.aspx")!
    /// FRED CSV fallback / cross-check — Indonesia policy rate, no API key.
    static let fredFallbackURL = URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=IRSTCB01IDM156N")!

    private let session: any HTTPSession

    init(session: any HTTPSession) {
        self.session = session
    }

    func biRate() async -> RegimeSnapshot.BIRate? {
        if let html = await MacroHTTP.text(from: Self.biRateURL, session: session),
           let bi = MacroParsing.toBIRate(MacroParsing.parseBIRateHTML(html)) {
            return bi
        }
        guard let csv = await MacroHTTP.text(from: Self.fredFallbackURL, session: session) else { return nil }
        return MacroParsing.toBIRate(MacroParsing.parseFREDCSV(csv))
    }
}
