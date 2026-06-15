import Foundation

/// The `{ "raw": …, "formatted": "…" }` pair Stockbit's `order-trade/*` endpoints wrap every
/// number in. `raw` is the machine value and `formatted` is its display string (`"41.2B"`).
///
/// `raw` is **inconsistently typed across the feeds** — a JSON `Int` in the broker payloads, a
/// JSON `Double` elsewhere, and a numeric **`String`** in `top-stock` / `broker/top` /
/// `running-trade/chart`. It is also occasionally absent. The decoder tolerates all of these,
/// surfacing a single `Double?` so callers never branch on the wire type; the numeric-string case
/// reuses `DisplayNumber.parseDecimal` (the same parser the other display strings go through —
/// no second number parser). `formatted` defaults to `""` so a value carrying only `raw` decodes.
nonisolated struct StockbitValue: Decodable, Sendable, Equatable {
    let raw: Double?
    let formatted: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatted = (try? c.decode(String.self, forKey: .formatted)) ?? ""
        if let i = try? c.decode(Int.self, forKey: .raw) {
            raw = Double(i)
        } else if let d = try? c.decode(Double.self, forKey: .raw) {
            raw = d
        } else if let s = try? c.decode(String.self, forKey: .raw) {
            raw = DisplayNumber.parseDecimal(s)
        } else {
            raw = nil
        }
    }

    enum CodingKeys: String, CodingKey { case raw, formatted }
}
