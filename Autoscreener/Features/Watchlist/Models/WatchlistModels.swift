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
    case freqSpike
    case volumeSpike
    case above50MA
    case above200MA
    case earningsYield
    case pbvBelow2
    case roeQuality
    case fcfPositive
    case manageableDebt
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
        case .freqSpike:         return 1.0
        case .volumeSpike:       return 1.0
        case .above50MA:         return 0.5
        case .above200MA:        return 1.0
        case .earningsYield:     return 1.0
        case .pbvBelow2:         return 1.0
        case .roeQuality:        return 1.0
        case .fcfPositive:       return 1.0
        case .manageableDebt:    return 1.0
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
        case .freqSpike:         return "6676260"
        case .volumeSpike:       return "6676263"
        case .above50MA:         return "6676264"
        case .above200MA:        return "6676268"
        case .earningsYield:     return "6676273"
        case .pbvBelow2:         return "6676280"
        case .roeQuality:        return "6676288"
        case .fcfPositive:       return "6676291"
        case .manageableDebt:    return "6676292"
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
        case .freqSpike:         return "Frequency Spike"
        case .volumeSpike:       return "Volume Spike"
        case .above50MA:         return "Above 50MA"
        case .above200MA:        return "Above 200MA"
        case .earningsYield:     return "Earnings Yield ≥8%"
        case .pbvBelow2:         return "PBV ≤2"
        case .roeQuality:        return "ROE ≥12%"
        case .fcfPositive:       return "Positive FCF"
        case .manageableDebt:    return "DER <1.5"
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

    /// The veto-gate kinds, as a set. Convenience for veto evaluation.
    static var vetoKinds: Set<BandarScreenerKind> { Set(allCases.filter(\.isVeto)) }

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

    /// Veto gates this row FAILS — but restricted to the gates that were actually
    /// evaluated (freshly fetched, or from the current cache generation) when this
    /// composite was built. A gate that was stale or missing is deliberately absent
    /// here: we don't flag a stock against a gate we couldn't read, which is what
    /// caused the "every row shows ILLIQUID" bug when one liquidity cache went stale.
    /// Materialized by `WatchlistViewModel` at composition time so the verdict travels
    /// with the persisted snapshot and survives a cold boot. Empty ⇒ liquid (no flag).
    var failedVetoGates: Set<BandarScreenerKind>

    init(symbol: String,
         name: String,
         matchedScreeners: Set<BandarScreenerKind>,
         failedVetoGates: Set<BandarScreenerKind> = []) {
        self.symbol = symbol
        self.name = name
        self.matchedScreeners = matchedScreeners
        self.failedVetoGates = failedVetoGates
    }

    private enum CodingKeys: String, CodingKey {
        case symbol, name, matchedScreeners, failedVetoGates
    }

    // Custom decode tolerates snapshots written before `failedVetoGates` existed —
    // they decode to "not vetoed" and self-correct on the next refresh.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decode(String.self, forKey: .name)
        matchedScreeners = try c.decode(Set<BandarScreenerKind>.self, forKey: .matchedScreeners)
        failedVetoGates = try c.decodeIfPresent(Set<BandarScreenerKind>.self, forKey: .failedVetoGates) ?? []
    }

    var score: Double {
        matchedScreeners.reduce(0) { $0 + $1.weight }
    }

    /// True when this stock fails at least one veto gate that was actually evaluated.
    /// Hard-AND semantics from `bandar-master.json` — but only over gates we hold a
    /// usable reading for (see `failedVetoGates`).
    var isVetoed: Bool { !failedVetoGates.isEmpty }

    var id: String { symbol }
}
