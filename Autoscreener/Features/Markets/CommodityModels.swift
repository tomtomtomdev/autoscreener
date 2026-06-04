import Foundation

// MARK: - Domain

/// A single price snapshot for a commodity (Crude Oil, Gold, …) or an FX pair
/// (USD/IDR), as shown in the Markets list. Sourced from `GET /emitten/{symbol}/info`
/// — *not* `indicative-price-volume`, which is null outside the pre-open auction.
///
/// `price` is the numeric last price for math/sorting; `formattedPrice` is the
/// server's display string (already grouped with thousands separators, e.g.
/// "4,493"). `change` is the absolute move vs. `previousClose`; `changePercent`
/// is the same move as a percentage.
nonisolated struct CommodityQuote: Sendable, Equatable {
    let symbol: String
    let name: String
    let price: Double
    let previousClose: Double?
    /// Absolute change vs. previous close. Server sends it signed ("+26.44"/"-0.98").
    let change: Double?
    /// Percentage change vs. previous close (server sends this as a JSON number).
    let changePercent: Double?
    let volume: Double?
    /// Pre-formatted display price ("95", "4,493", "18,040"). Never parse this as a
    /// number — it can contain thousands-separator commas.
    let formattedPrice: String
    /// Display timestamp of the quote, e.g. "Thu 14:22". Presentation-only.
    let asOf: String

    /// `true` when the quote is flat or up on the session. Prefers the percentage,
    /// falling back to the absolute change, then treating "unknown" as up.
    var isUp: Bool { (changePercent ?? change ?? 0) >= 0 }
}

// MARK: - DTO (`GET /emitten/{symbol}/info`)

nonisolated enum CommodityDecodeError: Error, Equatable { case malformedQuote }

/// Decodes the `data` envelope of `/emitten/{symbol}/info`. Only the price-relevant
/// fields are modelled; everything else (orderbook, followers, corp actions, …) is
/// ignored. Type gotchas from the live wire format (verified 2026-06-04):
/// - `price`/`previous`/`change`/`volume` arrive as **strings**; `change` is signed.
/// - `percentage` arrives as a **JSON number**.
/// - `value`/`average` can be the literal string "NA" — left undecoded, so they
///   can't break the decode.
nonisolated struct EmittenInfoResponseDTO: Decodable, Sendable {
    let data: DataDTO

    nonisolated struct DataDTO: Decodable, Sendable {
        let symbol: String
        let name: String
        let price: String
        let formattedPrice: String?
        let previous: String?
        let change: String?
        let percentage: Double?
        let volume: String?
        let time: String?

        enum CodingKeys: String, CodingKey {
            case symbol, name, price
            case formattedPrice = "formatted_price"
            case previous, change, percentage, volume, time
        }
    }
}

extension EmittenInfoResponseDTO {
    /// Maps the wire DTO to the domain quote. Throws `malformedQuote` only when the
    /// numeric `price` can't be parsed — the optional fields degrade to `nil` rather
    /// than failing the whole row.
    func toDomain() throws -> CommodityQuote {
        guard let price = Double(data.price) else { throw CommodityDecodeError.malformedQuote }
        return CommodityQuote(
            symbol: data.symbol,
            name: data.name,
            price: price,
            previousClose: data.previous.flatMap(Double.init),
            change: data.change.flatMap(Double.init),
            changePercent: data.percentage,
            volume: data.volume.flatMap(Double.init),
            formattedPrice: data.formattedPrice ?? data.price,
            asOf: data.time ?? ""
        )
    }
}
