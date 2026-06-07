import Foundation

// Reads Stockbit's dated daily price/flow summary for one symbol:
//   GET company-price-feed/historical/summary/{SYMBOL}
//       ?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&limit=N&page=P&period=HS_PERIOD_DAILY
//
// Wire shape verified against a live WIFI capture (2026-06-06): the envelope is
// { message, data: { paginate: { next_page }, result: [row…] } } and every row field is a
// JSON NUMBER (not a display string), so no DisplayNumber parsing is needed. Rows arrive
// NEWEST-FIRST; pagination walks `next_page`. This is the §11-settled source for the engine's
// OHLCV bars — it carries the true traded-rupiah `value` (ADV) and per-day `net_foreign`,
// which the chart endpoint does not.

nonisolated enum HistoricalSummaryPeriod: String, Sendable {
    case daily = "HS_PERIOD_DAILY"
    case weekly = "HS_PERIOD_WEEKLY"
    case monthly = "HS_PERIOD_MONTHLY"
}

/// One dated bar from the historical-summary feed. Currency-typed fields are `Decimal`.
nonisolated struct HistoricalSummaryBar: Sendable, Equatable {
    let date: Date
    let open, high, low, close: Decimal
    let volume: Decimal
    let value: Decimal          // traded value in rupiah (true ADV input)
    let netForeign: Decimal     // net foreign flow for the day (foreign_buy − foreign_sell)
}

/// One page of the feed, as returned (newest-first). `nextPage` is nil on the last page.
nonisolated struct HistoricalSummaryPage: Sendable, Equatable {
    let bars: [HistoricalSummaryBar]
    let nextPage: Int?
}

nonisolated enum CompanyPriceFeedError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol CompanyPriceFeedServicing: Sendable {
    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod,
                           startDate: Date, endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage
}

extension CompanyPriceFeedServicing {
    /// Pages through DAILY history in [from, to], returning bars sorted ascending (oldest→newest)
    /// as the engine expects. `maxPages` is a safety cap. NOTE: Phase 1.8 (§7) will add a shared
    /// throttle + per-symbol cache for universe-scale runs; this convenience paginates one symbol.
    func dailyBars(symbol: String, from: Date, to: Date,
                   pageLimit: Int = 1000, maxPages: Int = 10) async throws -> [HistoricalSummaryBar] {
        var all: [HistoricalSummaryBar] = []
        var page = 1
        while page <= maxPages {
            let p = try await historicalSummary(symbol: symbol, period: .daily,
                                                startDate: from, endDate: to, limit: pageLimit, page: page)
            all.append(contentsOf: p.bars)
            guard let next = p.nextPage else { break }
            page = next
        }
        return all.sorted { $0.date < $1.date }
    }
}

nonisolated final class CompanyPriceFeedService: CompanyPriceFeedServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func historicalSummary(symbol: String, period: HistoricalSummaryPeriod,
                           startDate: Date, endDate: Date, limit: Int, page: Int) async throws -> HistoricalSummaryPage {
        let endpoint = Self.makeEndpoint(symbol: symbol, period: period,
                                         startDate: Self.day(startDate), endDate: Self.day(endDate),
                                         limit: limit, page: page)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw CompanyPriceFeedError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw CompanyPriceFeedError.paywall
        } catch let err as APIError {
            throw CompanyPriceFeedError.network(String(describing: err))
        }
        do {
            return try Self.parse(data)
        } catch {
            throw CompanyPriceFeedError.malformedResponse
        }
    }

    // MARK: - Wire format

    static func makeEndpoint(symbol: String, period: HistoricalSummaryPeriod,
                             startDate: String, endDate: String, limit: Int, page: Int) -> Endpoint {
        Endpoint(
            method: .get,
            path: "company-price-feed/historical/summary/\(symbol)",
            query: [
                URLQueryItem(name: "start_date", value: startDate),
                URLQueryItem(name: "end_date", value: endDate),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "period", value: period.rawValue),
            ])
    }

    static func parse(_ data: Data) throws -> HistoricalSummaryPage {
        let dto = try JSONDecoder().decode(HistoricalSummaryResponseDTO.self, from: data)
        let bars = try dto.data.result.map { try $0.toDomain() }
        let next = dto.data.paginate?.next_page.flatMap { Int($0) }
        return HistoricalSummaryPage(bars: bars, nextPage: next)
    }

    static func day(_ d: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Parses a "yyyy-MM-dd" day to UTC midnight without a (non-Sendable) DateFormatter.
    static func parseDay(_ s: String) -> Date? {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return DateComponents(calendar: utcCalendar, year: y, month: m, day: d).date
    }

    nonisolated private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

// MARK: - DTOs (every numeric field is a JSON number → decoded straight to Decimal, exactly)

private nonisolated struct HistoricalSummaryResponseDTO: Decodable {
    let message: String?
    let data: DataDTO

    nonisolated struct DataDTO: Decodable {
        let paginate: Paginate?
        let result: [RowDTO]
    }
    nonisolated struct Paginate: Decodable { let next_page: String? }

    nonisolated struct RowDTO: Decodable {
        let date: String
        let open, high, low, close: Decimal
        let volume: Decimal
        let value: Decimal
        let net_foreign: Decimal

        func toDomain() throws -> HistoricalSummaryBar {
            guard let d = CompanyPriceFeedService.parseDay(date) else {
                throw HistoricalSummaryDecodeError.malformedRow
            }
            return HistoricalSummaryBar(
                date: d, open: open, high: high, low: low, close: close,
                volume: volume, value: value, netForeign: net_foreign)
        }
    }
}

private enum HistoricalSummaryDecodeError: Error { case malformedRow }
