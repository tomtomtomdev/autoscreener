import Foundation

// MARK: - Domain

/// A single numeric metric as Stockbit returns it: the machine value plus the
/// display string it already formatted (e.g. `raw: -360701021000`, `formatted: "-360.70 B"`).
nonisolated struct FlowMetric: Sendable, Equatable {
    let raw: Double
    let formatted: String
}

/// Foreign vs. domestic aggregate for one dimension (Value / Volume / Frequency),
/// each side carrying its share of the period total.
nonisolated struct ForeignFlowBreakdown: Sendable, Equatable {
    let label: String
    let total: FlowMetric
    let foreignTotal: FlowMetric
    let foreignPercentage: Double
    let domesticTotal: FlowMetric
    let domesticPercentage: Double
}

/// Foreign/domestic money flow for one symbol over a period.
///
/// Headline figures (`*Buy` / `*Sell` / `net*`) are value-based (IDR) from the
/// summary block; `value` / `volume` / `frequency` carry the full split with shares.
/// A negative `netForeign.raw` means net foreign *selling*.
nonisolated struct ForeignFlow: Sendable, Equatable {
    let symbol: String
    let dateRange: String
    let from: String
    let to: String
    let lastUpdated: String

    let foreignBuy: FlowMetric
    let foreignSell: FlowMetric
    let netForeign: FlowMetric
    let domesticBuy: FlowMetric
    let domesticSell: FlowMetric
    let netDomestic: FlowMetric

    let value: ForeignFlowBreakdown
    let volume: ForeignFlowBreakdown
    let frequency: ForeignFlowBreakdown
}

// MARK: - DTOs (Stockbit `GET /findata-view/foreign-domestic/v1/chart-data/{symbol}`)

nonisolated struct MetricDTO: Decodable, Sendable {
    let raw: Double
    let formatted: String
}

nonisolated struct LabeledMetricDTO: Decodable, Sendable {
    let label: String?
    let value: MetricDTO
}

nonisolated struct BreakdownItemDTO: Decodable, Sendable {
    let label: String?
    let value: MetricDTO
    let percentage: MetricDTO
}

nonisolated struct ForeignFlowResponseDTO: Decodable, Sendable {
    let message: String?
    let data: DataDTO

    nonisolated struct DataDTO: Decodable, Sendable {
        let summary: SummaryDTO
        let value: BreakdownDTO
        let volume: BreakdownDTO
        let frequency: BreakdownDTO
        let lastUpdated: String
        let from: String
        let to: String

        enum CodingKeys: String, CodingKey {
            case summary, value, volume, frequency, from, to
            case lastUpdated = "last_updated"
        }
    }

    nonisolated struct SummaryDTO: Decodable, Sendable {
        let dateRange: String
        let foreignBuy: LabeledMetricDTO
        let foreignSell: LabeledMetricDTO
        let netForeign: LabeledMetricDTO
        let domesticBuy: LabeledMetricDTO
        let domesticSell: LabeledMetricDTO
        let netDomestic: LabeledMetricDTO

        enum CodingKeys: String, CodingKey {
            case dateRange = "date_range"
            case foreignBuy = "foreign_buy"
            case foreignSell = "foreign_sell"
            case netForeign = "net_foreign"
            case domesticBuy = "domestic_buy"
            case domesticSell = "domestic_sell"
            case netDomestic = "net_domestic"
        }
    }

    nonisolated struct BreakdownDTO: Decodable, Sendable {
        let label: String
        let total: MetricDTO
        let foreignBuy: BreakdownItemDTO
        let foreignSell: BreakdownItemDTO
        let domesticBuy: BreakdownItemDTO
        let domesticSell: BreakdownItemDTO
        let foreignTotal: BreakdownItemDTO
        let domesticTotal: BreakdownItemDTO

        enum CodingKeys: String, CodingKey {
            case label, total
            case foreignBuy = "foreign_buy"
            case foreignSell = "foreign_sell"
            case domesticBuy = "domestic_buy"
            case domesticSell = "domestic_sell"
            case foreignTotal = "foreign_total"
            case domesticTotal = "domestic_total"
        }
    }
}

// MARK: - DTO → Domain

private extension MetricDTO {
    var flow: FlowMetric { FlowMetric(raw: raw, formatted: formatted) }
}

private extension LabeledMetricDTO {
    var flow: FlowMetric { value.flow }
}

extension ForeignFlowResponseDTO.BreakdownDTO {
    func toDomain() -> ForeignFlowBreakdown {
        ForeignFlowBreakdown(
            label: label,
            total: total.flow,
            foreignTotal: foreignTotal.value.flow,
            foreignPercentage: foreignTotal.percentage.raw,
            domesticTotal: domesticTotal.value.flow,
            domesticPercentage: domesticTotal.percentage.raw
        )
    }
}

extension ForeignFlowResponseDTO {
    func toDomain(symbol: String) -> ForeignFlow {
        ForeignFlow(
            symbol: symbol,
            dateRange: data.summary.dateRange,
            from: data.from,
            to: data.to,
            lastUpdated: data.lastUpdated,
            foreignBuy: data.summary.foreignBuy.flow,
            foreignSell: data.summary.foreignSell.flow,
            netForeign: data.summary.netForeign.flow,
            domesticBuy: data.summary.domesticBuy.flow,
            domesticSell: data.summary.domesticSell.flow,
            netDomestic: data.summary.netDomestic.flow,
            value: data.value.toDomain(),
            volume: data.volume.toDomain(),
            frequency: data.frequency.toDomain()
        )
    }
}
