import Foundation

nonisolated struct ScreenerMetric: Hashable, Identifiable, Codable, Sendable {
    let id: Int
    let name: String
}

nonisolated struct ScreenerUniverse: Codable, Hashable, Sendable {
    let scopeID: String
    let name: String
    let scope: String

    static let ihsg = ScreenerUniverse(scopeID: "0", name: "IHSG", scope: "IHSG")
}

nonisolated struct ScreenerFilter: Codable, Hashable, Sendable {
    enum FilterType: String, Codable, Sendable { case basic, compare }

    var type: FilterType
    var operator_: String
    var item1: Int
    var item1_name: String
    var item2: String
    var item2_name: String
    var multiplier: String

    private enum CodingKeys: String, CodingKey {
        case type, operator_ = "operator", item1, item1_name, item2, item2_name, multiplier
    }

    /// Bandar Accumulating (templateID 6676213): Bandar Value > Bandar Value MA20 **and**
    /// Bandar Value > 0. The basic > 0 filter excludes negative accumulation.
    static let bandarAccumulating: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">",
              item1: 14399, item1_name: "Bandar Value",
              item2: "14426", item2_name: "Bandar Value MA 20",
              multiplier: "1"),
        .init(type: .basic,
              operator_: ">",
              item1: 14399, item1_name: "Bandar Value",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Bandar Above MA20 (templateID 6676217): Bandar Value > Bandar Value MA20 only.
    /// One fewer filter than `bandarAccumulating` — fewer criteria, more matches.
    static let bandarAboveMA20: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">",
              item1: 14399, item1_name: "Bandar Value",
              item2: "14426", item2_name: "Bandar Value MA 20",
              multiplier: "1"),
    ]

    /// Bandar Shift Today (templateID 6676221): Bandar Value > Previous Bandar Value.
    /// Compares today's accumulation against yesterday's snapshot (metric 14425),
    /// not the 20-day MA — sequence is `[14399, 14425]`.
    static let bandarShiftToday: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">",
              item1: 14399, item1_name: "Bandar Value",
              item2: "14425", item2_name: "Previous Bandar Value",
              multiplier: "1"),
    ]

    /// Accum/Dist Positive (templateID 6676223): Bandar Accum/Dist > 0. Single-column
    /// `basic` filter — `item2` is the literal threshold "0", not a metric ID.
    static let accumDistPositive: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 14400, item1_name: "Bandar Accum/Dist",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Foreign Flow 1M (templateID 6676225): 1 Month Net Foreign Flow > 0.
    /// Single-column `basic` filter mirroring `accumDistPositive`'s shape — metric
    /// 13580 is the trailing-30-day net foreign accumulation.
    static let foreignFlow1M: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 13580, item1_name: "1 Month Net Foreign Flow",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Foreign Flow 6M (templateID 6676228): 6 Month Net Foreign Flow > 0.
    /// Long-horizon counterpart to `foreignFlow1M` — metric 13582 is the
    /// trailing-six-month net foreign accumulation.
    static let foreignFlow6M: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 13582, item1_name: "6 Month Net Foreign Flow",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Foreign Flow 3M (templateID 6676231): 3 Month Net Foreign Flow > 0.
    /// Mid-horizon counterpart to `foreignFlow1M` / `foreignFlow6M` — metric 13581
    /// is the trailing-three-month net foreign accumulation.
    static let foreignFlow3M: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 13581, item1_name: "3 Month Net Foreign Flow",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Foreign Buy Streak ≥ 5 (templateID 6676235): Net Foreign Buy Streak >= 5.
    /// Single-column `basic` filter — metric 13561 counts consecutive trading days
    /// of positive net foreign buy; threshold 5 mirrors `bandar-master.json`'s
    /// `foreign-buy-streak` rule.
    static let foreignBuyStreak: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">=",
              item1: 13561, item1_name: "Net Foreign Buy Streak",
              item2: "5", item2_name: "",
              multiplier: "0"),
    ]
}

nonisolated struct ScreenerConfig: Codable, Sendable {
    var name: String = "bandar-accumulating"
    var filters: [ScreenerFilter] = ScreenerFilter.bandarAccumulating
    var universe: ScreenerUniverse = .ihsg
    var sequence: [Int] = [14399, 14426]
    var orderColumn: Int = 2
    var orderType: String = "desc"
    var limit: Int = 25
    var screenerID: String = "6676213"
    var description: String = ""

    var columns: [ScreenerMetric] {
        sequence.map { ScreenerMetric(id: $0, name: Self.metricName(for: $0)) }
    }

    enum CodingKeys: String, CodingKey {
        case name, filters, universe, sequence, orderColumn, orderType, limit, screenerID, description
    }

    /// Maps a Stockbit metric ID to its display name. Extend as new screeners
    /// introduce new metric IDs — bandar-shift-today added 14425.
    static func metricName(for id: Int) -> String {
        switch id {
        case 13561: return "Net Foreign Buy Streak"
        case 13580: return "1M Net Foreign Flow"
        case 13581: return "3M Net Foreign Flow"
        case 13582: return "6M Net Foreign Flow"
        case 14399: return "Bandar Value"
        case 14400: return "Bandar Accum/Dist"
        case 14425: return "Previous Bandar Value"
        case 14426: return "Bandar Value MA 20"
        default:    return "Metric \(id)"
        }
    }
}

nonisolated struct ScreenerRow: Identifiable, Hashable, Codable, Sendable {
    let symbol: String
    let name: String
    let values: [Double?]
    let lastPrice: Double?
    let pctChange: Double?

    var id: String { symbol }

    func value(at columnIndex: Int) -> Double? {
        guard columnIndex < values.count else { return nil }
        return values[columnIndex]
    }

    /// Comparator used by ScreenerView for descending Last/Δ% sorts even when some rows are missing the value.
    static func sortNilLast<T: Comparable>(_ a: T?, _ b: T?, ascending: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?): return ascending ? x < y : x > y
        }
    }
}

nonisolated struct ScreenerPage: Sendable {
    let rows: [ScreenerRow]
    let total: Int?
    let page: Int
}
