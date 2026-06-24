import Foundation

/// The pure allocator behind paper trading — no I/O, no observation, fully unit-testable
/// (the same shape as `RegimeSynthesizer`). It turns *(portfolio, candidates, regime,
/// prices)* into a proposed `AllocationPlan` via three layers:
///
///   1. **How much to deploy** — map `RegimeRead.score` to a target equity exposure
///      (Zweig: don't fight the Fed/tape). The rest stays in cash.
///   2. **What to hold** — rank veto-clean, priced buy candidates (the gate-filtered
///      Tier-A `Recommendation`s) by conviction, take the top-N.
///   3. **How much of each** — size by the engine's own `suggestedWeight` (or, per
///      `config.sizingBasis`, fractional-Kelly-damped conviction), then water-fill under
///      a per-name cap (which also enforces a position-count floor), lot-round, and
///      suppress sub-band deltas to curb churn (Against the Gods: size for survival,
///      diversify, don't chase the extreme).
nonisolated enum AllocationEngine {

    /// Builds the proposed rebalance. `prices` is keyed by symbol; a candidate with no positive price
    /// is skipped (we never fill at a stale cost basis). A `nil` regime degrades to the neutral band,
    /// matching the rest of the app.
    ///
    /// `candidates` is the buy universe — the ranked, gate-filtered Tier-A recommendations (flattened to
    /// `AllocationCandidate`). A name that isn't a candidate is never bought; a held name that has
    /// dropped out of the set resolves to a full sale below.
    ///
    /// `exitDecisions` (Gate-5) overlays the sell-side discipline onto the regime-weighted target,
    /// keyed by symbol (defaulted empty ⇒ regime-only behaviour):
    ///   • `.exit` — the name is barred from the buy candidates (no re-entry) and any held position is
    ///     forced to a full sale, overriding the anti-churn band (a broken thesis isn't churn).
    ///   • `.trim` — the name's target is capped at its current size (never add); the natural downward
    ///     rebalance still applies, so the position can still shrink toward its regime target.
    ///   • `.hold` / absent — no constraint; the name sizes purely on its signal + regime.
    static func plan(state: PaperPortfolioState,
                     candidates universe: [AllocationCandidate],
                     regime: RegimeRead?,
                     prices: [String: Double],
                     exitDecisions: [String: ExitAction] = [:],
                     config: AllocationConfig = .standard) -> AllocationPlan {
        let score = regime?.score ?? 0
        let stance = regime?.stance ?? .neutral
        // Regime-blind books (RiBeTS) pin exposure to `fixedExposure`, ignoring the score; regime-aware
        // books (RAPaTS) map the score onto the stance exposure band.
        let exposure = config.fixedExposure ?? config.exposure(forScore: score)

        // Effective price per name: prefer the live screener price; fall back to the candidate's own
        // reference price (the close the selection engine valued it at). A recommended name is therefore
        // sizeable even when the screener snapshot hasn't surfaced a last price for it this sweep — the
        // fix for the regime-blind book stranding in cash. Held-only names keep the external price only.
        var px = prices
        for c in universe where (px[c.symbol] ?? 0) <= 0 {
            if let rp = c.referencePrice, rp > 0 { px[c.symbol] = rp }
        }

        let equity = state.equity(prices: px)

        // Layer 2 — rank priced candidates by conviction, take top-N. A Gate-5 `.exit` name is never a
        // candidate, so it can't consume a slot or be re-bought (the held side is forced out below).
        let priced: [AllocationCandidate] = universe.filter {
            (px[$0.symbol] ?? 0) > 0 && exitDecisions[$0.symbol] != .exit
        }
        let ranked: [AllocationCandidate] = priced.sorted { lhs, rhs in
            lhs.conviction != rhs.conviction ? lhs.conviction > rhs.conviction : lhs.symbol < rhs.symbol
        }
        let candidates: [AllocationCandidate] = Array(ranked.prefix(config.topN))

        // Layer 3 — weights as a fraction of *total equity*, summing to ≤ `exposure`.
        let weights = targetWeights(candidates: candidates, exposure: exposure, config: config)
        // Cash target reflects what's actually deployed, not just the exposure ceiling — a regime-blind
        // book that mirrors under-deploying suggested weights legitimately holds the residual in cash.
        let cashTarget = equity * (1 - min(exposure, weights.reduce(0, +)))

        // Build target shares (lot-rounded) for the names we want to hold.
        var targetShares: [String: Double] = [:]
        for (row, weight) in zip(candidates, weights) {
            guard let price = px[row.symbol], price > 0 else { continue }
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
            // A held name with no live/reference price (it dropped out of the candidate set) falls back to
            // its avg cost so it can still be sized down/exited instead of being stranded — mirroring
            // `PaperPortfolioState.equity`. A candidate-only name keeps the strict price guard (no position
            // ⇒ no fallback), so `nameWithoutAPriceIsSkipped` is unchanged.
            let price = (px[symbol] ?? 0) > 0 ? px[symbol]! : (state.positions[symbol]?.avgCost ?? 0)
            guard price > 0 else { continue } // can't value → skip
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

    /// The responsive **defense** pass, run on every warm sweep (cut risk fast — Zweig; defense before
    /// offense — Marks). It handles two verdict-driven, sell-only cases without waiting for a boundary:
    ///   • `.exit` (any stance) — liquidate the name in full (broken thesis, failed gate, governance, or
    ///     price past IV). A forced exit overrides the anti-churn band.
    ///   • `.trim` **in risk-off only** — reduce the name toward its risk-off target (the tighter of the
    ///     exposure band and the per-name cap), so a lone/over-concentrated holding de-risks now rather
    ///     than sitting at full size until the next session boundary. Off risk-off a `.trim` is left to
    ///     the boundary-gated `plan`, so the two passes never double-count the de-risking.
    /// A held name with no actionable verdict is left ALONE — this pass never rebalances the whole book or
    /// drops a name for falling out of the buy set. `names` supplies display labels (falls back to ticker).
    static func exitPlan(state: PaperPortfolioState,
                         prices: [String: Double],
                         exitDecisions: [String: ExitAction],
                         regime: RegimeRead?,
                         names: [String: String] = [:],
                         config: AllocationConfig = .standard) -> AllocationPlan {
        let score = regime?.score ?? 0
        let stance = regime?.stance ?? .neutral
        let exposure = config.exposure(forScore: score)
        let equity = state.equity(prices: prices)
        let cashTarget = equity * (1 - exposure)
        // A held name often has no fresh screener price (it isn't a buy candidate in risk-off); fall back
        // to its avg cost so it can still be sized down — mirroring `PaperPortfolioState.equity`.
        func price(_ symbol: String) -> Double? {
            if let p = prices[symbol], p > 0 { return p }
            if let c = state.positions[symbol]?.avgCost, c > 0 { return c }
            return nil
        }

        var lines: [AllocationLine] = []
        for (symbol, position) in state.positions {
            let action = exitDecisions[symbol]
            let isExit = action == .exit
            let isRiskOffTrim = action == .trim && stance == .riskOff
            guard isExit || isRiskOffTrim else { continue }              // only actionable defense verdicts
            guard let price = price(symbol), price > 0 else { continue } // can't value → skip
            let current = position.shares
            guard current > 0 else { continue }

            if isExit {
                lines.append(AllocationLine(
                    symbol: symbol, name: names[symbol] ?? symbol, side: .sell,
                    currentShares: current, targetShares: 0, deltaShares: -current,
                    price: price, estValue: current * price, targetWeight: 0,
                    rationale: "Gate-5: \(symbol) flagged for exit — full sale."))
                continue
            }

            // Risk-off trim: target the tighter of the exposure band and the per-name cap, lot-rounded.
            let targetWeight = Swift.min(exposure, config.effectivePerNameCap)
            let lot = Double(config.execution.lotSize)
            let targetByWeight = ((targetWeight * equity) / (price * lot)).rounded(.down) * lot
            let target = Swift.min(current, Swift.max(0, targetByWeight))
            let delta = target - current
            if abs(delta) * price < config.rebalanceBandPct * equity { continue } // anti-churn
            if abs(delta) < lot { continue }                                       // sub-lot residue
            lines.append(AllocationLine(
                symbol: symbol, name: names[symbol] ?? symbol, side: .sell,
                currentShares: current, targetShares: target, deltaShares: delta,
                price: price, estValue: abs(delta) * price, targetWeight: targetWeight,
                rationale: "\(stance.rawValue): trim \(symbol) toward its \(String(format: "%.0f%%", targetWeight * 100)) risk-off target."))
        }
        lines.sort { $0.estValue > $1.estValue }                          // larger liquidations first
        return AllocationPlan(stance: stance, score: score, targetExposure: exposure,
                              equity: equity, cashTarget: cashTarget, lines: lines)
    }

    // MARK: - Layer 3 weighting

    /// Per-name weights as a fraction of total equity, summing to `exposure`: take each candidate's raw
    /// sizing signal (`config.sizingBasis`), normalise to `exposure`, then water-fill under
    /// `effectivePerNameCap` so no name dominates and at least `minPositions` names share the book once
    /// exposure is high enough.
    private static func targetWeights(candidates: [AllocationCandidate], exposure: Double,
                                      config: AllocationConfig) -> [Double] {
        guard !candidates.isEmpty, exposure > 0 else {
            return Array(repeating: 0, count: candidates.count)
        }

        // Regime-blind books (RiBeTS) mirror the selection engine's own per-name weights verbatim — same
        // level AND tilt. `fixedExposure` (here `exposure`) is a CEILING, not a forced target: deploy the
        // suggested weights as-is, scaling the vector down only if it would over-deploy past the ceiling
        // (never inflate, never flatten). The engine already applied its per-name/sector/liquidity caps,
        // so the allocator's diversification cap is not re-applied. An all-zero vector (no suggested-weight
        // signal) falls through to the conviction-Kelly path below.
        if config.fixedExposure != nil, config.sizingBasis == .suggestedWeight {
            let mirrored = candidates.map { Swift.max($0.suggestedWeight, 0) }
            let sum = mirrored.reduce(0, +)
            if sum > exposure { return mirrored.map { $0 / sum * exposure } }
            if sum > 0 { return mirrored }
        }

        let cap = config.effectivePerNameCap

        // Raw sizing signal per name. `.suggestedWeight` honours the engine's own target verbatim; a
        // name missing it (≤ 0) falls back to conviction-Kelly so it's never silently dropped. The
        // proportion is what matters — the vector is renormalised to `exposure` below.
        let raw = candidates.map { rawSignal(for: $0, config: config) }
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

    /// The raw (pre-normalisation) sizing signal for one candidate under `config.sizingBasis`.
    /// `.suggestedWeight` honours the engine's own per-name weight; when that's ≤ 0 (or the basis is
    /// `.conviction`) it falls back to the fractional-Kelly damp of conviction, `convictionᵏ`, k < 1.
    private static func rawSignal(for c: AllocationCandidate, config: AllocationConfig) -> Double {
        if config.sizingBasis == .suggestedWeight, c.suggestedWeight > 0 { return c.suggestedWeight }
        return pow(max(c.conviction, 0.0001), config.kellyFraction)
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
