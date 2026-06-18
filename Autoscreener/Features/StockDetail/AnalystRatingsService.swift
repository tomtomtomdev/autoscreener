import Foundation

// MARK: - Domain

/// Sell-side analyst coverage for a symbol from Stockbit's `analyst-ratings/{SYM}` endpoint:
/// the consensus price target (mean / low / high vs current price), the headline recommendation,
/// and the buy/hold/sell analyst tally.
///
/// Shape verified against a covered large-cap re-capture (BBCA, 2026-06-12 — see
/// CAPTURED-ENDPOINTS-SPEC.md §6). An uncovered name replies `data: null`, which the service degrades
/// to `nil` ("no coverage"), so a `AnalystCoverage` value is always fully populated.
nonisolated struct AnalystCoverage: Sendable, Equatable, Codable {
    let priceTarget: AnalystPriceTarget
    let recommendation: String          // "Buy" / "Hold" / "Sell" / "Strong Buy" … (verbatim)
    let totalBuy: Int
    let totalHold: Int
    let totalSell: Int
    let totalAnalyst: Int
    let lastUpdated: String             // display date, e.g. "11 Jun 26"

    /// Implied upside of the consensus (best) target over the current price, as a ratio
    /// (`0.49` = +49%); `nil` when there is no positive current price to divide by.
    var targetUpsidePct: Double? {
        guard priceTarget.current > 0 else { return nil }
        return (priceTarget.best - priceTarget.current) / priceTarget.current
    }
}

/// The consensus price-target band and the price it is measured against (rupiah).
nonisolated struct AnalystPriceTarget: Sendable, Equatable, Codable {
    let best: Double                    // best_target — consensus / mean target
    let low: Double                     // best_low_target
    let high: Double                    // best_high_target
    let current: Double                 // current_price at capture time
}

/// One forward-estimate series from `analyst-ratings/{SYM}/consensus` — a single line item
/// (Revenue / Op. Profit / Net Income / EPS) with its actual-then-estimated values by year.
nonisolated struct AnalystEstimateSeries: Sendable, Equatable {
    let name: String                    // "Revenue", "Op. Profit", "Net Income", "EPS"
    let items: [AnalystEstimate]
}

/// One year's figure within an `AnalystEstimateSeries`.
nonisolated struct AnalystEstimate: Sendable, Equatable {
    let year: Int
    let isEstimate: Bool                // false = reported actual, true = forward analyst estimate
    let value: Double?                  // parsed from the display string; `nil` if non-numeric
}

// MARK: - Service

nonisolated enum AnalystRatingsError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol AnalystRatingsServicing: Sendable {
    /// The symbol's analyst-rating block, or `nil` when the name carries no sell-side coverage
    /// (Stockbit replies `data: null`).
    func coverage(symbol: String) async throws -> AnalystCoverage?
    /// The symbol's forward consensus-estimate series, or `[]` when there is no coverage
    /// (`data: []`/`null`).
    func consensus(symbol: String) async throws -> [AnalystEstimateSeries]
}

