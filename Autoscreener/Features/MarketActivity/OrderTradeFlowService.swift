import Foundation

// Reads Stockbit's `order-trade/*` flow family — the "who's accumulating" / "what's the market
// buying" feeds that sit alongside the dated net series in `BrokerActivityService`:
//
//   • distribution(symbol:) → GET order-trade/broker/distribution  (per-ticker bandar concentration)
//   • topStocks(valueType:) → GET order-trade/top-stock            (market-wide net buy/sell leaders)
//
// Both share one envelope, one error mapping (mirrors KeystatsRatioService: 401→.unauthorized,
// 402|403→.paywall), and the order-trade convention that numbers arrive either as a JSON Int
// (broker/distribution `amount`) or as a `{raw,formatted}` StockbitValue with a numeric-String
// `raw` (top-stock). Wire shapes verified against the 2026-06-11 capture.

// MARK: - Domain

/// Per-ticker broker distribution for one day: which brokers bought / sold the most by rupiah value.
/// Stockbit returns each side already sorted descending by value. `amount` is rupiah (a JSON Int on
/// the wire). The per-broker `distribute_to` counterparty fan-out is dropped — only the `detail` leg
/// (the broker's own total) feeds a concentration read.
nonisolated struct BrokerDistribution: Sendable, Equatable {
    let symbol: String
    let date: String                 // "yyyy-MM-dd" (date_info)
    let topBuyers: [DistributionLeg]        // descending by value
    let topSellers: [DistributionLeg]

    var totalBuyValue: Double { topBuyers.reduce(0) { $0 + $1.amount } }
    var totalSellValue: Double { topSellers.reduce(0) { $0 + $1.amount } }

    /// Share of total buy value captured by the top `n` buying brokers — high ⇒ accumulation
    /// concentrated in few hands (a bandar signal). `nil` when there is no buy-side data.
    func buyConcentration(topN n: Int = 3) -> Double? {
        guard totalBuyValue > 0 else { return nil }
        let top = topBuyers.prefix(max(0, n)).reduce(0) { $0 + $1.amount }
        return top / totalBuyValue
    }
}

/// One broker's leg of a distribution: `code` (e.g. "XL"), `type` ("Lokal" / "Asing" /
/// "Pemerintah"), and the rupiah `amount`.
nonisolated struct DistributionLeg: Sendable, Equatable {
    let code: String
    let type: String
    let amount: Double
}

/// Market-wide accumulation leaderboard: the names with the largest net (or gross / total) buy and
/// sell value over the latest session. `topSell` rows carry a negative `value.raw`.
nonisolated struct FlowLeaderboard: Sendable, Equatable {
    let topBuy: [FlowRow]
    let topSell: [FlowRow]
}

/// One ranked row of the flow leaderboard. `value` is the signed traded rupiah; `foreignValue` is the
/// net foreign leg (negative ⇒ foreign outflow); `lot` is the signed traded lots. Each is a
/// `StockbitValue` so the display string is preserved alongside the parsed `raw`.
nonisolated struct FlowRow: Sendable, Equatable {
    let rank: Int
    let code: String
    let value: StockbitValue
    let foreignValue: StockbitValue
    let lot: StockbitValue
}

/// Which dimension `top-stock` ranks by.
nonisolated enum TopStockValueType: String, Sendable {
    case net = "VALUE_TYPE_NET"
    case gross = "VALUE_TYPE_GROSS"
    case total = "VALUE_TYPE_TOTAL"
}

// MARK: - Service

nonisolated enum OrderTradeFlowError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}

nonisolated protocol OrderTradeFlowServicing: Sendable {
    /// The top buying / selling brokers for `symbol` over the last trading day, by value.
    func distribution(symbol: String) async throws -> BrokerDistribution

    /// The market-wide buy/sell leaderboard for the latest session, ranked by `valueType`.
    func topStocks(valueType: TopStockValueType, page: Int) async throws -> FlowLeaderboard
}

extension OrderTradeFlowServicing {
    /// First page of the leaderboard.
    func topStocks(valueType: TopStockValueType) async throws -> FlowLeaderboard {
        try await topStocks(valueType: valueType, page: 1)
    }
}

