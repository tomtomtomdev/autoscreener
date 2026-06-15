import Foundation

// MARK: - Domain

/// Investor classification Stockbit attaches to each broker leg.
/// Mirrors the `type` field on `brokers_buy` / `brokers_sell`.
nonisolated enum InvestorCategory: String, Sendable, Equatable {
    case foreign = "Asing"
    case domestic = "Lokal"
    case government = "Pemerintah"
    case unknown = ""

    init(raw: String) { self = InvestorCategory(rawValue: raw) ?? .unknown }
}

/// One broker's net position for the period (a row in the broker-summary table).
///
/// `value` / `lot` are *net* and signed (positive on the buy side, negative on
/// the sell side); the `*Gross` variants are the unsigned traded totals.
nonisolated struct BrokerLeg: Sendable, Equatable, Identifiable {
    let brokerCode: String
    let averagePrice: Double
    let lot: Double
    let lotGross: Double
    let value: Double
    let valueGross: Double
    let frequency: Int
    let category: InvestorCategory
    let date: String

    var id: String { brokerCode }
}

/// One bucket of Stockbit's "Bandar Detector" aggregation (avg / top-N concentration).
nonisolated struct BandarBucket: Sendable, Equatable {
    /// Accumulation/distribution label, e.g. "Acc", "Dist", "Big Acc", "Big Dist".
    let accdist: String
    let amount: Double
    let percent: Double
    let volume: Double
}

/// Stockbit's "Bandar Detector" summary — who is in control and by how much.
nonisolated struct BandarDetector: Sendable, Equatable {
    let accdist: String
    let averagePrice: Double
    let numberBrokerBuySell: Int
    let totalBuyer: Int
    let totalSeller: Int
    let totalValue: Double
    let totalVolume: Double
    let avg: BandarBucket
    let avg5: BandarBucket
    let top1: BandarBucket
    let top3: BandarBucket
    let top5: BandarBucket
    let top10: BandarBucket
}

/// The full broker-summary response for one symbol and period.
nonisolated struct BrokerSummary: Sendable, Equatable {
    let symbol: String
    let from: String
    let to: String
    let buyers: [BrokerLeg]
    let sellers: [BrokerLeg]
    let detector: BandarDetector
}

// MARK: - DTOs (Stockbit `GET /marketdetectors/{symbol}` envelope)

nonisolated struct BrokerSummaryResponseDTO: Decodable, Sendable {
    let message: String?
    let data: DataDTO

    nonisolated struct DataDTO: Decodable, Sendable {
        let bandarDetector: BandarDetectorDTO
        let brokerSummary: BrokerSummaryDTO
        let from: String
        let to: String

        enum CodingKeys: String, CodingKey {
            case bandarDetector = "bandar_detector"
            case brokerSummary = "broker_summary"
            case from, to
        }
    }
}

nonisolated struct BandarBucketDTO: Decodable, Sendable {
    let accdist: String
    let amount: Double
    let percent: Double
    let vol: Double
}

nonisolated struct BandarDetectorDTO: Decodable, Sendable {
    let average: Double
    let brokerAccdist: String
    let numberBrokerBuysell: Int
    let totalBuyer: Int
    let totalSeller: Int
    let value: Double
    let volume: Double
    let avg: BandarBucketDTO
    let avg5: BandarBucketDTO
    let top1: BandarBucketDTO
    let top3: BandarBucketDTO
    let top5: BandarBucketDTO
    let top10: BandarBucketDTO

    enum CodingKeys: String, CodingKey {
        case average, value, volume, avg, avg5, top1, top3, top5, top10
        case brokerAccdist = "broker_accdist"
        case numberBrokerBuysell = "number_broker_buysell"
        case totalBuyer = "total_buyer"
        case totalSeller = "total_seller"
    }
}

nonisolated struct BrokerSummaryDTO: Decodable, Sendable {
    let symbol: String
    let brokersBuy: [BuyBrokerDTO]
    let brokersSell: [SellBrokerDTO]

    enum CodingKeys: String, CodingKey {
        case symbol
        case brokersBuy = "brokers_buy"
        case brokersSell = "brokers_sell"
    }
}

