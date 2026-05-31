import Foundation

nonisolated struct ScreenerMetric: Hashable, Identifiable, Sendable {
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
}

nonisolated struct ScreenerConfig: Sendable {
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
        zip(sequence, ["Bandar Value", "Bandar Value MA 20"]).map(ScreenerMetric.init)
    }
}

nonisolated struct ScreenerRow: Identifiable, Hashable, Sendable {
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
