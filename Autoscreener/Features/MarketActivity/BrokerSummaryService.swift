import Foundation

/// Period windows accepted by `GET /marketdetectors/{symbol}`.
nonisolated enum BrokerSummaryPeriod: String, Sendable, CaseIterable {
    case latest = "BROKER_SUMMARY_PERIOD_LATEST"
    case last7Days = "BROKER_SUMMARY_PERIOD_LAST_7_DAYS"
    case last1Month = "BROKER_SUMMARY_PERIOD_LAST_1_MONTH"
}

nonisolated protocol BrokerSummaryServicing: Sendable {
    func summary(
        symbol: String,
        period: BrokerSummaryPeriod,
        limit: Int
    ) async throws -> BrokerSummary
}

extension BrokerSummaryServicing {
    func summary(symbol: String, period: BrokerSummaryPeriod = .latest) async throws -> BrokerSummary {
        try await summary(symbol: symbol, period: period, limit: 25)
    }
}

/// Reads Stockbit's broker-summary / "Bandar Detector" feed for a single symbol —
/// the top net buyers and sellers plus the accumulation/distribution aggregation.
///
/// `investorType` (1 = all), `marketBoard` (2 = regular) and `transactionType`
/// (1 = net) are pinned to the values the iOS app sends for the default view.
nonisolated final class BrokerSummaryService: BrokerSummaryServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func summary(
        symbol: String,
        period: BrokerSummaryPeriod,
        limit: Int = 25
    ) async throws -> BrokerSummary {
        let endpoint = Endpoint(
            method: .get,
            path: "marketdetectors/\(symbol)",
            query: [
                URLQueryItem(name: "investor_type", value: "1"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "market_board", value: "2"),
                URLQueryItem(name: "period", value: period.rawValue),
                URLQueryItem(name: "transaction_type", value: "1"),
            ]
        )
        let dto = try await apiClient.send(endpoint, as: BrokerSummaryResponseDTO.self)
        return dto.toDomain()
    }
}
