import Foundation

// MARK: - Domain

/// A company research note from Stockbit's `research/company/{SYM}` endpoint — qualitative,
/// display-only text for the StockDetail UI (never a selection input).
///
/// The envelope shape **is** verified (`{ id, symbol, content, masks }`), but in the 2026-06-11
/// capture `content` was empty for every captured symbol (no coverage / paywalled). The service
/// therefore treats an empty `content` as "no research" and returns `nil`, so a returned
/// `CompanyResearch` always carries non-empty `content`. `masks` was an empty object whose purpose is
/// unknown — left undeclared (ignored) until a populated capture clarifies it (§3.5 / §6).
nonisolated struct CompanyResearch: Sendable, Equatable {
    let id: Int
    let symbol: String
    let content: String          // HTML / rich text; non-empty by construction
}

// MARK: - Service

nonisolated enum ResearchError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol ResearchServicing: Sendable {
    /// The symbol's research note, or `nil` when there is no research (empty `content`).
    func research(symbol: String) async throws -> CompanyResearch?
}

/// Reads Stockbit's company research (`GET research/company/{SYM}`). The wire shape is known; the
/// captured payloads were empty (no coverage), so an empty `content` degrades to `nil` rather than a
/// thrown error. Error mapping mirrors `SeasonalityService` (`401`→`.unauthorized`, `402|403`→`.paywall`).
nonisolated final class ResearchService: ResearchServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func research(symbol: String) async throws -> CompanyResearch? {
        let data = try await rawData(symbol: symbol)
        do {
            return try Self.parse(data)
        } catch {
            throw ResearchError.malformedResponse
        }
    }

    /// Fetch + `APIError` → domain-error mapping, mirroring `SeasonalityService`.
    private func rawData(symbol: String) async throws -> Data {
        do {
            return try await apiClient.sendRaw(Self.makeEndpoint(symbol: symbol))
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw ResearchError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw ResearchError.paywall
        } catch let err as APIError {
            throw ResearchError.network(String(describing: err))
        }
    }

    /// Builds `GET research/company/{SYM}`.
    static func makeEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "research/company/\(symbol)")
    }

    /// Decodes the envelope; absent `data` or empty `content` ⇒ `nil` ("no research").
    static func parse(_ data: Data) throws -> CompanyResearch? {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<ResearchDTO>.self, from: data)
        guard let dto = envelope.data, !dto.content.isEmpty else { return nil }
        return CompanyResearch(id: dto.id, symbol: dto.symbol, content: dto.content)
    }
}

// MARK: - DTO (Stockbit `GET /research/company/{SYM}`)

/// `data` is `{ id, symbol, content, masks }`. `masks` (an empty `{}` in the capture, purpose
/// unknown) is intentionally undeclared, so it's skipped.
private struct ResearchDTO: Decodable {
    let id: Int
    let symbol: String
    let content: String
}
