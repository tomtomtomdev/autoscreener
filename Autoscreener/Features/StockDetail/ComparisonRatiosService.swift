import Foundation

// MARK: - Domain

/// A peer-comparison ratio matrix from Stockbit's `comparison/v2/ratios` endpoint.
///
/// Stockbit returns the **subject ticker first**, followed by the `INDUSTRY` and `SECTOR`
/// aggregate benchmarks — e.g. `symbols == ["TPIA", "INDUSTRY", "SECTOR"]` — so this is really
/// "the stock vs. its industry / sector averages", which is exactly the comparison set a
/// relative-cheapness read wants. Metrics are grouped (Valuation / Per Share / Solvency / …),
/// and every cell value arrives as a Stockbit display string (`"154,423 B"`, `"15.67"`, `"-"`).
nonisolated struct PeerComparison: Sendable, Equatable {
    /// Compared columns, subject first then the benchmark aggregates.
    let symbols: [String]
    let groups: [PeerMetricGroup]

    /// The subject column label (the requested ticker), if present.
    var subject: String? { symbols.first }

    /// First metric across all groups whose `name` matches exactly.
    func metric(named name: String) -> PeerMetric? {
        groups.lazy.flatMap(\.metrics).first { $0.name == name }
    }

    /// The subject's parsed value for a named metric — `nil` if the metric is absent or the
    /// cell was non-numeric (`"-"`).
    func subjectValue(forMetric name: String) -> Double? {
        guard let subject else { return nil }
        return metric(named: name)?.numeric[subject]
    }
}

nonisolated struct PeerMetricGroup: Sendable, Equatable {
    let name: String                 // "Valuation", "Per Share", …
    let metrics: [PeerMetric]
}

nonisolated struct PeerMetric: Sendable, Equatable {
    let id: Int                      // fitem_id — stable & language-independent
    let name: String                 // fitem_name, e.g. "Market Cap"
    let raw: [String: String]        // column symbol → verbatim display value
    let numeric: [String: Double]    // column symbol → parsed (scaled) value; non-numeric cells omitted
}

// MARK: - Service

nonisolated enum ComparisonRatiosError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol ComparisonRatiosServicing: Sendable {
    /// The subject ticker's ratio matrix against its industry / sector benchmarks.
    func comparison(symbol: String) async throws -> PeerComparison
}

/// Reads Stockbit's peer-comparison ratios (`GET comparison/v2/ratios?symbol={symbol}`):
/// the subject's valuation / per-share / solvency / profitability metrics alongside the
/// `INDUSTRY` and `SECTOR` aggregate benchmarks.
nonisolated final class ComparisonRatiosService: ComparisonRatiosServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func comparison(symbol: String) async throws -> PeerComparison {
        let data = try await rawData(symbol: symbol)
        do {
            return try Self.parse(data)
        } catch {
            throw ComparisonRatiosError.malformedResponse
        }
    }

    /// Fetch + `APIError` → domain-error mapping, mirroring `KeystatsRatioService`.
    private func rawData(symbol: String) async throws -> Data {
        do {
            return try await apiClient.sendRaw(Self.makeEndpoint(symbol: symbol))
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw ComparisonRatiosError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw ComparisonRatiosError.paywall
        } catch let err as APIError {
            throw ComparisonRatiosError.network(String(describing: err))
        }
    }

    /// Builds `GET comparison/v2/ratios?symbol={symbol}`. The benchmark columns
    /// (INDUSTRY / SECTOR) are selected server-side from the subject alone.
    static func makeEndpoint(symbol: String) -> Endpoint {
        Endpoint(
            method: .get,
            path: "comparison/v2/ratios",
            query: [URLQueryItem(name: "symbol", value: symbol)]
        )
    }

    /// Decodes the envelope and maps the grouped wire shape into `PeerComparison`, parsing each
    /// display-string cell with `DisplayNumber.parseScaledDecimal` (handles `"154,423 B"`,
    /// `"15.67"`, `"31.87%"`, `"(1,899 B)"`, `"-"`→omitted). Throws when `data` is absent.
    static func parse(_ data: Data) throws -> PeerComparison {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<ComparisonDTO>.self, from: data)
        guard let dto = envelope.data else { throw ComparisonRatiosError.malformedResponse }

        let groups = dto.metricGroups.map { group in
            PeerMetricGroup(name: group.name, metrics: group.metrics.map { metric in
                var raw: [String: String] = [:]
                var numeric: [String: Double] = [:]
                for cell in metric.ratios {
                    raw[cell.symbol] = cell.value
                    if let value = DisplayNumber.parseScaledDecimal(cell.value) {
                        numeric[cell.symbol] = value
                    }
                }
                return PeerMetric(id: metric.fitemID, name: metric.fitemName, raw: raw, numeric: numeric)
            })
        }
        return PeerComparison(symbols: dto.symbols, groups: groups)
    }
}

// MARK: - DTO (Stockbit `GET /comparison/v2/ratios`)

/// `data.metric_groups[]` → `{ metric_group_name, metric: [{ fitem_id, fitem_name,
/// ratios: [{ symbol, value }] }] }`. `value` is a display string.
private struct ComparisonDTO: Decodable {
    let symbols: [String]
    let metricGroups: [GroupDTO]
    enum CodingKeys: String, CodingKey { case symbols; case metricGroups = "metric_groups" }

    struct GroupDTO: Decodable {
        let name: String
        let metrics: [MetricDTO]
        enum CodingKeys: String, CodingKey { case name = "metric_group_name"; case metrics = "metric" }
    }

    struct MetricDTO: Decodable {
        let fitemID: Int
        let fitemName: String
        let ratios: [RatioDTO]
        enum CodingKeys: String, CodingKey {
            case fitemID = "fitem_id"
            case fitemName = "fitem_name"
            case ratios
        }
    }

    struct RatioDTO: Decodable {
        let symbol: String
        let value: String
    }
}
