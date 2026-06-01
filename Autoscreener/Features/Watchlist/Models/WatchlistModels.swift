import Foundation

/// One of the bandar screeners that feed the composite Watchlist.
/// Weights mirror `screener/bandar-master.json` (Ulysees repo). The watchlist
/// score for a stock is the sum of `weight` over every kind that returned it.
///
/// Veto kinds (`isVeto == true`) follow `bandar-master.json`'s "hard-AND for
/// veto rules": a stock failing any veto gate is flagged "ILLIQUID" in the
/// composite, regardless of its bandar score. Matching a veto still contributes
/// `weight` to the score normally.
nonisolated enum BandarScreenerKind: String, CaseIterable, Codable, Sendable {
    case accumulating
    case aboveMA20
    case shiftToday
    case accumDistPositive
    case foreignFlow1M
    case foreignFlow6M
    case foreignFlow3M
    case foreignBuyStreak
    case freshForeignBuy
    case liquidityFloor
    case intradayLiquidity

    var weight: Double {
        switch self {
        case .accumulating:      return 2.0
        case .aboveMA20:         return 1.5
        case .shiftToday:        return 2.0
        case .accumDistPositive: return 1.5
        case .foreignFlow1M:     return 1.0
        case .foreignFlow6M:     return 1.5
        case .foreignFlow3M:     return 1.0
        case .foreignBuyStreak:  return 1.0
        case .freshForeignBuy:   return 1.5
        case .liquidityFloor:    return 0.5
        case .intradayLiquidity: return 0.5
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
        case .foreignFlow3M:     return "6676231"
        case .foreignBuyStreak:  return "6676235"
        case .freshForeignBuy:   return "6676238"
        case .liquidityFloor:    return "6676314"
        case .intradayLiquidity: return "6676320"
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
        case .foreignFlow3M:     return "3M Net Foreign Flow"
        case .foreignBuyStreak:  return "Foreign Buy Streak ≥5"
        case .freshForeignBuy:   return "Fresh Foreign Buy"
        case .liquidityFloor:    return "Liquidity Floor"
        case .intradayLiquidity: return "Intraday Liquidity"
        }
    }

    /// Veto gates from `bandar-master.json`. A stock missing from any veto kind
    /// is flagged in the Watchlist even if its bandar score is high.
    var isVeto: Bool {
        switch self {
        case .liquidityFloor, .intradayLiquidity: return true
        default:                                  return false
        }
    }

    /// Sum of every kind's weight — the highest score a single symbol can earn
    /// (matched by every screener). Derived so the toolbar's "max N" label stays
    /// in sync when kinds are added.
    static var maxCompositeScore: Double {
        allCases.map(\.weight).reduce(0, +)
    }
}

nonisolated struct WatchlistRow: Identifiable, Hashable, Codable, Sendable {
    let symbol: String
    let name: String
    var matchedScreeners: Set<BandarScreenerKind>

    var score: Double {
        matchedScreeners.reduce(0) { $0 + $1.weight }
    }

    /// True when this stock is missing from any veto-gate screener. Hard-AND
    /// semantics from `bandar-master.json`: the row should be visibly flagged
    /// "ILLIQUID" even if its bandar score is high.
    ///
    /// Caveat: if a veto kind's fetch failed mid-bootstrap, every row will look
    /// vetoed (no rows ⇒ no matches). The WatchlistViewModel surfaces that
    /// failure in its error banner so the flag stays interpretable.
    var isVetoed: Bool {
        BandarScreenerKind.allCases.contains { $0.isVeto && !matchedScreeners.contains($0) }
    }

    var id: String { symbol }
}
