import Foundation

nonisolated protocol FREDMacroProviding: Sendable {
    /// The global macro anchors (US fed funds / 10y / broad dollar), or `nil` when none
    /// of the three series could be read. Each series is independent: one failed/empty
    /// fetch is omitted from the block, not fatal — so a single bad series degrades the
    /// read by one factor rather than dropping the whole macro leg.
    func macro() async -> RegimeSnapshot.MacroBlock?
}

/// Fetches the FRED global anchors on-device — the leg the Python scraper wrote into the
/// `macro` block of `regime.json`. All three are plain CSV (`fredgraph.csv?id=…`, no API
/// key, no Cloudflare), so — like `RegimeSnapshotService` / `BIRateService` — this rides a
/// plain `HTTPSession`, not the authenticated Stockbit client. Parsing lives in
/// `MacroParsing` (offline-testable); this type only does the three GETs and assembly.
///
/// `DTWEXBGS` (broad trade-weighted dollar) is the EM-relevant dollar gauge — more apt
/// for the rupiah than the proprietary ICE DXY, and free.
nonisolated final class FREDMacroService: FREDMacroProviding {
    private static let base = "https://fred.stlouisfed.org/graph/fredgraph.csv?id="
    /// Keyed as they appear in the `macro` block of the `RegimeSnapshot` contract.
    static let series: [(key: String, id: String)] = [
        ("usFedFunds", "DFF"),
        ("us10y", "DGS10"),
        ("broadDollar", "DTWEXBGS"),
    ]

    private let session: any HTTPSession

    init(session: any HTTPSession) {
        self.session = session
    }

    func macro() async -> RegimeSnapshot.MacroBlock? {
        var byKey: [String: RegimeSnapshot.MacroSeries] = [:]
        for (key, id) in Self.series {
            guard let url = URL(string: Self.base + id),
                  let csv = await MacroHTTP.text(from: url, session: session),
                  let parsed = MacroParsing.toMacroSeries(MacroParsing.parseFREDSeries(csv)) else { continue }
            byKey[key] = parsed
        }
        guard !byKey.isEmpty else { return nil }
        return RegimeSnapshot.MacroBlock(
            usFedFunds: byKey["usFedFunds"],
            us10y: byKey["us10y"],
            broadDollar: byKey["broadDollar"])
    }
}
