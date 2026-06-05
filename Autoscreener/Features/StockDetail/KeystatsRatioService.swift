import Foundation

// MARK: - Domain

/// A point-in-time snapshot of the per-stock ratios Stockbit's keystats endpoint
/// groups as Valuation / Per-share / Solvency (`idx-regime-data-research.md` §2).
/// Every field is optional on purpose: a loss-maker has no meaningful P/E, a
/// negative-equity name no P/B — absence is information, not zero.
nonisolated struct ValuationRatios: Sendable, Equatable {
    let symbol: String

    // Valuation
    let pe: Double?            // annualised
    let peTTM: Double?
    let priceToSales: Double?
    let priceToBook: Double?
    let priceToCashFlow: Double?
    let priceToFreeCashFlow: Double?
    let evToEBITDA: Double?

    // Per-share
    let eps: Double?
    let bookValuePerShare: Double?
    let cashPerShare: Double?
    let freeCashFlowPerShare: Double?

    // Solvency
    let currentRatio: Double?
    let quickRatio: Double?
    let debtToEquity: Double?
}

extension ValuationRatios {
    /// √(22.5 · EPS · BVPS) — see `GrahamNumber`. `nil` when the inputs don't qualify.
    var grahamNumber: Double? {
        GrahamNumber.value(eps: eps, bookValuePerShare: bookValuePerShare)
    }

    /// Margin of safety of `price` against the Graham Number (positive = discount).
    func marginOfSafety(atPrice price: Double) -> Double? {
        GrahamNumber.marginOfSafety(price: price, eps: eps, bookValuePerShare: bookValuePerShare)
    }
}

/// Graham's defensive fair-value ceiling: √(22.5 · EPS · BVPS), where
/// 22.5 = 15 (max defensible P/E) × 1.5 (max defensible P/B). A stock trading
/// below its Graham Number clears Graham's price test for a defensive investor.
nonisolated enum GrahamNumber {
    /// Returns `nil` when EPS or BVPS is missing or non-positive: a loss-maker or
    /// a negative-equity company has no Graham Number (the formula degenerates),
    /// so it fails to qualify rather than producing a misleading figure.
    static func value(eps: Double?, bookValuePerShare: Double?) -> Double? {
        guard let eps, let bvps = bookValuePerShare, eps > 0, bvps > 0 else { return nil }
        return (22.5 * eps * bvps).squareRoot()
    }

    /// Fraction below the Graham Number paid at `price`: positive = discount /
    /// margin of safety, negative = premium. `nil` when there is no Graham Number.
    static func marginOfSafety(price: Double, eps: Double?, bookValuePerShare: Double?) -> Double? {
        guard let number = value(eps: eps, bookValuePerShare: bookValuePerShare), number > 0 else { return nil }
        return (number - price) / number
    }
}

// MARK: - Service

nonisolated enum KeystatsRatioError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol KeystatsRatioServicing: Sendable {
    /// Latest grouped valuation ratios for `symbol`. `yearLimit` requests up to
    /// N years of history from the endpoint (default 10, per the research doc).
    func ratios(symbol: String, yearLimit: Int) async throws -> ValuationRatios
}

extension KeystatsRatioServicing {
    func ratios(symbol: String) async throws -> ValuationRatios {
        try await ratios(symbol: symbol, yearLimit: 10)
    }
}

