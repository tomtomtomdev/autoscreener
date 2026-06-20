import Foundation

/// The thin impure layer for the on-device macro fetchers (`BIRateService`,
/// `FREDMacroService`): a single `GET` that returns the decoded body text on success or
/// `nil` on any failure (network error, non-2xx, undecodable). Kept tiny and separate so
/// the parsing in `MacroParsing` stays pure and offline-testable — mirroring how the
/// Python scraper isolates `sources.py` from its `aggregate`/`bi_rate`/`macro` logic.
///
/// These are public, static, unauthenticated feeds (bi.go.id, FRED), so — like
/// `RegimeSnapshotService` — they ride a plain `HTTPSession`, never the Stockbit client.
nonisolated enum MacroHTTP {
    /// A desktop browser UA — bi.go.id serves a different/blocked body to obvious bots
    /// (port of the scraper's `_BROWSER_UA`); harmless for FRED.
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    static func text(from url: URL, session: any HTTPSession) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A JSON `POST` returning the decoded body text on success or `nil` on any failure — the
    /// `text(from:session:)` analogue for the one regime leg (`IndonesiaSovereignService`) that
    /// reads a country API which only answers `POST`. `headers` carries the per-host extras the
    /// endpoint requires (e.g. the `Origin` worldgovernmentbonds.com gates on); the browser UA and
    /// JSON content-type are always set.
    static func postJSON(_ body: String, to url: URL,
                         headers: [String: String] = [:],
                         session: any HTTPSession) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body.data(using: .utf8)

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
