import Foundation
import Testing
@testable import Autoscreener

/// Tests the pure regime-gated, recommendation-driven, risk-capped allocator. The buy universe is the
/// gate-filtered Tier-A picks (flattened to `AllocationCandidate`); names are sized by the engine's own
/// `suggestedWeight` (default) or fractional-Kelly conviction, ranked by conviction.
@Suite struct AllocationEngineTests {

    // MARK: - Builders

    private func read(_ stance: RegimeStance, score: Double) -> RegimeRead {
        RegimeRead(stance: stance, score: score,
                   factors: [RegimeFactor(kind: .breadth, signal: .neutral, detail: "test")],
                   asOf: "2026-06-12", valuationCapped: false)
    }

    private let seed = PaperPortfolioState.seed   // 100M cash, no positions

    // MARK: - Layer 1: regime → exposure

    @Test func riskOffParksMostOfTheBookInCash() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOff, score: -0.9), prices: prices)
        #expect(plan.targetExposure <= 0.30)        // risk-off band
        #expect(plan.cashTarget >= plan.equity * 0.70)
    }

    @Test func riskOnDeploysHeavilyButNeverFully() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices)
        #expect(plan.targetExposure > 0.60)
        #expect(plan.targetExposure <= 0.95)        // survive-first cash floor
        #expect(plan.cashTarget >= plan.equity * 0.05 - 1)
    }

    @Test func nilRegimeFallsBackToNeutralBand() {
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, candidates: rows, regime: nil, prices: prices)
        #expect(plan.stance == .neutral)
        #expect(plan.targetExposure >= 0.50 && plan.targetExposure <= 0.60)
    }

    @Test func regimeBlindConfigIgnoresTheScoreAndDeploysFully() {
        // The RiBeTS book (`.regimeBlind`) overrides Layer 1: a deeply risk-off regime that parks the
        // regime-aware RAPaTS book in cash still deploys the blind book toward its suggested weights.
        let (rows, prices) = scoredUniverse(8)
        let riskOff = read(.riskOff, score: -0.9)
        let blind = AllocationEngine.plan(state: seed, candidates: rows, regime: riskOff,
                                          prices: prices, config: .regimeBlind)
        let aware = AllocationEngine.plan(state: seed, candidates: rows, regime: riskOff,
                                          prices: prices, config: .standard)

        #expect(blind.targetExposure == 1.0)            // fixed full deployment, regardless of risk-off
        #expect(aware.targetExposure <= 0.30)           // regime-aware parks in cash
        #expect(blind.cashTarget < aware.cashTarget)    // blind keeps far less cash

        let buys: (AllocationPlan) -> Double = { $0.lines.filter { $0.side == .buy }.reduce(0) { $0 + $1.estValue } }
        #expect(buys(blind) > buys(aware))              // and actually buys more
    }

    // MARK: - Layer 3: sizing, caps, diversification

    @Test func noNameExceedsThePerNameCap() {
        let (rows, prices) = scoredUniverse(20)
        let cfg = AllocationConfig.standard
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        for line in plan.lines where line.side == .buy {
            #expect(line.targetWeight <= cfg.effectivePerNameCap + 1e-6)
        }
    }

    @Test func fullDeploymentHonoursPositionCountFloor() {
        let (rows, prices) = scoredUniverse(20)
        let cfg = AllocationConfig.standard
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let bought = plan.lines.filter { $0.side == .buy }
        #expect(bought.count >= cfg.minPositions)   // ≥6 names share the deployed book
    }

    // MARK: - Sizing basis

    @Test func sizesProportionalToSuggestedWeight() {
        // Default basis honours the engine's own weight verbatim. AAA has the LOWER conviction (so it
        // ranks second) but the HIGHER suggestedWeight — proving the size tracks suggestedWeight, not
        // conviction or rank.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA Co", conviction: 0.5, suggestedWeight: 0.30),
            AllocationCandidate(symbol: "BBB", name: "BBB Co", conviction: 0.9, suggestedWeight: 0.10),
        ]
        let prices = ["AAA": 1_000.0, "BBB": 1_000.0]
        var cfg = AllocationConfig.standard
        cfg.perNameCap = 1.0; cfg.minPositions = 1   // disable caps to isolate the proportions
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let aaa = plan.lines.first { $0.symbol == "AAA" }?.targetWeight ?? 0
        let bbb = plan.lines.first { $0.symbol == "BBB" }?.targetWeight ?? 0
        #expect(aaa > bbb)                           // bigger suggestedWeight → bigger position
        #expect(abs(aaa / bbb - 3.0) < 0.2)          // 0.30 / 0.10 ≈ 3:1
    }

    @Test func regimeBlindMirrorsSuggestedWeightsVerbatim() {
        // The RiBeTS book sizes each name at the selection engine's own `suggestedWeight` — same level
        // AND tilt. `fixedExposure` is a ceiling, not a forced 100% deployment, so the per-name
        // diversification cap must NOT flatten the tilt: AAA's 3× weight survives verbatim.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA Co", conviction: 0.9, suggestedWeight: 0.30),
            AllocationCandidate(symbol: "BBB", name: "BBB Co", conviction: 0.8, suggestedWeight: 0.10),
            AllocationCandidate(symbol: "CCC", name: "CCC Co", conviction: 0.7, suggestedWeight: 0.10),
            AllocationCandidate(symbol: "DDD", name: "DDD Co", conviction: 0.6, suggestedWeight: 0.10),
        ]
        let prices = Dictionary(uniqueKeysWithValues: candidates.map { ($0.symbol, 1_000.0) })
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOff, score: -0.9), prices: prices,
                                         config: .regimeBlind)
        let weight: (String) -> Double = { sym in plan.lines.first { $0.symbol == sym }?.targetWeight ?? 0 }
        #expect(abs(weight("AAA") - 0.30) < 0.01)        // verbatim, not flattened to the ~0.167 cap
        #expect(abs(weight("AAA") / weight("BBB") - 3.0) < 0.2)   // 0.30 / 0.10 tilt preserved
    }

    @Test func regimeBlindHoldsCashWhenSuggestedWeightsUnderDeploy() {
        // The suggested weights sum to 0.60 — RiBeTS deploys exactly that and parks the remaining 40% in
        // cash. `fixedExposure` is a ceiling, so it never inflates the weights to fill the book.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA Co", conviction: 0.9, suggestedWeight: 0.30),
            AllocationCandidate(symbol: "BBB", name: "BBB Co", conviction: 0.8, suggestedWeight: 0.10),
            AllocationCandidate(symbol: "CCC", name: "CCC Co", conviction: 0.7, suggestedWeight: 0.10),
            AllocationCandidate(symbol: "DDD", name: "DDD Co", conviction: 0.6, suggestedWeight: 0.10),
        ]
        let prices = Dictionary(uniqueKeysWithValues: candidates.map { ($0.symbol, 1_000.0) })
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOff, score: -0.9), prices: prices,
                                         config: .regimeBlind)
        #expect(abs(plan.cashTarget - plan.equity * 0.40) < plan.equity * 0.02)
    }

    @Test func suggestedWeightZeroFallsBackToConviction() {
        // A candidate with no suggestedWeight is sized on conviction-Kelly instead of being dropped.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA Co", conviction: 4, suggestedWeight: 0),
            AllocationCandidate(symbol: "BBB", name: "BBB Co", conviction: 1, suggestedWeight: 0),
        ]
        let prices = ["AAA": 1_000.0, "BBB": 1_000.0]
        var cfg = AllocationConfig.standard
        cfg.perNameCap = 1.0; cfg.minPositions = 1
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let aaa = plan.lines.first { $0.symbol == "AAA" }?.targetWeight ?? 0
        let bbb = plan.lines.first { $0.symbol == "BBB" }?.targetWeight ?? 0
        #expect(aaa > bbb)                           // √4 / √1 = 2× before normalisation
        #expect(abs(aaa / bbb - 2.0) < 0.2)
    }

    @Test func fractionalKellyDampsTheTopNameVsRawProportional() {
        // Conviction basis: the top name has 4× the conviction of the rest. √-damping must pull its
        // weight well below the 57% a raw-proportional split would hand it.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 4, suggestedWeight: 0),
            AllocationCandidate(symbol: "BBB", name: "BBB", conviction: 1, suggestedWeight: 0),
            AllocationCandidate(symbol: "CCC", name: "CCC", conviction: 1, suggestedWeight: 0),
            AllocationCandidate(symbol: "DDD", name: "DDD", conviction: 1, suggestedWeight: 0),
        ]
        let prices = Dictionary(uniqueKeysWithValues: candidates.map { ($0.symbol, 1_000.0) })
        var cfg = AllocationConfig.standard
        cfg.sizingBasis = .conviction
        cfg.perNameCap = 1.0; cfg.minPositions = 1   // disable caps to isolate the damping
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: prices, config: cfg)
        let top = plan.lines.first { $0.symbol == "AAA" }
        #expect(top != nil)
        let rawShare = 4.0 / (4.0 + 1 + 1 + 1)      // 0.571 of the deployed sleeve
        // √-damped: √4 / (√4 + 3·√1) = 2/5 = 0.40 of the sleeve → well under raw.
        #expect((top!.targetWeight / plan.targetExposure) < rawShare - 0.1)
    }

    @Test func lotRoundingProducesWholeLots() {
        let (rows, prices) = scoredUniverse(8, price: 333)   // awkward price forces rounding
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 0.8), prices: prices)
        for line in plan.lines {
            #expect(line.targetShares.truncatingRemainder(dividingBy: 100) == 0)
            #expect(abs(line.deltaShares).truncatingRemainder(dividingBy: 100) == 0)
        }
    }

    @Test func emptyUniverseProducesNoBuys() {
        let plan = AllocationEngine.plan(state: seed, candidates: [],
                                         regime: read(.riskOn, score: 1.0), prices: [:])
        #expect(plan.lines.allSatisfy { $0.side == .sell })
        #expect(plan.lines.isEmpty)
    }

    @Test func nameWithoutAPriceIsSkipped() {
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1),
            AllocationCandidate(symbol: "NPR", name: "No Price", conviction: 1, suggestedWeight: 0.1),
        ]
        let prices = ["AAA": 1_000.0]   // NPR absent
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: prices)
        #expect(plan.lines.contains { $0.symbol == "AAA" })
        #expect(!plan.lines.contains { $0.symbol == "NPR" })
    }

    @Test func aCandidateIsPricedFromItsReferencePriceWhenTheMapHasNone() {
        // The screener snapshot carried no last price for AAA this sweep, but the recommendation knows the
        // price the selection engine valued it at. The allocator must still size and buy it from that
        // reference price — otherwise a fully-recommended name is stranded unbought (the RiBeTS bug).
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1,
                                referencePrice: 1_000),
        ]
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: [:])   // empty price map
        let line = plan.lines.first { $0.symbol == "AAA" }
        #expect(line?.side == .buy)
        #expect(line?.price == 1_000)
    }

    @Test func aLiveScreenerPriceIsPreferredOverTheReferencePrice() {
        // When both are present the live price wins — the reference price is only a fallback, never an
        // override of fresher market data.
        let candidates = [
            AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1,
                                referencePrice: 1_000),
        ]
        let plan = AllocationEngine.plan(state: seed, candidates: candidates,
                                         regime: read(.riskOn, score: 1.0), prices: ["AAA": 1_200])
        #expect(plan.lines.first { $0.symbol == "AAA" }?.price == 1_200)
    }

    @Test func subBandDeltaIsSuppressed() {
        // Already holding almost exactly the target → the tiny top-up is below the
        // rebalance band and must not generate a line.
        let candidates = [AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1)]
        let prices = ["AAA": 1_000.0]
        var state = PaperPortfolioState.seed
        var cfg = AllocationConfig.standard
        cfg.execution = ExecutionModel(lotSize: 100, buyFeePct: 0, sellFeePct: 0,
                                       slippagePct: 0, fillAt: .nextOpen, araArbLimit: 0.25)
        // Neutral, single name → weight is the per-name cap. Seed the holding at exactly that capped
        // target so the recomputed delta is ~0 and falls inside the rebalance band.
        let target = cfg.effectivePerNameCap * state.equity(prices: prices) / 1_000
        let lots = (target / 100).rounded(.down) * 100
        state.apply(side: .buy, symbol: "AAA", shares: lots, price: 1_000, feePct: 0,
                    date: Date(timeIntervalSince1970: 0))
        let plan = AllocationEngine.plan(state: state, candidates: candidates,
                                         regime: read(.neutral, score: 0), prices: prices, config: cfg)
        #expect(!plan.lines.contains { $0.symbol == "AAA" })
    }

    @Test func droppedNameIsFullyExited() {
        // Hold a name that isn't a candidate any more → expect a full sell.
        let candidates = [AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1)]
        let prices = ["AAA": 1_000.0, "OLD": 2_000.0]
        var state = PaperPortfolioState.seed
        state.positions["OLD"] = PaperPosition(shares: 5_000, avgCost: 1_800)
        let plan = AllocationEngine.plan(state: state, candidates: candidates,
                                         regime: read(.neutral, score: 0), prices: prices)
        let exit = plan.lines.first { $0.symbol == "OLD" }
        #expect(exit?.side == .sell)
        #expect(exit?.targetShares == 0)
        #expect(exit?.deltaShares == -5_000)
    }

    // MARK: - Gate-5 exit decisions feed the allocator

    @Test func exitFlaggedNameIsFullySoldEvenWhenStillHighConviction() {
        // SYM00 is the top-conviction candidate (normally a large buy) AND already held.
        // A Gate-5 `.exit` flag must override conviction: sell it in full, never add.
        let (rows, prices) = scoredUniverse(8)
        var state = PaperPortfolioState.seed
        state.positions["SYM00"] = PaperPosition(shares: 3_000, avgCost: 900)
        let plan = AllocationEngine.plan(state: state, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices,
                                         exitDecisions: ["SYM00": .exit])
        let line = plan.lines.first { $0.symbol == "SYM00" }
        #expect(line?.side == .sell)
        #expect(line?.targetShares == 0)
        #expect(line?.deltaShares == -3_000)
        #expect(!plan.lines.contains { $0.symbol == "SYM00" && $0.side == .buy })
    }

    @Test func exitFlaggedNameIsBlockedFromReentry() {
        // Not held, top conviction — without a flag it would be the first buy. `.exit` blocks it.
        let (rows, prices) = scoredUniverse(8)
        let plan = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices,
                                         exitDecisions: ["SYM00": .exit])
        #expect(!plan.lines.contains { $0.symbol == "SYM00" })          // never re-bought
        #expect(plan.lines.contains { $0.symbol == "SYM01" && $0.side == .buy })  // others unaffected
    }

    @Test func trimFlaggedNameIsNotAddedTo() {
        // Hold a tiny slice of the top name; conviction wants far more. `.trim` caps at current,
        // so the would-be top-up is suppressed (control proves it would otherwise buy).
        let (rows, prices) = scoredUniverse(8)
        var state = PaperPortfolioState.seed
        state.positions["SYM00"] = PaperPosition(shares: 200, avgCost: 1_000)
        let control = AllocationEngine.plan(state: state, candidates: rows,
                                            regime: read(.riskOn, score: 1.0), prices: prices)
        let plan = AllocationEngine.plan(state: state, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices,
                                         exitDecisions: ["SYM00": .trim])
        #expect(control.lines.contains { $0.symbol == "SYM00" && $0.side == .buy })  // would add
        #expect(!plan.lines.contains { $0.symbol == "SYM00" && $0.side == .buy })    // trim caps it
    }

    @Test func trimFlaggedNameStillRebalancesDown() {
        // Hold far MORE than the natural target. `.trim` caps at current (min), so it must NOT
        // freeze the position — the natural reduction toward target still happens.
        let (rows, prices) = scoredUniverse(8)
        var state = PaperPortfolioState.seed
        state.positions["SYM07"] = PaperPosition(shares: 30_000, avgCost: 1_000)
        let plan = AllocationEngine.plan(state: state, candidates: rows,
                                         regime: read(.neutral, score: 0), prices: prices,
                                         exitDecisions: ["SYM07": .trim])
        let line = plan.lines.first { $0.symbol == "SYM07" }
        #expect(line?.side == .sell)
        #expect((line?.targetShares ?? .infinity) < 30_000)
    }

    @Test func holdFlaggedNamesMatchTheBaselinePlan() {
        // `.hold` (and, by extension, the default empty map) must be byte-for-byte the baseline behaviour.
        let (rows, prices) = scoredUniverse(12)
        let base = AllocationEngine.plan(state: seed, candidates: rows,
                                         regime: read(.riskOn, score: 1.0), prices: prices)
        let withHolds = AllocationEngine.plan(state: seed, candidates: rows,
                                              regime: read(.riskOn, score: 1.0), prices: prices,
                                              exitDecisions: ["SYM00": .hold, "SYM03": .hold])
        #expect(base.lines.map(\.id) == withHolds.lines.map(\.id))
        #expect(base.lines.map(\.deltaShares) == withHolds.lines.map(\.deltaShares))
    }

    @Test func exitOverridesTheAntiChurnBand() {
        // A held slice too small to trip the rebalance band is normally left alone; a Gate-5 `.exit`
        // forces the full sale anyway (a broken thesis isn't churn).
        let candidates = [AllocationCandidate(symbol: "AAA", name: "AAA", conviction: 1, suggestedWeight: 0.1)]
        let prices = ["AAA": 1_000.0, "TINY": 1_000.0]
        var state = PaperPortfolioState.seed
        state.positions["TINY"] = PaperPosition(shares: 200, avgCost: 1_000)   // 200k ≪ 2% of ~100M
        let control = AllocationEngine.plan(state: state, candidates: candidates,
                                            regime: read(.neutral, score: 0), prices: prices)
        #expect(!control.lines.contains { $0.symbol == "TINY" })               // sub-band → suppressed
        let plan = AllocationEngine.plan(state: state, candidates: candidates,
                                         regime: read(.neutral, score: 0), prices: prices,
                                         exitDecisions: ["TINY": .exit])
        let exit = plan.lines.first { $0.symbol == "TINY" }
        #expect(exit?.side == .sell)
        #expect(exit?.targetShares == 0)
        #expect(exit?.deltaShares == -200)
    }

    // MARK: - exitPlan: risk-off de-risks a flagged held name continuously (defense pass)

    @Test func riskOffTrimReducesALoneConcentratedHeldName() {
        // The live RAPaTS bug: a single over-concentrated holding flagged `.trim` in risk-off. The
        // continuous defense pass must reduce it toward the risk-off band, not wait for a boundary.
        var state = PaperPortfolioState.seed
        state.positions["BMRI"] = PaperPosition(shares: 4_000, avgCost: 4_162)   // ~16.6M, the only position
        let plan = AllocationEngine.exitPlan(state: state, prices: ["BMRI": 4_200],
                                             exitDecisions: ["BMRI": .trim],
                                             regime: read(.riskOff, score: -0.9))
        let line = plan.lines.first { $0.symbol == "BMRI" }
        #expect(line?.side == .sell)
        #expect((line?.targetShares ?? .infinity) < 4_000)        // trimmed toward the band
        #expect(line?.targetShares ?? -1 >= 0)                    // never oversells
    }

    @Test func riskOffTrimSizesAHeldNameThatHasNoLivePrice() {
        // A held-only name (not a buy candidate in risk-off) often has no fresh screener price. It must
        // still be sizeable via the avgCost fallback, or the trim would be silently skipped.
        var state = PaperPortfolioState.seed
        state.positions["BMRI"] = PaperPosition(shares: 4_000, avgCost: 4_162)
        let plan = AllocationEngine.exitPlan(state: state, prices: [:],   // no live price for BMRI
                                             exitDecisions: ["BMRI": .trim],
                                             regime: read(.riskOff, score: -0.9))
        #expect(plan.lines.contains { $0.symbol == "BMRI" && $0.side == .sell })
    }

    @Test func neutralLeavesTrimFlaggedNamesToTheBoundaryPlan() {
        // Off risk-off, the defense pass stays exit-only: a `.trim` is the boundary `plan`'s job, so the
        // continuous pass must not act on it (no double-counting of the de-risking).
        var state = PaperPortfolioState.seed
        state.positions["BMRI"] = PaperPosition(shares: 4_000, avgCost: 4_162)
        let plan = AllocationEngine.exitPlan(state: state, prices: ["BMRI": 4_200],
                                             exitDecisions: ["BMRI": .trim],
                                             regime: read(.neutral, score: 0))
        #expect(!plan.lines.contains { $0.symbol == "BMRI" })
    }

    @Test func riskOffExitPassStillIgnoresHeldNamesWithNoVerdict() {
        // The risk-off trim is verdict-driven: an unflagged holding is left alone even in risk-off, so the
        // defense pass never silently rebalances the whole book.
        var state = PaperPortfolioState.seed
        state.positions["BMRI"] = PaperPosition(shares: 4_000, avgCost: 4_162)
        let plan = AllocationEngine.exitPlan(state: state, prices: ["BMRI": 4_200],
                                             exitDecisions: [:],
                                             regime: read(.riskOff, score: -0.9))
        #expect(!plan.lines.contains { $0.symbol == "BMRI" })
    }

    // MARK: - Helpers

    /// `n` ranked candidates SYM00…, strictly descending conviction (index 0 highest), each priced at
    /// `price`. `suggestedWeight` tracks conviction so the default sizing basis has a positive signal.
    private func scoredUniverse(_ n: Int, price: Double = 1_000)
        -> (candidates: [AllocationCandidate], prices: [String: Double]) {
        var candidates: [AllocationCandidate] = []
        var prices: [String: Double] = [:]
        for i in 0..<n {
            let sym = String(format: "SYM%02d", i)
            let conviction = Double(n - i)           // strictly descending, positive
            candidates.append(AllocationCandidate(symbol: sym, name: "\(sym) Co",
                                                  conviction: conviction, suggestedWeight: conviction))
            prices[sym] = price
        }
        return (candidates, prices)
    }
}
