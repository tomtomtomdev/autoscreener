import Foundation

/// Codable model for the confirmed Stockbit screener response (2026-05-31).
///
///   { "data": {
///       "calcs": [
///         { "company": { "symbol", "name", "icon_url", … },
///           "results": [ { "id": 14399, "item": "Bandar Value", "raw": "14925216921719.91", "display": "14,925.22 B" }, … ] }
///       ],
///       "total": ?     // not always present
///     } }
///
/// Returned by both `GET /screener/templates/{id}` (page 1) and
/// `POST /screener/templates` with `save="0"` (pages ≥ 2).
nonisolated struct ScreenerResponseDTO: Decodable, Sendable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable, Sendable {
        let calcs: [CalcDTO]?
        let total: Int?
    }

    nonisolated struct CalcDTO: Decodable, Sendable {
        let company: CompanyDTO
        let results: [MetricResultDTO]
    }

    nonisolated struct CompanyDTO: Decodable, Sendable {
        let symbol: String
        let name: String
        let id: String?
        let exchange: String?
        let country: String?
        let iconURL: String?
        let lastPrice: Double?
        let pctChange: Double?

        enum CodingKeys: String, CodingKey {
            case symbol, name, id, exchange, country
            case iconURL = "icon_url"
            case lastPrice = "last_price"
            case pctChange = "pct_change"
        }
    }

    nonisolated struct MetricResultDTO: Decodable, Sendable {
        let id: Int
        let item: String?
        let raw: String?       // server-side decimal, e.g. "14925216921719.91"
        let display: String?

        /// The server ships numeric values as strings under `raw`. Parse them to Double here
        /// so consumers don't repeat the conversion.
        var value: Double? {
            if let raw, let d = Double(raw) { return d }
            return nil
        }
    }
}

extension ScreenerResponseDTO.CalcDTO {
    /// Project a server `calc` into the app's row model, picking metric values in `sequence` order.
    func toRow(sequence: [Int]) -> ScreenerRow {
        let byID = Dictionary(uniqueKeysWithValues:
            results.compactMap { r -> (Int, Double)? in
                guard let v = r.value else { return nil }
                return (r.id, v)
            }
        )
        return ScreenerRow(
            symbol: company.symbol,
            name: company.name,
            values: sequence.map { byID[$0] },
            lastPrice: company.lastPrice,
            pctChange: company.pctChange
        )
    }
}
