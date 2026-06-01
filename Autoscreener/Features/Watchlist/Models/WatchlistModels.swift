import Foundation

/// One of the three bandar screeners that feed the composite Watchlist.
/// Weights mirror `screener/bandar-master.json` (Ulysees repo). The watchlist
/// score for a stock is the sum of `weight` over every kind that returned it.
nonisolated enum BandarScreenerKind: String, CaseIterable, Sendable {
    case accumulating
    case aboveMA20
    case shiftToday
    case accumDistPositive
    case foreignFlow1M
    case foreignFlow6M

    var weight: Double {
        switch self {
        case .accumulating:      return 2.0
        case .aboveMA20:         return 1.5
        case .shiftToday:        return 2.0
        case .accumDistPositive: return 1.5
        case .foreignFlow1M:     return 1.0
        case .foreignFlow6M:     return 1.5
        }
    }

    var templateID: String {
        switch self {
        case .accumulating:      return "6676213"
        case .aboveMA20:         return "6676217"
        case .shiftToday:        return "6676221"
        case .accumDistPositive: return "6676223"
        case .foreignFlow1M:     return "6676225"
        case .foreignFlow6M:     return "6676228"
        }
    }

    var displayName: String {
        switch self {
        case .accumulating:      return "Bandar Accumulating"
        case .aboveMA20:         return "Bandar Above MA20"
        case .shiftToday:        return "Bandar Shift Today"
        case .accumDistPositive: return "Accum/Dist Positive"
        case .foreignFlow1M:     return "1M Net Foreign Flow"
        case .foreignFlow6M:     return "6M Net Foreign Flow"
        }
    }

    /// Sum of every kind's weight — the highest score a single symbol can earn
    /// (matched by every screener). Derived so the toolbar's "max N" label stays
    /// in sync when kinds are added.
    static var maxCompositeScore: Double {
        allCases.map(\.weight).reduce(0, +)
    }
}

nonisolated struct WatchlistRow: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    var matchedScreeners: Set<BandarScreenerKind>

    var score: Double {
        matchedScreeners.reduce(0) { $0 + $1.weight }
    }

    var id: String { symbol }
}
