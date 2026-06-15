import Foundation

nonisolated enum ChartError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol ChartServicing: Sendable {
    func candles(
        symbol: String,
        timeframe: ChartTimeframe,
        chartType: ChartType
    ) async throws -> PriceSeries
}

extension ChartServicing {
    /// Convenience: candlestick OHLCV for the given window (default: one year of daily bars).
    func candles(symbol: String, timeframe: ChartTimeframe = .oneYear) async throws -> PriceSeries {
        try await candles(symbol: symbol, timeframe: timeframe, chartType: .candle)
    }
}

/// Reads Stockbit's OHLCV chart series for one symbol. Works identically for the
/// market index (`IHSG`) and an individual stock (`CUAN`) — same path, same shape.
nonisolated final class ChartService: ChartServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func candles(
        symbol: String,
        timeframe: ChartTimeframe,
        chartType: ChartType = .candle
    ) async throws -> PriceSeries {
        let endpoint = Self.makeEndpoint(symbol: symbol, timeframe: timeframe, chartType: chartType)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw ChartError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw ChartError.paywall
        } catch let err as APIError {
            throw ChartError.network(String(describing: err))
        }
        do {
            return try Self.parse(data, symbol: symbol, timeframe: timeframe)
        } catch {
            throw ChartError.malformedResponse
        }
    }

    // MARK: - Wire format

    /// Builds `GET charts/{symbol}/daily` with the chart-type + timeframe selectors
    /// and the fixed `is_include_previous_historical=1`.
    static func makeEndpoint(symbol: String, timeframe: ChartTimeframe, chartType: ChartType) -> Endpoint {
        Endpoint(
            method: .get,
            path: "charts/\(symbol)/daily",
            query: [
                URLQueryItem(name: "chart_type", value: chartType.rawValue),
                URLQueryItem(name: "is_include_previous_historical", value: "1"),
                URLQueryItem(name: "timeframe", value: timeframe.rawValue),
            ])
    }

    static func parse(_ data: Data, symbol: String, timeframe: ChartTimeframe) throws -> PriceSeries {
        let dto = try JSONDecoder().decode(ChartResponseDTO.self, from: data)
        return try dto.toDomain(symbol: symbol, timeframe: timeframe)
    }
}