/// Numeric fields here arrive as strings, sometimes in scientific notation
/// (e.g. `"5.686627505e+11"`), so they are decoded as `String` and parsed lazily.
nonisolated struct BuyBrokerDTO: Decodable, Sendable {
    let netbsBrokerCode: String
    let netbsBuyAvgPrice: String
    let netbsDate: String
    let netbsStockCode: String
    let type: String
    let freq: String
    let blot: String
    let blotv: String
    let bval: String
    let bvalv: String

    enum CodingKeys: String, CodingKey {
        case type, freq, blot, blotv, bval, bvalv
        case netbsBrokerCode = "netbs_broker_code"
        case netbsBuyAvgPrice = "netbs_buy_avg_price"
        case netbsDate = "netbs_date"
        case netbsStockCode = "netbs_stock_code"
    }
}

nonisolated struct SellBrokerDTO: Decodable, Sendable {
    let netbsBrokerCode: String
    let netbsSellAvgPrice: String
    let netbsDate: String
    let netbsStockCode: String
    let type: String
    let freq: String
    let slot: String
    let slotv: String
    let sval: String
    let svalv: String

    enum CodingKeys: String, CodingKey {
        case type, freq, slot, slotv, sval, svalv
        case netbsBrokerCode = "netbs_broker_code"
        case netbsSellAvgPrice = "netbs_sell_avg_price"
        case netbsDate = "netbs_date"
        case netbsStockCode = "netbs_stock_code"
    }
}

// MARK: - DTO → Domain

private func sbDouble(_ s: String) -> Double { Double(s) ?? 0 }

extension BandarBucketDTO {
    func toDomain() -> BandarBucket {
        BandarBucket(accdist: accdist, amount: amount, percent: percent, volume: vol)
    }
}

extension BandarDetectorDTO {
    func toDomain() -> BandarDetector {
        BandarDetector(
            accdist: brokerAccdist,
            averagePrice: average,
            numberBrokerBuySell: numberBrokerBuysell,
            totalBuyer: totalBuyer,
            totalSeller: totalSeller,
            totalValue: value,
            totalVolume: volume,
            avg: avg.toDomain(),
            avg5: avg5.toDomain(),
            top1: top1.toDomain(),
            top3: top3.toDomain(),
            top5: top5.toDomain(),
            top10: top10.toDomain()
        )
    }
}

extension BuyBrokerDTO {
    func toLeg() -> BrokerLeg {
        BrokerLeg(
            brokerCode: netbsBrokerCode,
            averagePrice: sbDouble(netbsBuyAvgPrice),
            lot: sbDouble(blot),
            lotGross: sbDouble(blotv),
            value: sbDouble(bval),
            valueGross: sbDouble(bvalv),
            frequency: Int(sbDouble(freq)),
            category: InvestorCategory(raw: type),
            date: netbsDate
        )
    }
}

extension SellBrokerDTO {
    func toLeg() -> BrokerLeg {
        BrokerLeg(
            brokerCode: netbsBrokerCode,
            averagePrice: sbDouble(netbsSellAvgPrice),
            lot: sbDouble(slot),
            lotGross: sbDouble(slotv),
            value: sbDouble(sval),
            valueGross: sbDouble(svalv),
            frequency: Int(sbDouble(freq)),
            category: InvestorCategory(raw: type),
            date: netbsDate
        )
    }
}

extension BrokerSummaryResponseDTO {
    func toDomain() -> BrokerSummary {
        BrokerSummary(
            symbol: data.brokerSummary.symbol,
            from: data.from,
            to: data.to,
            buyers: data.brokerSummary.brokersBuy.map { $0.toLeg() },
            sellers: data.brokerSummary.brokersSell.map { $0.toLeg() },
            detector: data.bandarDetector.toDomain()
        )
    }
}
