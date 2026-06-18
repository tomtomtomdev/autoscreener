import Foundation

// MARK: - Domain

/// A stock's monthly seasonality table from Stockbit's `seasonality/{SYM}` endpoint: for each
/// calendar month, how often (over the captured history) the name closed up vs. down, the average
/// monthly return, and the historical probability of an up month. Stockbit also returns a `"Year"`
/// aggregate row, kept here as a 13th `SeasonalMonth` so callers can read the annual figures.
///
/// This is a **thin, survivorship-prone timing signal**: useful as a soft tilt (the current
/// calendar month's `probabilityUpPct` / `avgReturnPct`) and as a StockDetail UI table, but never a
/// hard gate. The per-year `price_change` grid and the UI-only hex `color`s are intentionally dropped.
nonisolated struct Seasonality: Sendable, Equatable, Codable {
    let symbol: String
    /// Jan … Dec in calendar order, followed by the `"Year"` aggregate.
    let months: [SeasonalMonth]

    /// The row for a given column name (`"Jan"` … `"Dec"`, or `"Year"`), if present.
    func month(_ name: String) -> SeasonalMonth? {
        months.first { $0.name == name }
    }
}

/// One column of the seasonality table — a calendar month, or the `"Year"` aggregate.
nonisolated struct SeasonalMonth: Sendable, Equatable, Codable {
    let name: String                  // "Jan" … "Dec", or "Year"
    let upCount: Int                  // years this month closed up
    let downCount: Int                // years this month closed down
    let totalYears: Int               // years of history for this month (recent months may trail by one)
    let avgReturnPct: Double          // average monthly % return
    let probabilityUpPct: Double      // historical P(up) %, 0–100
}

// MARK: - Service

nonisolated enum SeasonalityError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol SeasonalityServicing: Sendable {
    /// The monthly seasonality table for `symbol`, anchored on `year` with `backYear` years of
    /// look-back (Stockbit's default is the full captured history, `back_year=0`).
    func seasonality(symbol: String, year: Int, backYear: Int) async throws -> Seasonality
}

extension SeasonalityServicing {
    /// Full captured history (`back_year=0`), the app's only call shape.
    func seasonality(symbol: String, year: Int) async throws -> Seasonality {
        try await seasonality(symbol: symbol, year: year, backYear: 0)
    }
}

/// Reads Stockbit's monthly seasonality (`GET seasonality/{SYM}?year={Y}&back_year={B}`) and zips its
/// five parallel display-string columns (`up`, `down`, `total_months`, `avg`, `prob`) into one row
/// per month. Error mapping mirrors `KeystatsRatioService` (`401`→`.unauthorized`, `402|403`→`.paywall`).
nonisolated final class SeasonalityService: SeasonalityServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func seasonality(symbol: String, year: Int, backYear: Int) async throws -> Seasonality {
        let data = try await rawData(symbol: symbol, year: year, backYear: backYear)
        do {
            return try Self.parse(data, symbol: symbol)
        } catch {
            throw SeasonalityError.malformedResponse
        }
    }

    /// Fetch + `APIError` → domain-error mapping, mirroring `ComparisonRatiosService`.
    private func rawData(symbol: String, year: Int, backYear: Int) async throws -> Data {
        do {
            return try await apiClient.sendRaw(Self.makeEndpoint(symbol: symbol, year: year, backYear: backYear))
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw SeasonalityError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw SeasonalityError.paywall
        } catch let err as APIError {
            throw SeasonalityError.network(String(describing: err))
        }
    }

    /// Builds `GET seasonality/{SYM}?year={Y}&back_year={B}`.
    static func makeEndpoint(symbol: String, year: Int, backYear: Int) -> Endpoint {
        Endpoint(
            method: .get,
            path: "seasonality/\(symbol)",
            query: [
                URLQueryItem(name: "year", value: String(year)),
                URLQueryItem(name: "back_year", value: String(backYear)),
            ]
        )
    }

    /// Decodes the envelope and zips the five parallel columns by month name (using `up` as the
    /// canonical ordered spine), parsing counts as `Int` and `avg`/`prob` via `DisplayNumber.parseDecimal`
    /// (which already handles negatives like `"-3.00"`). Throws when `data` is absent.
    static func parse(_ data: Data, symbol: String) throws -> Seasonality {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<SeasonalityDTO>.self, from: data)
        guard let dto = envelope.data else { throw SeasonalityError.malformedResponse }

        func indexed(_ column: SeasonalityDTO.Column?) -> [String: String] {
            Dictionary(column?.columns.map { ($0.name, $0.value) } ?? [], uniquingKeysWith: { first, _ in first })
        }
        let down = indexed(dto.down)
        let total = indexed(dto.totalMonths)
        let avg = indexed(dto.avg)
        let prob = indexed(dto.prob)

        let months = (dto.up?.columns ?? []).map { cell -> SeasonalMonth in
            SeasonalMonth(
                name: cell.name,
                upCount: Int(cell.value) ?? 0,
                downCount: down[cell.name].flatMap { Int($0) } ?? 0,
                totalYears: total[cell.name].flatMap { Int($0) } ?? 0,
                avgReturnPct: avg[cell.name].flatMap(DisplayNumber.parseDecimal) ?? 0,
                probabilityUpPct: prob[cell.name].flatMap(DisplayNumber.parseDecimal) ?? 0)
        }
        return Seasonality(symbol: symbol, months: months)
    }
}

// MARK: - DTO (Stockbit `GET /seasonality/{SYM}`)

/// `data` carries five parallel columns — `up`, `down`, `total_months`, `avg`, `prob` — each
/// `{ columns: [{ name, value: String, color }] }` with one entry per month (Jan … Dec) plus a
/// `"Year"` aggregate. `price_change` (per-year grid), `default_last_year`, and the UI-only hex
/// `color`s are intentionally undeclared, so they're skipped.
private struct SeasonalityDTO: Decodable {
    let up: Column?
    let down: Column?
    let totalMonths: Column?
    let avg: Column?
    let prob: Column?
    enum CodingKeys: String, CodingKey {
        case up, down, avg, prob
        case totalMonths = "total_months"
    }

    struct Column: Decodable {
        let columns: [Cell]
    }

    struct Cell: Decodable {
        let name: String
        let value: String
    }
}
