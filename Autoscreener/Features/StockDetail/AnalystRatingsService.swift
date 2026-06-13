import Foundation

// MARK: - Domain

/// Sell-side analyst coverage for a symbol from Stockbit's `analyst-ratings/{SYM}` endpoint.
///
/// ⚠️ **Skeleton — populated shape UNVERIFIED.** In the 2026-06-11 capture this endpoint returned
/// `data: null` for every captured symbol (TPIA, IHSG — neither carries sell-side coverage), so the
/// service is built to degrade that `null` cleanly to "no coverage" (`nil`), **not** an error. The
/// fields below mirror the *typical* analyst-rating block (price-target high/low/mean, the
/// buy/hold/sell tally, analyst count, implied upside) but are **hypotheses**: their `CodingKeys` are
/// not finalized. Confirm them against a re-capture from a covered large-cap (BBCA / BBRI / TLKM /
/// ASII — see CAPTURED-ENDPOINTS-SPEC.md §6) before relying on any field. Every field is optional so a
/// partial or differently-shaped payload still decodes to a non-`nil` "coverage exists" value.
nonisolated struct AnalystCoverage: Sendable, Equatable {
    let targetHigh: Double?
    let targetLow: Double?
    let targetMean: Double?
    let buyCount: Int?
    let holdCount: Int?
    let sellCount: Int?
    let analystCount: Int?
    let upsidePct: Double?
}

/// One row of the analyst-consensus history from `analyst-ratings/{SYM}/consensus`.
///
/// ⚠️ **Skeleton — element shape UNVERIFIED.** The captured `data` was `[]` (no coverage), so the
/// element fields are hypotheses pending a covered-large-cap re-capture (§6). All optional.
nonisolated struct AnalystConsensusRow: Sendable, Equatable {
    let date: String?
    let rating: String?
    let targetPrice: Double?
    let analyst: String?
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
    /// The symbol's analyst-consensus history, or `[]` when there is no coverage (`data: []`/`null`).
    func consensus(symbol: String) async throws -> [AnalystConsensusRow]
}

/// Reads Stockbit's analyst coverage (`GET analyst-ratings/{SYM}` and `…/consensus`).
///
/// ⚠️ **Skeleton service.** Both endpoints returned empty payloads (`null` / `[]`) for every symbol
/// in the source capture, so this wires the request shape + envelope handling + error mapping only:
/// an empty payload is the legitimate "no coverage" answer (`nil` / `[]`), never a thrown error. The
/// populated DTOs are finalized after a covered-large-cap re-capture (§3.4 / §6). Error mapping
/// mirrors `KeystatsRatioService` / `SeasonalityService` (`401`→`.unauthorized`, `402|403`→`.paywall`).
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

    func consensus(symbol: String) async throws -> [AnalystConsensusRow] {
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

    /// Decodes the envelope; `data: null` ⇒ `nil` ("no coverage"). A present object maps through the
    /// (unverified) DTO — fields that don't match the eventual real keys simply stay `nil`.
    static func parseCoverage(_ data: Data) throws -> AnalystCoverage? {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<CoverageDTO>.self, from: data)
        return envelope.data.map { dto in
            AnalystCoverage(
                targetHigh: dto.targetHigh,
                targetLow: dto.targetLow,
                targetMean: dto.targetMean,
                buyCount: dto.buyCount,
                holdCount: dto.holdCount,
                sellCount: dto.sellCount,
                analystCount: dto.analystCount,
                upsidePct: dto.upsidePct)
        }
    }

    /// Decodes the envelope; `data: []` or `null` ⇒ `[]` ("no coverage").
    static func parseConsensus(_ data: Data) throws -> [AnalystConsensusRow] {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<[ConsensusRowDTO]>.self, from: data)
        return (envelope.data ?? []).map { dto in
            AnalystConsensusRow(date: dto.date, rating: dto.rating,
                                targetPrice: dto.targetPrice, analyst: dto.analyst)
        }
    }
}

// MARK: - DTO (Stockbit `GET /analyst-ratings/{SYM}` — UNVERIFIED, see §6)

/// ⚠️ **Hypothesis.** Captured `data` was `null`, so these keys are best-guess and not finalized.
/// All optional, so wrong guesses degrade to `nil` rather than failing the decode. Re-capture a
/// covered large-cap (§6) before trusting any of these.
private struct CoverageDTO: Decodable {
    let targetHigh: Double?
    let targetLow: Double?
    let targetMean: Double?
    let buyCount: Int?
    let holdCount: Int?
    let sellCount: Int?
    let analystCount: Int?
    let upsidePct: Double?
    enum CodingKeys: String, CodingKey {
        case targetHigh = "target_high"
        case targetLow = "target_low"
        case targetMean = "target_mean"
        case buyCount = "buy"
        case holdCount = "hold"
        case sellCount = "sell"
        case analystCount = "total_analyst"
        case upsidePct = "upside"
    }
}

/// ⚠️ **Hypothesis.** Captured `data` was `[]`; element keys are best-guess (§6). All optional.
private struct ConsensusRowDTO: Decodable {
    let date: String?
    let rating: String?
    let targetPrice: Double?
    let analyst: String?
    enum CodingKeys: String, CodingKey {
        case date
        case rating
        case targetPrice = "target_price"
        case analyst
    }
}
