import Foundation

/// Period windows accepted by the foreign-domestic chart-data endpoint.
/// `oneDay` and `oneMonth` are confirmed against the live API; longer ranges
/// (`PERIOD_RANGE_3M`, `_6M`, `_1Y`, …) likely exist but are not yet verified.
nonisolated enum ForeignFlowPeriod: String, Sendable, CaseIterable {
    case oneDay = "PERIOD_RANGE_1D"
    case oneMonth = "PERIOD_RANGE_1M"
}

/// Market scope. Only `regular` is confirmed against the live API.
nonisolated enum ForeignFlowMarketType: String, Sendable {
    case regular = "MARKET_TYPE_REGULAR"
}

nonisolated protocol ForeignFlowServicing: Sendable {
    func flow(
        symbol: String,
        period: ForeignFlowPeriod,
        marketType: ForeignFlowMarketType
    ) async throws -> ForeignFlow
}

extension ForeignFlowServicing {
    func flow(symbol: String, period: ForeignFlowPeriod = .oneDay) async throws -> ForeignFlow {
        try await flow(symbol: symbol, period: period, marketType: .regular)
    }
}

/// Reads Stockbit's foreign vs. domestic money-flow aggregation for one symbol
/// (the "net buy asing" / foreign-flow view).
nonisolated final class ForeignFlowService: ForeignFlowServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func flow(
        symbol: String,
        period: ForeignFlowPeriod,
        marketType: ForeignFlowMarketType = .regular
    ) async throws -> ForeignFlow {
        let endpoint = Endpoint(
            method: .get,
            path: "findata-view/foreign-domestic/v1/chart-data/\(symbol)",
            query: [
                URLQueryItem(name: "market_type", value: marketType.rawValue),
                URLQueryItem(name: "period", value: period.rawValue),
            ]
        )
        let dto = try await apiClient.send(endpoint, as: ForeignFlowResponseDTO.self)
        return dto.toDomain(symbol: symbol)
    }
}
