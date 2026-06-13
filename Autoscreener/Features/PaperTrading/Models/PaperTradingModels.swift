import Foundation

// MARK: - Portfolio state (persisted)

/// One open paper position: shares held and the average cost basis per share.
/// Mirrors `Lot` in `BacktestHarness.swift`, but `Codable` so the live portfolio
/// round-trips to disk like the other stores.
nonisolated struct PaperPosition: Codable, Hashable, Sendable {
    var shares: Double
    var avgCost: Double
    /// The buy thesis recorded when this lot was first opened (Gate-5 Phase 3). `nil` for lots opened
    /// before Phase 3, or bought outside a recently-ranked set — those review on current data alone.
    /// Preserved across adds (the entry rationale is the *original* one) and dropped when the lot closes.
    var thesis: EntryThesis? = nil
}

/// An executed paper fill, appended to the trade log. `realizedPnL` is non-nil only
/// for sells (proceeds − cost basis, both after fees).
nonisolated struct PaperTrade: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let date: Date
    let side: TradeSide
    let symbol: String
    let shares: Double
    let price: Double
    let fee: Double
    let realizedPnL: Double?

    init(id: UUID = UUID(), date: Date, side: TradeSide, symbol: String, shares: Double,
         price: Double, fee: Double, realizedPnL: Double? = nil) {
        self.id = id; self.date = date; self.side = side; self.symbol = symbol
        self.shares = shares; self.price = price; self.fee = fee; self.realizedPnL = realizedPnL
    }
}

/// The whole paper portfolio: starting capital, free cash, open positions and the
/// trade log. A fresh portfolio is *seeded* (`cash == initialCapital`); the fill math
/// (avg-cost basis, fee on both sides) mirrors `Portfolio.apply` in `BacktestHarness.swift`.
nonisolated struct PaperPortfolioState: Codable, Sendable {
    /// The brief: a 100,000,000 IDR paper account.
    static let seedCapital: Double = 100_000_000

    var initialCapital: Double
    var cash: Double
    var positions: [String: PaperPosition]
    var trades: [PaperTrade]

    static var seed: PaperPortfolioState {
        PaperPortfolioState(initialCapital: seedCapital, cash: seedCapital, positions: [:], trades: [])
    }

    /// Marked-to-market equity: cash + Σ shares × price. A held name with no live
    /// price falls back to its avg cost (mirrors `Portfolio.equity`).
    func equity(prices: [String: Double]) -> Double {
        cash + positions.reduce(0) { acc, kv in
            acc + kv.value.shares * (prices[kv.key] ?? kv.value.avgCost)
        }
    }

    /// Equity at risk in positions (equity − cash).
    func investedValue(prices: [String: Double]) -> Double { equity(prices: prices) - cash }

    /// Unrealized P&L vs cost basis across open positions.
    func unrealizedPnL(prices: [String: Double]) -> Double {
        positions.reduce(0) { acc, kv in
            let px = prices[kv.key] ?? kv.value.avgCost
            return acc + kv.value.shares * (px - kv.value.avgCost)
        }
    }

    /// Realized P&L booked across the trade log.
    var realizedPnL: Double { trades.compactMap(\.realizedPnL).reduce(0, +) }

    /// Applies a single fill, mutating cash/positions and appending a `PaperTrade`.
    /// `feePct` is charged on notional on both sides (buy adds, sell deducts).
    /// Mirrors `Portfolio.apply`'s avg-cost accounting. Returns the booked trade, or
    /// `nil` for a no-op (zero shares, or a sell with nothing held).
    @discardableResult
    mutating func apply(side: TradeSide, symbol: String, shares: Double, price: Double,
                        feePct: Double, date: Date, thesis: EntryThesis? = nil) -> PaperTrade? {
        guard shares > 0, price > 0 else { return nil }
        switch side {
        case .buy:
            let fee = shares * price * feePct
            cash -= shares * price + fee
            var lot = positions[symbol] ?? PaperPosition(shares: 0, avgCost: 0)
            let opening = lot.shares == 0                  // fresh entry (new or re-bought after a full exit)
            let newShares = lot.shares + shares
            lot.avgCost = newShares > 0 ? (lot.avgCost * lot.shares + price * shares) / newShares : 0
            lot.shares = newShares
            if opening, let thesis { lot.thesis = thesis }  // record the entry rationale once; preserve on adds
            positions[symbol] = lot
            let trade = PaperTrade(date: date, side: .buy, symbol: symbol, shares: shares,
                                   price: price, fee: fee)
            trades.append(trade)
            return trade
        case .sell:
            guard var lot = positions[symbol], lot.shares > 0 else { return nil }
            let qty = min(shares, lot.shares)
            let fee = qty * price * feePct
            let proceeds = qty * price - fee
            let realized = proceeds - qty * lot.avgCost
            cash += proceeds
            lot.shares -= qty
            if lot.shares <= 0 { positions[symbol] = nil } else { positions[symbol] = lot }
            let trade = PaperTrade(date: date, side: .sell, symbol: symbol, shares: qty,
                                   price: price, fee: fee, realizedPnL: realized)
            trades.append(trade)
            return trade
        }
    }
}