/// Reads Stockbit's per-stock keystats ratios
/// (`GET keystats/ratio/v1/{symbol}?year_limit=N`): the Graham inputs (EPS, BVPS)
/// alongside the valuation and solvency ratios.
nonisolated final class KeystatsRatioService: KeystatsRatioServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func ratios(symbol: String, yearLimit: Int) async throws -> ValuationRatios {
        let endpoint = Self.makeEndpoint(symbol: symbol, yearLimit: yearLimit)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw KeystatsRatioError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw KeystatsRatioError.paywall
        } catch let err as APIError {
            throw KeystatsRatioError.network(String(describing: err))
        }
        do {
            return try Self.parse(data, symbol: symbol)
        } catch {
            throw KeystatsRatioError.malformedResponse
        }
    }

    /// Builds `GET keystats/ratio/v1/{symbol}` with the `year_limit` history window.
    static func makeEndpoint(symbol: String, yearLimit: Int = 10) -> Endpoint {
        Endpoint(
            method: .get,
            path: "keystats/ratio/v1/\(symbol)",
            query: [URLQueryItem(name: "year_limit", value: String(yearLimit))]
        )
    }

    /// Decodes the grouped keystats payload, flattens every item into an
    /// `id → value` map, and pulls the fields we model by their stable numeric id
    /// (`Field`). Ids are language-independent; the human `name` is not. Mapped to
    /// `ValuationRatios` via `parseDisplayDecimal` (values arrive as strings).
    static func parse(_ data: Data, symbol: String) throws -> ValuationRatios {
        let dto = try JSONDecoder().decode(KeystatsResponseDTO.self, from: data)
        var byID: [String: String] = [:]
        for group in dto.data.groups {
            for item in group.items { byID[item.fitem.id] = item.fitem.value }
        }
        func num(_ id: String) -> Double? { byID[id].flatMap(parseDisplayDecimal) }

        return ValuationRatios(
            symbol: symbol,
            pe: num(Field.peAnnualised),
            peTTM: num(Field.peTTM),
            priceToSales: num(Field.priceToSales),
            priceToBook: num(Field.priceToBook),
            priceToCashFlow: num(Field.priceToCashFlow),
            priceToFreeCashFlow: num(Field.priceToFreeCashFlow),
            evToEBITDA: num(Field.evToEBITDA),
            eps: num(Field.epsTTM),
            bookValuePerShare: num(Field.bookValuePerShare),
            cashPerShare: num(Field.cashPerShare),
            freeCashFlowPerShare: num(Field.freeCashFlowPerShare),
            currentRatio: num(Field.currentRatio),
            quickRatio: num(Field.quickRatio),
            debtToEquity: num(Field.debtToEquity)
        )
    }

    /// Parses Stockbit's display strings into a number:
    /// `"1,688.51"` → 1688.51, `"-22.24"` → −22.24, `"(5,349)"` → −5349,
    /// `"31.87%"` → 31.87, and `"-"` / `""` → nil (field not applicable).
    static func parseDisplayDecimal(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "-" else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: ",", with: "")
        if s.hasSuffix("%") { s = String(s.dropLast()) }
        guard let value = Double(s) else { return nil }
        return negative ? -value : value
    }

    /// Stable keystats item ids (`fitem.id`) for the fields we model.
    /// `eps` uses the TTM figure (the headline "Current EPS"); the annualised
    /// variant (id 12988) is also present should a more conservative calc be wanted.
    private enum Field {
        static let peAnnualised = "12148"
        static let peTTM = "2891"
        static let priceToSales = "2893"
        static let priceToBook = "2896"
        static let priceToCashFlow = "16533"
        static let priceToFreeCashFlow = "15881"
        static let evToEBITDA = "21457"
        static let epsTTM = "13200"
        static let bookValuePerShare = "15718"
        static let cashPerShare = "15879"
        static let freeCashFlowPerShare = "15882"
        static let currentRatio = "1498"
        static let quickRatio = "1500"
        static let debtToEquity = "1508"
    }
}

// MARK: - DTO (Stockbit `GET /keystats/ratio/v1/{symbol}`)

/// `data.closure_fin_items_results[]` groups (Valuation / Per Share / Solvency / …),
/// each a list of `{ fitem: { id, name, value } }`. Values are display strings.
private struct KeystatsResponseDTO: Decodable {
    let data: DataDTO

    struct DataDTO: Decodable {
        let groups: [GroupDTO]
        enum CodingKeys: String, CodingKey { case groups = "closure_fin_items_results" }
    }

    struct GroupDTO: Decodable {
        let items: [ItemDTO]
        enum CodingKeys: String, CodingKey { case items = "fin_name_results" }
    }

    struct ItemDTO: Decodable {
        let fitem: FItemDTO
    }

    struct FItemDTO: Decodable {
        let id: String
        let value: String
    }
}
