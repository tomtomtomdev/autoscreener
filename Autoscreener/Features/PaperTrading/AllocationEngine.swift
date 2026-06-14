import Foundation

/// The pure allocator behind paper trading — no I/O, no observation, fully unit-testable
/// (the same shape as `RegimeSynthesizer`). It turns *(portfolio, watchlist, regime,
/// prices)* into a proposed `AllocationPlan` via three layers:
///
///   1. **How much to deploy** — map `RegimeRead.score` to a target equity exposure
///      (Zweig: don't fight the Fed/tape). The rest stays in cash.
///   2. **What to hold** — rank veto-clean, priced watchlist names by conviction
///      (`WatchlistRow.score`), take the top-N.
///   3. **How much of each** — conviction weights, fractional-Kelly damped, then
///      water-filled under a per-name cap (which also enforces a position-count floor),
///      lot-rounded, with sub-band deltas suppressed to curb churn (Against the Gods:
///      size for survival, diversify, don't chase the extreme).
nonisolated enum AllocationEngine {

    /// Builds the proposed rebalance. `prices` is keyed by symbol; a watchlist name
    /// with no positive price is skipped (we never fill at a stale cost basis). A `nil`
    /// regime degrades to the neutral band, matching the rest of the app.
    ///
    /// `exitDecisions` (Gate-5) overlays the sell-side discipline onto the regime-weighted target,
    /// keyed by symbol (defaulted empty ⇒ byte-for-byte the regime-only behaviour, so every existing
    /// caller and the harness are unchanged):
    ///   • `.exit` — the name is barred from the buy candidates (no re-entry) and any held position is
    ///     forced to a full sale, overriding the anti-churn band (a broken thesis isn't churn).
    ///   • `.trim` — the name's target is capped at its current size (never add); the natural downward
    ///     rebalance still applies, so the position can still shrink toward its regime target.
    ///   • `.hold` / absent — no constraint; the name sizes purely on conviction + regime.
    static func plan(state: PaperPortfolioState,
                     watchlist: [WatchlistRow],
                     regime: RegimeRead?,
                     prices: [String: Double],
                     exitDecisions: [String: ExitAction] = [:],
                     config: AllocationConfig = .standard) -> AllocationPlan {
        let score = regime?.score ?? 0
        let stance = regime?.stance ?? .neutral
        let exposure = config.exposure(forScore: score)

        let equity = state.equity(prices: prices)
        let cashTarget = equity * (1 - exposure)

        // Layer 2 — rank priced candidates by conviction, take top-N. A Gate-5 `.exit` name is never a
        // candidate, so it can't consume a slot or be re-bought (the held side is forced out below).
        let priced: [WatchlistRow] = watchlist.filter {
            (prices[$0.symbol] ?? 0) > 0 && exitDecisions[$0.symbol] != .exit
        }
        let ranked: [WatchlistRow] = priced.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.symbol < rhs.symbol
        }
        let candidates: [WatchlistRow] = Array(ranked.prefix(config.topN))

        // Layer 3 — weights as a fraction of *total equity*, summing to `exposure`.
        let weights = targetWeights(candidates: candidates, exposure: exposure, config: config)

        // Build target shares (lot-rounded) for the names we want to hold.
        var targetShares: [String: Double] = [:]
        for (row, weight) in zip(candidates, weights) {
            guard let price = prices[row.symbol], price > 0 else { continue }
            let lot = Double(config.execution.lotSize)
            let lots = ((weight * equity) / (price * lot)).rounded(.down)
            targetShares[row.symbol] = max(0, lots) * lot
        }

        // Names to act on: union of current holdings and desired targets. Anything held
        // but no longer targeted resolves to a full exit (target 0).
        let names = Set(state.positions.keys).union(targetShares.keys)
        let nameBySymbol: [String: String] = Dictionary(
            candidates.map { ($0.symbol, $0.name) }, uniquingKeysWith: { first, _ in first })
        let weightBySymbol: [String: Double] = Dictionary(
            zip(candidates.map(\.symbol), weights), uniquingKeysWith: { first, _ in first })

        var lines: [AllocationLine] = []
        for symbol in names {
            guard let price = prices[symbol], price > 0 else { continue } // can't value → skip
            let current = state.positions[symbol]?.shares ?? 0
            // Gate-5 overlay on the regime-weighted target (`.exit` names were already excluded from
            // `targetShares` above, so their target is 0 — the held side is forced out here).
            let exitAction = exitDecisions[symbol]
            var target = targetShares[symbol] ?? 0
            switch exitAction {
            case .exit: target = 0                              // sell in full; barred from re-entry above
            case .trim: target = Swift.min(target, current)     // cap at current — never add to a flagged name
            case .hold, nil: break
            }
            let delta = target - current
            let forcedExit = exitAction == .exit && current > 0
            // Anti-churn: ignore a move worth less than `rebalanceBandPct` of equity — but a forced exit
            // is a deliberate sell, not churn, so it overrides the band.
            if !forcedExit, abs(delta) * price < config.rebalanceBandPct * equity { continue }
            // Sub-lot residue can't trade.
            if abs(delta) < Double(config.execution.lotSize) { continue }

            let side: TradeSide = delta > 0 ? .buy : .sell
            let weight = weightBySymbol[symbol] ?? 0
            lines.append(AllocationLine(
                symbol: symbol,
                name: nameBySymbol[symbol] ?? symbol,
                side: side,
                currentShares: current,
                targetShares: target,
                deltaShares: delta,
                price: price,
                estValue: abs(delta) * price,
                targetWeight: weight,
                rationale: rationale(side: side, symbol: symbol, weight: weight, stance: stance,
                                     exposure: exposure, capped: weight >= config.effectivePerNameCap - 1e-9,
                                     forcedExit: forcedExit)))
        }

        // Sells first (free the cash buys consume), then larger trades first.
        lines.sort { a, b in
            if a.side != b.side { return a.side == .sell }
            return a.estValue > b.estValue
        }

        return AllocationPlan(stance: stance, score: score, targetExposure: exposure,
                              equity: equity, cashTarget: cashTarget, lines: lines)
    }

    // MARK: - Layer 3 weighting

    /// Conviction weights as a fraction of total equity, summing to `exposure`:
    /// damp each score by `weightᵏ` (k = kellyFraction), normalise to `exposure`, then
    /// water-fill under `effectivePerNameCap` so no name dominates and at least
    /// `minPositions` names share the book once exposure is high enough.
    private static func targetWeights(candidates: [WatchlistRow], exposure: Double,
                                      config: AllocationConfig) -> [Double] {
        guard !candidates.isEmpty, exposure > 0 else {
            return Array(repeating: 0, count: candidates.count)
        }
        let cap = config.effectivePerNameCap

        // Damped raw conviction (guard against non-positive scores).
        let raw = candidates.map { pow(max($0.score, 0.0001), config.kellyFraction) }
        let rawSum = raw.reduce(0, +)
        guard rawSum > 0 else {
            // No conviction signal — spread the exposure evenly (still cap-bounded).
            let even = min(cap, exposure / Double(candidates.count))
            return Array(repeating: even, count: candidates.count)
        }

        // Start proportional to `exposure`, then water-fill the cap.
        var weights = raw.map { $0 / rawSum * exposure }
        for _ in 0..<candidates.count {           // converges in ≤ N passes
            var overflow = 0.0
            var freeSum = 0.0
            for i in weights.indices where weights[i] > cap {
                overflow += weights[i] - cap
                weights[i] = cap
            }
            guard overflow > 1e-12 else { break }
            for i in weights.indices where weights[i] < cap { freeSum += weights[i] }
            guard freeSum > 1e-12 else { break }   // everyone capped → remainder stays cash
            for i in weights.indices where weights[i] < cap {
                weights[i] += overflow * (weights[i] / freeSum)
            }
        }
        return weights
    }

    private static func rationale(side: TradeSide, symbol: String, weight: Double, stance: RegimeStance,
                                  exposure: Double, capped: Bool, forcedExit: Bool) -> String {
        let pct = { (x: Double) in String(format: "%.0f%%", x * 100) }
        switch side {
        case .buy:
            let cap = capped ? ", at per-name cap" : ""
            return "\(stance.rawValue): deploy \(pct(exposure)) of equity; \(symbol) sized to \(pct(weight)) on conviction\(cap)."
        case .sell:
            if forcedExit { return "Gate-5: \(symbol) flagged for exit — full sale." }
            return weight <= 0
                ? "\(stance.rawValue): \(symbol) no longer in the regime-weighted target — exit."
                : "\(stance.rawValue): trim \(symbol) toward its \(pct(weight)) target weight."
        }
    }
}