nonisolated final class OrderTradeFlowService: OrderTradeFlowServicing {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    func distribution(symbol: String) async throws -> BrokerDistribution {
        try await fetch(Self.distributionEndpoint(symbol: symbol)) {
            try Self.parseDistribution($0, symbol: symbol)
        }
    }

    func topStocks(valueType: TopStockValueType, page: Int) async throws -> FlowLeaderboard {
        try await fetch(Self.topStockEndpoint(valueType: valueType, page: page), Self.parseTopStocks)
    }

    /// Fetch the endpoint, map transport/HTTP failures to `OrderTradeFlowError` (mirroring
    /// `KeystatsRatioService` / `BrokerActivityService`), and surface any decode failure as
    /// `.malformedResponse`.
    private func fetch<T>(_ endpoint: Endpoint, _ parse: (Data) throws -> T) async throws -> T {
        let data: Data
        do {
            data = try await apiClient.sendRaw(endpoint)
        } catch APIError.unauthorized, APIError.notSignedIn {
            throw OrderTradeFlowError.unauthorized
        } catch APIError.http(let status, _) where status == 402 || status == 403 {
            throw OrderTradeFlowError.paywall
        } catch let err as APIError {
            throw OrderTradeFlowError.network(String(describing: err))
        }
        do {
            return try parse(data)
        } catch {
            throw OrderTradeFlowError.malformedResponse
        }
    }

    // MARK: distribution wire format

    static func distributionEndpoint(symbol: String) -> Endpoint {
        Endpoint(method: .get, path: "order-trade/broker/distribution", query: [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "data_type", value: "BROKER_DISTRIBUTION_DATA_TYPE_VALUE"),
            URLQueryItem(name: "investor_type", value: "INVESTOR_TYPE_ALL"),
            URLQueryItem(name: "market_board", value: "MARKET_TYPE_REGULER"),
            URLQueryItem(name: "period", value: "TB_PERIOD_LAST_1_DAY"),
        ])
    }

    static func parseDistribution(_ data: Data, symbol: String) throws -> BrokerDistribution {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<DistributionDTO>.self, from: data)
        guard let dto = envelope.data else { throw OrderTradeFlowError.malformedResponse }
        func legs(_ entries: [DistributionDTO.EntryDTO]) -> [DistributionLeg] {
            entries.map { DistributionLeg(code: $0.detail.code, type: $0.detail.type, amount: $0.detail.amount) }
        }
        return BrokerDistribution(
            symbol: symbol,
            date: dto.dateInfo,
            topBuyers: legs(dto.byValue.topBrokerBuy),
            topSellers: legs(dto.byValue.topBrokerSell))
    }

    // MARK: top-stock wire format

    static func topStockEndpoint(valueType: TopStockValueType, page: Int) -> Endpoint {
        Endpoint(method: .get, path: "order-trade/top-stock", query: [
            URLQueryItem(name: "value_type", value: valueType.rawValue),
            URLQueryItem(name: "market_type", value: "MARKET_TYPE_REGULER"),
            URLQueryItem(name: "investor_type", value: "INVESTOR_TYPE_ALL"),
            URLQueryItem(name: "period", value: "TOP_STOCK_PERIOD_LATEST"),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    static func parseTopStocks(_ data: Data) throws -> FlowLeaderboard {
        let envelope = try JSONDecoder().decode(StockbitEnvelope<TopStockDTO>.self, from: data)
        guard let dto = envelope.data else { throw OrderTradeFlowError.malformedResponse }
        func rows(_ rows: [TopStockDTO.RowDTO]) -> [FlowRow] {
            rows.map { FlowRow(rank: $0.rank, code: $0.code, value: $0.value,
                               foreignValue: $0.foreignValue, lot: $0.lot) }
        }
        return FlowLeaderboard(topBuy: rows(dto.topBuy), topSell: rows(dto.topSell))
    }
}

// MARK: - DTO (Stockbit `GET /order-trade/broker/distribution`)

/// `data.by_value.{top_broker_buy,top_broker_sell}[]` → `{ detail{code,type,amount:Int},
/// distribute_to:[…] }`. `by_volume` mirrors the shape but is empty for the `…_VALUE` data_type;
/// `distribute_to` (the per-broker counterparty fan-out) is intentionally undeclared, so it's skipped.
private struct DistributionDTO: Decodable {
    let dateInfo: String
    let byValue: ByValueDTO
    enum CodingKeys: String, CodingKey { case dateInfo = "date_info"; case byValue = "by_value" }

    struct ByValueDTO: Decodable {
        let topBrokerBuy: [EntryDTO]
        let topBrokerSell: [EntryDTO]
        enum CodingKeys: String, CodingKey {
            case topBrokerBuy = "top_broker_buy"
            case topBrokerSell = "top_broker_sell"
        }
    }

    struct EntryDTO: Decodable { let detail: LegDTO }

    struct LegDTO: Decodable {
        let code: String
        let type: String
        let amount: Double
    }
}

// MARK: - DTO (Stockbit `GET /order-trade/top-stock`)

/// `data.{top_buy,top_sell}[]` → `{ rank, code, value, lot, average, foreign_value, frequency }`,
/// each metric a `{raw,formatted}` StockbitValue. `total`, `response_info`, `display_option`,
/// `icon_url`, `average`, and `frequency` are intentionally undeclared — not selection inputs.
private struct TopStockDTO: Decodable {
    let topBuy: [RowDTO]
    let topSell: [RowDTO]
    enum CodingKeys: String, CodingKey { case topBuy = "top_buy"; case topSell = "top_sell" }

    struct RowDTO: Decodable {
        let rank: Int
        let code: String
        let value: StockbitValue
        let lot: StockbitValue
        let foreignValue: StockbitValue
        enum CodingKeys: String, CodingKey {
            case rank, code, value, lot
            case foreignValue = "foreign_value"
        }
    }
}
