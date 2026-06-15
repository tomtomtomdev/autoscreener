import Foundation

nonisolated enum RegimeSnapshotError: Error, Equatable {
    case network(String)
    case malformedResponse
    /// 404 — the `data` branch / `regime.json` isn't published yet. Expected until the
    /// server-side job ships; the regime read degrades to its live-only factors.
    case notFound
}

nonisolated protocol RegimeSnapshotProviding: Sendable {
    func snapshot() async throws -> RegimeSnapshot
}

/// Fetches the server-side `regime.json` (`idx-regime-data-research.md` §6) over plain
/// HTTPS. It is public, static, unauthenticated data committed to the repo's `data`
/// branch, so it deliberately does **not** go through the authenticated Stockbit
/// `APIClient`. All the Cloudflare/scraping work lives in the server-side job; the app
/// only does a `GET` of the raw JSON and computes the read on-device.
///
/// Its authoritative payload is now the `indices` (valuation/percentile) block. The
/// snapshot's `biRate`/`macro` are still decoded but treated as a *fallback* by
/// `DataSweepCoordinator`, which fetches both live on-device (`BIRateService` /
/// `FREDMacroService`) and merges those over the published values.
nonisolated final class RegimeSnapshotService: RegimeSnapshotProviding {
    /// Raw URL of the committed snapshot on the `data` branch the scraper writes (the
    /// §6 plan). Until that job ships this 404s, and the read falls back to live factors
    /// only — by design, not an error to surface loudly.
    static let defaultURL = URL(string: "https://raw.githubusercontent.com/tomtomtomdev/autoscreener/data/regime.json")!

    private let session: any HTTPSession
    private let url: URL

    init(session: any HTTPSession, url: URL = RegimeSnapshotService.defaultURL) {
        self.session = session
        self.url = url
    }

    func snapshot() async throws -> RegimeSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RegimeSnapshotError.network(String(describing: error))
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw RegimeSnapshotError.notFound }
            guard (200..<300).contains(http.statusCode) else {
                throw RegimeSnapshotError.network("HTTP \(http.statusCode)")
            }
        }
        do {
            return try Self.parse(data)
        } catch {
            throw RegimeSnapshotError.malformedResponse
        }
    }

    /// Decodes the `regime.json` contract. Pure + static so it's unit-testable against a
    /// saved fixture without any networking.
    static func parse(_ data: Data) throws -> RegimeSnapshot {
        try JSONDecoder().decode(RegimeSnapshot.self, from: data)
    }
}
