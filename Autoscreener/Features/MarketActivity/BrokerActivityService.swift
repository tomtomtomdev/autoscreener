import Foundation

// Reads Stockbit's daily broker-activity history for one symbol:
//   GET order-trade/broker/activity/historical
//       ?symbols={SYM}&interval=INTERVAL_DAILY&transaction_type=TRANSACTION_TYPE_NET
//        &investor_type=INVESTOR_TYPE_ALL&market_board=BOARD_TYPE_REGULAR
//        &period={RT_PERIOD…}&pagination.limit=N&pagination.page=P[&broker_codes=CSV]
//
// Wire shape verified against a live WIFI capture (2026-06-06): the envelope is
// { message, data: { records: [ { date, trade_activity: { net_summary{value}, buy_summary{value},
// sell_summary{value}, … }, … } … ] } }, rows arrive NEWEST-FIRST, and every value is a JSON NUMBER
// (decoded straight to `Decimal`, exact — like CompanyPriceFeedService / FundachartService). This is
// the §11-settled source for the engine's `brokerAccumulationSignal`; the SelectionFundamentals
// adapter turns the daily net series into a single [-1,1] scalar.
//
// Distinct from `BrokerSummaryService` (the `/marketdetectors` "Bandar Detector" ranked snapshot):
// this endpoint is the dated daily NET series we need to compute a signal over a window.
//
// CAVEAT (honest scope): with no `broker_codes` the server returns the *default broker's* net — a true
// all-broker net is identically zero (every buy is someone's sell), so a per-broker series is the only
// meaningful unit. `brokerCodes` is exposed so a curated "smart-money" broker group can be tracked
// later (§6); the signal math is unchanged either way.

nonisolated enum BrokerActivityPeriod: String, Sendable {
    case lastMonth = "RT_PERIOD_LAST_1_MONTH"   // not capture-verified (RT_PERIOD family is standard)
    case lastYear = "RT_PERIOD_LAST_1_YEAR"      // capture-verified (WIFI, 2026-06-06)
}

/// One dated broker-activity row. Currency fields are `Decimal` (JSON numbers, exact). `netValue` is
/// the broker(s)' net traded rupiah for the day (buy − sell); `buyValue`/`sellValue` are the gross
/// legs. Kept free of any engine type (uses `Decimal`, not the `Rupiah` typealias) so this service
/// stays independent of the Selection feature — SelectionFundamentals does the engine-facing adapting.
nonisolated struct BrokerActivityRecord: Sendable, Equatable {
    let date: Date
    let netValue: Decimal
    let buyValue: Decimal
    let sellValue: Decimal
}

nonisolated enum BrokerActivityError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol BrokerActivityServicing: Sendable {
    func dailyActivity(symbol: String, period: BrokerActivityPeriod, brokerCodes: [String],
                       limit: Int, page: Int) async throws -> [BrokerActivityRecord]
}

extension BrokerActivityServicing {
    /// The recent daily net series (newest-first) for `symbol`, all-brokers default view. Phase 1.8
    /// (§7) will add the shared throttle / per-symbol cache; this convenience fetches one page.
    func dailyActivity(symbol: String, period: BrokerActivityPeriod = .lastYear,
                       limit: Int = 100) async throws -> [BrokerActivityRecord] {
        try await dailyActivity(symbol: symbol, period: period, brokerCodes: [], limit: limit, page: 1)
    }
}

nonisolated final class BrokerActivityService: BrokerActivityServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func dailyActivity(symbol: String, period: BrokerActivityPeriod, brokerCodes: [String],
                       limit: Int, page: Int) async throws -> [BrokerActivityRecord] {
        let endpoint = Self.makeEndpoint(symbol: symbol, period: period, brokerCodes: brokerCodes,
                                         limit: limit, page: page)
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw BrokerActivityError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw BrokerActivityError.paywall
        } catch let err as APIError {
            throw BrokerActivityError.network(String(describing: err))
        }
        do {
            return try Self.parse(data)
        } catch {
            throw BrokerActivityError.malformedResponse
        }
    }

    // MARK: - Wire format

    static func makeEndpoint(symbol: String, period: BrokerActivityPeriod, brokerCodes: [String],
                             limit: Int, page: Int) -> Endpoint {
        var query = [
            URLQueryItem(name: "symbols", value: symbol),
            URLQueryItem(name: "interval", value: "INTERVAL_DAILY"),
            URLQueryItem(name: "investor_type", value: "INVESTOR_TYPE_ALL"),
            URLQueryItem(name: "market_board", value: "BOARD_TYPE_REGULAR"),
            URLQueryItem(name: "transaction_type", value: "TRANSACTION_TYPE_NET"),
            URLQueryItem(name: "period", value: period.rawValue),
            URLQueryItem(name: "pagination.limit", value: String(limit)),
            URLQueryItem(name: "pagination.page", value: String(page)),
        ]
        if !brokerCodes.isEmpty {
            query.append(URLQueryItem(name: "broker_codes", value: brokerCodes.joined(separator: ",")))
        }
        return Endpoint(method: .get, path: "order-trade/broker/activity/historical", query: query)
    }

    static func parse(_ data: Data) throws -> [BrokerActivityRecord] {
        let dto = try JSONDecoder().decode(ResponseDTO.self, from: data)
        return try dto.data.records.map { try $0.toDomain() }
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

// MARK: - DTOs (every value is a JSON number → decoded straight to Decimal, exactly)

private nonisolated struct ResponseDTO: Decodable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable { let records: [RecordDTO] }

    nonisolated struct RecordDTO: Decodable {
        let date: String
        let trade_activity: TradeActivityDTO

        func toDomain() throws -> BrokerActivityRecord {
            guard let d = BrokerActivityService.parseDay(date) else {
                throw BrokerActivityDecodeError.malformedRow
            }
            return BrokerActivityRecord(
                date: d,
                netValue: trade_activity.net_summary.value,
                buyValue: trade_activity.buy_summary.value,
                sellValue: trade_activity.sell_summary.value)
        }
    }
    nonisolated struct TradeActivityDTO: Decodable {
        let net_summary: SummaryDTO
        let buy_summary: SummaryDTO
        let sell_summary: SummaryDTO
    }
    nonisolated struct SummaryDTO: Decodable { let value: Decimal }
}

private enum BrokerActivityDecodeError: Error { case malformedRow }
