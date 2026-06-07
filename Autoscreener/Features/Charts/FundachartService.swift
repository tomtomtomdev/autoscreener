import Foundation

// Reads Stockbit's fundamental-chart series for one symbol:
//   GET fundachart/v2/{SYMBOL}/financials?data_type={1|2|3}&report={1|2}
//
// Each `data_type` returns three legends; `report=2` is annual (x_axis = fiscal years, e.g.
// ["2025","2024",…], NEWEST-FIRST), `report=1` is quarterly (x_axis = ["Q1 2026",…]). The `y_axis`
// array carries RAW JSON numbers aligned to x_axis — no display-string parsing — so currency amounts
// decode straight to `Decimal` (exact, like CompanyPriceFeedService). The `label` strings are the
// pre-formatted display ("1.7T") and are ignored.
//
//   data_type=1 → { Net Margin, Revenue, Net Income }
//   data_type=2 → { Debt Equity Ratio, Total Assets, Total Liabilities }
//   data_type=3 → { Operating, Investing, Financing }   (cash flows)
//
// Wire shape verified against a live WIFI capture (2026-06-06). This is the §11-settled multi-year
// fundamentals source for the engine's `[AnnualFinancials]`; SelectionFundamentals joins the three
// datasets by fiscal year.

nonisolated enum FundachartReport: Int, Sendable {
    case quarterly = 1
    case annual = 2
}

/// The three financial datasets, by their `data_type` query value.
nonisolated enum FundachartDataset: Int, Sendable {
    case incomeStatement = 1   // Net Margin, Revenue, Net Income
    case balanceSheet = 2       // Debt Equity Ratio, Total Assets, Total Liabilities
    case cashFlow = 3           // Operating, Investing, Financing
}

/// One charted legend (e.g. "Revenue") and its `y_axis`, aligned positionally to the parent's `periods`.
nonisolated struct FundachartSeries: Sendable, Equatable {
    let legend: String
    let values: [Decimal]
}

/// One `data_type` response: the shared `x_axis` periods (newest-first) and its legends.
nonisolated struct FundachartFinancials: Sendable, Equatable {
    let periods: [String]
    let series: [FundachartSeries]

    /// The `y_axis` value for `legend` at `period`, or nil if either is absent. Legend match is
    /// case-insensitive; period match is exact (fiscal-year string), so callers join datasets by year.
    func value(legend: String, period: String) -> Decimal? {
        guard let s = series.first(where: { $0.legend.caseInsensitiveCompare(legend) == .orderedSame }),
              let i = periods.firstIndex(of: period), i < s.values.count
        else { return nil }
        return s.values[i]
    }
}

nonisolated enum FundachartError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol FundachartServicing: Sendable {
    func financials(symbol: String, dataset: FundachartDataset, report: FundachartReport) async throws -> FundachartFinancials
}

nonisolated final class FundachartService: FundachartServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func financials(symbol: String, dataset: FundachartDataset, report: FundachartReport) async throws -> FundachartFinancials {
        let endpoint = Self.makeEndpoint(symbol: symbol, dataset: dataset, report: report)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw FundachartError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw FundachartError.paywall
        } catch let err as APIError {
            throw FundachartError.network(String(describing: err))
        }
        do {
            return try Self.parse(data)
        } catch {
            throw FundachartError.malformedResponse
        }
    }

    // MARK: - Wire format

    static func makeEndpoint(symbol: String, dataset: FundachartDataset, report: FundachartReport) -> Endpoint {
        Endpoint(
            method: .get,
            path: "fundachart/v2/\(symbol)/financials",
            query: [
                URLQueryItem(name: "data_type", value: String(dataset.rawValue)),
                URLQueryItem(name: "report", value: String(report.rawValue)),
            ])
    }

    static func parse(_ data: Data) throws -> FundachartFinancials {
        let dto = try JSONDecoder().decode(FundachartResponseDTO.self, from: data)
        let series = dto.data.chart_data.map { FundachartSeries(legend: $0.legend, values: $0.y_axis) }
        return FundachartFinancials(periods: dto.data.x_axis, series: series)
    }
}

// MARK: - DTO (y_axis is JSON numbers → decoded straight to Decimal, exactly)

private nonisolated struct FundachartResponseDTO: Decodable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable {
        let x_axis: [String]
        let chart_data: [SeriesDTO]
    }
    nonisolated struct SeriesDTO: Decodable {
        let legend: String
        let y_axis: [Decimal]
    }
}
