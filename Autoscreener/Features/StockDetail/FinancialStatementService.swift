import Foundation

nonisolated enum FinancialStatementError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol FinancialStatementServicing: Sendable {
    func load(symbol: String,
              report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement
}

nonisolated final class FinancialStatementService: FinancialStatementServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func load(symbol: String,
              report: FinancialReportType,
              basis: FinancialPeriodBasis) async throws -> FinancialStatement {
        let endpoint = Self.makeEndpoint(symbol: symbol, report: report, basis: basis)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw FinancialStatementError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw FinancialStatementError.paywall
        } catch let err as APIError {
            throw FinancialStatementError.network(String(describing: err))
        }
        do {
            return try Self.parse(data)
        } catch {
            throw FinancialStatementError.malformedResponse
        }
    }

    // MARK: - Wire format

    /// Builds `GET findata-view/v2/financials/{symbol}` with the fixed
    /// `data_type=1&is_percentage=0&page=1` plus the report/basis selectors.
    static func makeEndpoint(symbol: String,
                             report: FinancialReportType,
                             basis: FinancialPeriodBasis) -> Endpoint {
        Endpoint(
            method: .get,
            path: "findata-view/v2/financials/\(symbol)",
            query: [
                URLQueryItem(name: "data_type", value: "1"),
                URLQueryItem(name: "is_percentage", value: "0"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "report_type", value: String(report.rawValue)),
                URLQueryItem(name: "statement_type", value: String(basis.rawValue)),
            ])
    }

    static func parse(_ data: Data) throws -> FinancialStatement {
        let dto = try JSONDecoder().decode(FinancialsResponseDTO.self, from: data)
        return dto.toDomain()
    }
}
