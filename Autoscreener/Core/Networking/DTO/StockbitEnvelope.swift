import Foundation

/// Stockbit's `exodus` JSON responses share one envelope: `{ "message": String, "data": <T?> }`.
///
/// `data` is legitimately absent on "no data" replies — `null` (e.g. `analyst-ratings` for an
/// uncovered name) or an empty array (e.g. `analyst-ratings/{sym}/consensus`) — so it is decoded
/// as **optional**. A service decodes `StockbitEnvelope<ItsDataDTO>` and treats a `nil` `data` as
/// "no data", not a transport/parse failure. `message` is non-load-bearing and also optional so a
/// response that omits it still decodes.
nonisolated struct StockbitEnvelope<T: Decodable>: Decodable {
    let message: String?
    let data: T?
}
