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

    /// Fresh Foreign Buy (templateID 6676238): Net Foreign Buy Streak > 0.
    /// Same metric (13561) as `foreignBuyStreak` but the threshold is `> 0` — the
    /// streak has *just* turned positive (≥1 day), so this surfaces names where
    /// foreign net buying has only recently started rather than `foreignBuyStreak`'s
    /// sustained ≥5-day run. Mirrors `bandar-master.json`'s `fresh-foreign-buy` rule
    /// (weight 1.5).
    static let freshForeignBuy: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 13561, item1_name: "Net Foreign Buy Streak",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Liquidity Floor (templateID 6676314): Value MA 20 >= 5,000,000,000 IDR.
    /// Veto gate — stocks failing this 5B 20-day-average traded-value floor are
    /// flagged in the composite Watchlist regardless of bandar score (mirrors
    /// `bandar-master.json`'s `liquidity-floor` rule, weight 0.5, veto: true).
    static let liquidityFloor: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">=",
              item1: 16454, item1_name: "Value MA 20",
              item2: "5000000000", item2_name: "",
              multiplier: "0"),
    ]

    /// Intraday Liquidity (templateID 6676320): Value >= 10,000,000,000 IDR.
    /// Veto gate — stocks failing today's 10B traded-value floor are flagged in
    /// the composite Watchlist (mirrors `bandar-master.json`'s `intraday-liquidity`
    /// rule, weight 0.5, veto: true).
    static let intradayLiquidity: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">=",
              item1: 13620, item1_name: "Value",
              item2: "10000000000", item2_name: "",
              multiplier: "0"),
    ]

    /// Frequency Spike (templateID 6676260): Frequency Spike (15396) > 0 **and**
    /// Frequency Analyzer (15394) >= 1.5. Two `basic` filters — per the proxseer
    /// capture Stockbit AND-combines them on the wire, which is *stricter* than
    /// `bandar-master.json`'s `freq-spike` rule (an OR). We mirror the captured
    /// template exactly so page-2+ POSTs reproduce the GET's results. Weight 1.0
    /// (tape-activity group).
    static let freqSpike: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 15396, item1_name: "Frequency Spike",
              item2: "0", item2_name: "",
              multiplier: "0"),
        .init(type: .basic,
              operator_: ">=",
              item1: 15394, item1_name: "Frequency Analyzer",
              item2: "1.5", item2_name: "",
              multiplier: "0"),
    ]

    /// Volume Spike (templateID 6676263): Volume (12469) >= 1.5 × Volume MA 20
    /// (12464). A `compare` filter (column vs column) where `multiplier` scales
    /// `item2` — mirrors `bandar-master.json`'s `volume >= 1.5 * volume_ma_20`
    /// rule. Weight 1.0 (tape-activity group).
    static let volumeSpike: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">=",
              item1: 12469, item1_name: "Volume",
              item2: "12464", item2_name: "Volume MA 20",
              multiplier: "1.5"),
    ]

    /// Above 50MA (templateID 6676264): Price (2661) >= 1 × Price MA 50 (12460).
    /// A `compare` filter — `bandar-master.json`'s `above-50ma` rule (`price >=
    /// price_ma_50`), weight 0.5 (trend group).
    static let above50MA: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">=",
              item1: 2661, item1_name: "Price",
              item2: "12460", item2_name: "Price MA 50",
              multiplier: "1"),
    ]

    /// Above 200MA (templateID 6676268): Price (2661) >= 1 × Price MA 200 (12462).
    /// Long-term-trend counterpart to `above50MA` — `bandar-master.json`'s
    /// `above-200ma` rule (`price >= price_ma_200`), weight 1.0 (trend group).
    static let above200MA: [ScreenerFilter] = [
        .init(type: .compare,
              operator_: ">=",
              item1: 2661, item1_name: "Price",
              item2: "12462", item2_name: "Price MA 200",
              multiplier: "1"),
    ]

    /// Earnings Yield (templateID 6676273): Earnings Yield (TTM) (2898) >= 8.
    /// Single-column `basic` filter — mirrors `bandar-master.json`'s `earnings-yield`
    /// rule (`earnings_yield_ttm >= 8`), weight 1.0 (fundamentals group). 8 is a
    /// percentage (≈ P/E ≤ 12.5). Transcribed from the proxseer POST run body.
    static let earningsYield: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">=",
              item1: 2898, item1_name: "Earnings Yield (TTM)",
              item2: "8", item2_name: "",
              multiplier: "0"),
    ]

    /// PBV Below 2 (templateID 6676280): Current Price to Book Value (2896) > 0 **and**
    /// <= 2. Two `basic` filters on the same metric form a range gate — mirrors
    /// `bandar-master.json`'s `pbv-below-2` rule (`pbv > 0 and pbv <= 2`), weight 1.0
    /// (fundamentals group). The `> 0` arm excludes negative-equity names.
    static let pbvBelow2: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 2896, item1_name: "Current Price to Book Value",
              item2: "0", item2_name: "",
              multiplier: "0"),
        .init(type: .basic,
              operator_: "<=",
              item1: 2896, item1_name: "Current Price to Book Value",
              item2: "2", item2_name: "",
              multiplier: "0"),
    ]

    /// ROE Quality (templateID 6676288): Return on Equity (TTM) (1461) >= 12.
    /// Single-column `basic` filter — mirrors `bandar-master.json`'s `roe-quality`
    /// rule (`roe_ttm >= 12`), weight 1.0 (fundamentals group).
    static let roeQuality: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">=",
              item1: 1461, item1_name: "Return on Equity (TTM)",
              item2: "12", item2_name: "",
              multiplier: "0"),
    ]

    /// FCF Positive (templateID 6676291): Free cash flow (TTM) (2538) > 0.
    /// Single-column `basic` filter — mirrors `bandar-master.json`'s `fcf-positive`
    /// rule (`fcf_ttm > 0`), weight 1.0 (fundamentals group).
    static let fcfPositive: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: ">",
              item1: 2538, item1_name: "Free cash flow (TTM)",
              item2: "0", item2_name: "",
              multiplier: "0"),
    ]

    /// Manageable Debt (templateID 6676292): Debt to Equity Ratio (Quarter) (1508) < 1.5.
    /// Single-column `basic` filter — mirrors `bandar-master.json`'s `manageable-debt`
    /// rule (`der < 1.5`), weight 1.0 (fundamentals group).
    static let manageableDebt: [ScreenerFilter] = [
        .init(type: .basic,
              operator_: "<",
              item1: 1508, item1_name: "Debt to Equity Ratio (Quarter)",
              item2: "1.5", item2_name: "",
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
        case 1461:  return "Return on Equity (TTM)"
        case 1508:  return "Debt to Equity Ratio (Quarter)"
        case 2538:  return "Free cash flow (TTM)"
        case 2661:  return "Price"
        case 2896:  return "Current Price to Book Value"
        case 2898:  return "Earnings Yield (TTM)"
        case 12460: return "Price MA 50"
        case 12462: return "Price MA 200"
        case 12464: return "Volume MA 20"
        case 12469: return "Volume"
        case 13561: return "Net Foreign Buy Streak"
        case 13580: return "1M Net Foreign Flow"
        case 13581: return "3M Net Foreign Flow"
        case 13582: return "6M Net Foreign Flow"
        case 13620: return "Value"
        case 14399: return "Bandar Value"
        case 14400: return "Bandar Accum/Dist"
        case 14425: return "Previous Bandar Value"
        case 14426: return "Bandar Value MA 20"
        case 15394: return "Frequency Analyzer"
        case 15396: return "Frequency Spike"
        case 16454: return "Value MA 20"
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
