import Foundation

nonisolated protocol FREDMacroProviding: Sendable {
    /// The global macro anchors (US fed funds / 10y / broad dollar), or `nil` when none
    /// of the three series could be read. Each series is independent: one failed/empty
    /// fetch is omitted from the block, not fatal — so a single bad series degrades the
    /// read by one factor rather than dropping the whole macro leg.
    func macro() async -> RegimeSnapshot.MacroBlock?
}

/// Fetches the FRED global anchors on-device — the leg the Python scraper wrote into the
/// `macro` block of `regime.json`.
///
/// Primary path is the **keyed JSON API** (`series/observations?...&file_type=json`) when a
/// key is configured (`FREDKeyStore`, seeded into the Keychain). It pulls only the most
/// recent observations (`sort_order=desc&limit=…`) rather than the full multi-decade
/// history, so the macro leg is a few KB. When no key is present it falls back to the
/// original keyless CSV endpoint (`fredgraph.csv?id=…`), so the leg still works without a
/// key. Either way it rides a plain `HTTPSession` — public data, never the authenticated
/// Stockbit client — and parsing lives in `MacroParsing` (offline-testable); this type only
/// does the three GETs and assembly.
///
/// `DTWEXBGS` (broad trade-weighted dollar) is the EM-relevant dollar gauge — more apt
/// for the rupiah than the proprietary ICE DXY, and free.
nonisolated final class FREDMacroService: FREDMacroProviding {
    /// Keyed JSON API — preferred when an API key is configured.
    private static let apiBase = "https://api.stlouisfed.org/fred/series/observations"
    /// Keyless CSV fallback (the original path) — used when no key is configured.
    private static let csvBase = "https://fred.stlouisfed.org/graph/fredgraph.csv?id="
    /// How many recent observations to request from the API. The trend lookback is 20
    /// observations (`MacroParsing.trend`); 40 daily points (~8 weeks) covers it with margin
    /// while keeping the payload tiny.
    private static let recentLimit = 40

    /// Keyed as they appear in the `macro` block of the `RegimeSnapshot` contract.
    static let series: [(key: String, id: String)] = [
        ("usFedFunds", "DFF"),
        ("us10y", "DGS10"),
        ("broadDollar", "DTWEXBGS"),
    ]

    private let session: any HTTPSession
    private let apiKey: String?

    /// - Parameter apiKey: the FRED API key. `nil` → the keyless CSV fallback. Inject from
    ///   `FREDKeyStore().apiKey` in production; pass an explicit value (or `nil`) in tests.
    init(session: any HTTPSession, apiKey: String? = nil) {
        self.session = session
        self.apiKey = apiKey
    }

    func macro() async -> RegimeSnapshot.MacroBlock? {
        var byKey: [String: RegimeSnapshot.MacroSeries] = [:]
        for (key, id) in Self.series {
            guard let series = await fetchSeries(id: id) else { continue }
            byKey[key] = series
        }
        guard !byKey.isEmpty else { return nil }
        return RegimeSnapshot.MacroBlock(
            usFedFunds: byKey["usFedFunds"],
            us10y: byKey["us10y"],
            broadDollar: byKey["broadDollar"])
    }

    /// One series via the keyed JSON API when a key is configured, else the keyless CSV
    /// endpoint. `nil` when the fetch fails or parses empty — the caller omits it from the
    /// block (a bad key yields FRED's `error_*` JSON, which `parseFREDJSON` reads as empty).
    private func fetchSeries(id: String) async -> RegimeSnapshot.MacroSeries? {
        if let url = apiURL(id: id) {
            guard let json = await MacroHTTP.text(from: url, session: session) else { return nil }
            return MacroParsing.toMacroSeries(MacroParsing.parseFREDJSON(json))
        }
        guard let url = URL(string: Self.csvBase + id),
              let csv = await MacroHTTP.text(from: url, session: session) else { return nil }
        return MacroParsing.toMacroSeries(MacroParsing.parseFREDSeries(csv))
    }

    /// The keyed JSON observations URL, or `nil` when no key is configured (CSV fallback).
    private func apiURL(id: String) -> URL? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: Self.apiBase)
        components?.queryItems = [
            URLQueryItem(name: "series_id", value: id),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "file_type", value: "json"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "limit", value: String(Self.recentLimit)),
        ]
        return components?.url
    }
}