/// Reads Stockbit's analyst coverage (`GET analyst-ratings/{SYM}` and `…/consensus`). An empty
/// payload (`null` / `[]`) is the legitimate "no coverage" answer (`nil` / `[]`), never a thrown
/// error. Error mapping mirrors `KeystatsRatioService` / `SeasonalityService` (`401`→`.unauthorized`,
/// `402|403`→`.paywall`).
nonisolated final class AnalystRatingsService: AnalystRatingsServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func coverage(symbol: String) async throws -> AnalystCoverage? {
        let data = try await rawData(Self.makeCoverageEndpoint(symbol: symbol))
        do {
            return try Self.parseCoverage(data)
        } catch {
            throw AnalystRatingsError.malformedResponse
        }
    }

    func consensus(symbol: String) async throws -> [AnalystEstimateSeries] {
        let data = try await rawData(Self.makeConsensusEndpoint(symbol: symbol))
        do {
            return try Self.parseConsensus(data)
        } catch {
            throw AnalystRatingsError.malformedResponse
        }
    }

    /// Fetch + `APIError` → domain-error mapping, mirroring `SeasonalityService`.
    private func rawData(_ endpoint: Endpoint) async throws -> Data {
        do {
            return try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw AnalystRatingsError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw AnalystRatingsError.paywall
        } catch let err as APIError {
            throw AnalystRatingsError.network(String(describing: err))
        }
    }

    /// Builds `GET analyst-ratings/{SYM}`.
    static func makeCoverageEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "analyst-ratings/\(symbol)")
    }

    /// Builds `GET analyst-ratings/{SYM}/consensus`.
    static func makeConsensusEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "analyst-ratings/\(symbol)/consensus")
    }

    /// Decodes the envelope; `data: null` ⇒ `nil` ("no coverage").
    static func parseCoverage(_ data: Data) throws -> AnalystCoverage? {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<CoverageDTO>.self, from: data)
        return envelope.data.map { dto in
            AnalystCoverage(
                priceTarget: AnalystPriceTarget(
                    best: dto.priceTarget.bestTarget,
                    low: dto.priceTarget.bestLowTarget,
                    high: dto.priceTarget.bestHighTarget,
                    current: dto.priceTarget.currentPrice),
                recommendation: dto.recommendation,
                totalBuy: dto.totalBuy,
                totalHold: dto.totalHold,
                totalSell: dto.totalSell,
                totalAnalyst: dto.totalAnalyst,
                lastUpdated: dto.lastUpdated)
        }
    }

    /// Decodes the envelope; `data: []` or `null` ⇒ `[]` ("no coverage"). The real figure is the
    /// display-string `value` (the wire `raw_value` is `0`), parsed via `DisplayNumber.parseScaledDecimal`
    /// (handles `"118,573 B"` → `118_573e9` and bare decimals like EPS `"466.74"`).
    static func parseConsensus(_ data: Data) throws -> [AnalystEstimateSeries] {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<[SeriesDTO]>.self, from: data)
        return (envelope.data ?? []).map { series in
            AnalystEstimateSeries(name: series.name, items: series.items.map { item in
                AnalystEstimate(year: item.year,
                                isEstimate: item.isEstimate,
                                value: DisplayNumber.parseScaledDecimal(item.value))
            })
        }
    }
}

// MARK: - DTO (Stockbit `GET /analyst-ratings/{SYM}` — verified vs BBCA, §6)

/// `data` = `{ price_target{ best_target, best_low_target, best_high_target, current_price },
/// recommendation, total_buy, total_sell, total_hold, total_analyst, last_updated }`. Targets are
/// JSON ints (decoded as `Double` for the upside arithmetic).
private struct CoverageDTO: Decodable {
    let priceTarget: PriceTargetDTO
    let recommendation: String
    let totalBuy: Int
    let totalSell: Int
    let totalHold: Int
    let totalAnalyst: Int
    let lastUpdated: String
    enum CodingKeys: String, CodingKey {
        case priceTarget = "price_target"
        case recommendation
        case totalBuy = "total_buy"
        case totalSell = "total_sell"
        case totalHold = "total_hold"
        case totalAnalyst = "total_analyst"
        case lastUpdated = "last_updated"
    }

    struct PriceTargetDTO: Decodable {
        let bestTarget: Double
        let bestLowTarget: Double
        let bestHighTarget: Double
        let currentPrice: Double
        enum CodingKeys: String, CodingKey {
            case bestTarget = "best_target"
            case bestLowTarget = "best_low_target"
            case bestHighTarget = "best_high_target"
            case currentPrice = "current_price"
        }
    }
}

/// `data[]` = `{ name, items: [{ year, is_estimate, value: String, raw_value }] }`. `raw_value` is
/// `0` on the wire (the figure lives in the display-string `value`), so it is left undeclared.
private struct SeriesDTO: Decodable {
    let name: String
    let items: [ItemDTO]

    struct ItemDTO: Decodable {
        let year: Int
        let isEstimate: Bool
        let value: String
        enum CodingKeys: String, CodingKey {
            case year
            case isEstimate = "is_estimate"
            case value
        }
    }
}