// MARK: - Allocation config

/// The knobs of the regime-gated, conviction-weighted, risk-capped allocator. The
/// defaults encode the framework: Zweig-style exposure bands (Layer 1), a fractional
/// Kelly damp + per-name cap + position-count floor (Layer 3), and IDX execution costs.
nonisolated struct AllocationConfig: Codable, Sendable {
    // Layer 1 — equity-exposure band endpoints by stance (fraction of total equity
    // deployed; the rest is cash). Risk-on never reaches 100% — a survive-first floor.
    var riskOffMin: Double = 0.0
    var riskOffMax: Double = 0.30
    var neutralMin: Double = 0.50
    var neutralMax: Double = 0.60
    var riskOnMin: Double = 0.60
    var riskOnMax: Double = 0.95

    // Layer 2/3 — universe and sizing.
    var topN: Int = 12
    var perNameCap: Double = 0.20       // max fraction of total equity in one name
    var minPositions: Int = 6           // diversification target when fully deployed
    var kellyFraction: Double = 0.5     // damp conviction: weightᵏ, k < 1 (√ by default)
    var rebalanceBandPct: Double = 0.02 // skip a delta smaller than this × equity (anti-churn)
    var execution: ExecutionModel = .standardIDX

    static let standard = AllocationConfig()

    /// The stance-band endpoints used by the score → exposure map.
    var scoreRiskOff: Double { -0.33 }
    var scoreRiskOn: Double { 0.33 }

    /// Piecewise-linear map from the regime score ∈ [−1,+1] to target equity exposure.
    /// Each stance band interpolates between its own min/max so exposure rises smoothly
    /// with conviction within a regime.
    func exposure(forScore score: Double) -> Double {
        let s = max(-1, min(1, score))
        if s <= scoreRiskOff {
            let t = (s + 1) / (scoreRiskOff + 1)               // [-1,-0.33] → 0…1
            return riskOffMin + t * (riskOffMax - riskOffMin)
        } else if s < scoreRiskOn {
            let t = (s - scoreRiskOff) / (scoreRiskOn - scoreRiskOff)
            return neutralMin + t * (neutralMax - neutralMin)
        } else {
            let t = (s - scoreRiskOn) / (1 - scoreRiskOn)      // [0.33,1] → 0…1
            return riskOnMin + t * (riskOnMax - riskOnMin)
        }
    }

    /// The cap actually applied to a single name's weight: the tighter of the explicit
    /// per-name cap and `1/minPositions`. The latter forces ≥ `minPositions` names once
    /// exposure is high enough to fill them (Against-the-Gods diversification).
    var effectivePerNameCap: Double { Swift.min(perNameCap, 1.0 / Double(max(minPositions, 1))) }
}

// MARK: - Allocation plan (proposed, not yet executed)

/// One proposed buy/sell toward the regime-weighted target. `rationale` makes the
/// reasoning visible in the UI — the same transparency ethos as `RegimeFactor.detail`.
nonisolated struct AllocationLine: Identifiable, Sendable, Hashable {
    let symbol: String
    let name: String
    let side: TradeSide
    let currentShares: Double
    let targetShares: Double
    let deltaShares: Double        // signed: + buy, − sell
    let price: Double
    let estValue: Double           // |deltaShares| × price (gross)
    let targetWeight: Double       // target fraction of total equity in this name
    let rationale: String
    var id: String { symbol }
}

/// The full proposed rebalance: the regime context that drove it plus the per-name
/// lines. Nothing is executed until the user confirms (`PaperTradingStore.apply`).
nonisolated struct AllocationPlan: Sendable {
    let stance: RegimeStance
    let score: Double
    let targetExposure: Double     // fraction of equity to deploy
    let equity: Double
    let cashTarget: Double
    let lines: [AllocationLine]

    var hasTrades: Bool { !lines.isEmpty }

    static let empty = AllocationPlan(stance: .neutral, score: 0, targetExposure: 0,
                                      equity: 0, cashTarget: 0, lines: [])
}
