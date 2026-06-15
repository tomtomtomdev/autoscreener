import Foundation

nonisolated enum CommodityPriceError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol CommodityPriceServicing: Sendable {
    /// The latest price snapshot for one commodity / FX symbol.
    func quote(symbol: String) async throws -> CommodityQuote
}

/// Reads a commodity's price snapshot from Stockbit's `emitten/{symbol}/info`.
/// The same path/shape serves stocks and indices; here it backs the Markets
/// commodities + currencies rows. Mirrors `ChartService`'s structure: a static
/// `makeEndpoint`/`parse` pair for unit testing, plus `APIError` → domain-error
/// mapping in the async entry point.
nonisolated final class CommodityPriceService: CommodityPriceServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func quote(symbol: String) async throws -> CommodityQuote {
        let data: Data
        do {
            data = try await apiClient.sendRaw(Self.makeEndpoint(symbol: symbol))
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw CommodityPriceError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw CommodityPriceError.paywall
        } catch let err as APIError {
            throw CommodityPriceError.network(String(describing: err))
        }
        do {
            return try Self.parse(data)
        } catch {
            throw CommodityPriceError.malformedResponse
        }
    }

    // MARK: - Wire format

    /// `GET emitten/{symbol}/info` — no query, auth required.
    static func makeEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "emitten/\(symbol)/info")
    }

    static func parse(_ data: Data) throws -> CommodityQuote {
        try JSONDecoder().decode(EmittenInfoResponseDTO.self, from: data).toDomain()
    }
}
