import Foundation

private func pctString(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

// MARK: - Gate-5 — exit / sell discipline
//
// The selection engine (`StockSelectionEngine.run`) is BUY-only: universe → ranked recommendations.
// Gate-5 is its mirror image — holdings → sell/trim/hold decisions — and is built as a SIBLING use
// case rather than a stage inside `run()` (different input, output, and reason-to-change: SRP/ISP).
// It deliberately REUSES the buy-side policy: each held name is re-run through its own
// `SelectionProfile` hard gates, the Gate-2 `governanceVeto`, and its valuator's CURRENT margin of
// safety. "Would this name fail to be bought today — and badly?" is the sell question.
//
// The sell taxonomy is grounded in three frameworks the app already encodes on the buy side:
//   • Fisher (Common Stocks and Uncommon Profits, "When to Sell"): the only valid reasons to sell are
//     a broken thesis or a deteriorated business — NOT a risen price, a drawdown, or a temporary miss.
//   • Graham (The Intelligent Investor, Mr. Market): sell when price exceeds intrinsic value.
//   • Howard Marks: play defense when the cycle turns.
// Fisher and Graham only conflict if you sell the instant the margin of safety shrinks. They are
// reconciled by a HYSTERESIS band: you BUY at `policy.minMarginOfSafety` (positive); you SELL only at
// `config.exit.exitMarginFloor` (negative — price has run PAST a re-computed IV). The band between is
// HOLD. Because the valuator recomputes IV from CURRENT fundamentals every review, a compounding
// winner earns a higher IV and is not sold on price alone — exactly Fisher's rule.
//
// Pure and clock-free, like the buy engine: "now" enters only at the provider edge (which already
// injects the clock when it assembles `GovernanceAssessment`). Phase 1 re-evaluates CURRENT data only;
// a persisted entry-thesis snapshot (true "thesis-was-wrong" / "IV collapsed since entry") is Phase 2.

// MARK: - Boundary DTOs

/// A currently-held position, in a form convenient to this use case (Clean Architecture: the inner
/// layer dictates the shape). Infrastructure position types (`PaperPosition`, harness `Lot`) are
/// mapped to this at the edge. `avgCost` is carried for the audit only — by Fisher's discipline the
/// SELL decision never depends on it (a paper loss is not a reason to sell).
struct HeldPosition: Sendable, Equatable {
    let ticker: Ticker
    let shares: Double
    let avgCost: Double
}

/// What Gate-5 decides for one held name.
enum ExitAction: String, Sendable {
    case hold      // thesis intact — keep the full position
    case trim      // de-risk the size (regime), but the name still belongs in the book
    case exit      // sell in full — thesis broken / business deteriorated / price past IV
}

/// The exit decision for one held name, carrying the same present-only audit trail style as
/// `Recommendation.audit` so the reasoning is transparent and re-traceable.
struct ExitDecision: Sendable {
    let ticker: Ticker
    let action: ExitAction
    let reason: String        // one-line headline, e.g. "Forensic: CFO persistently << NI"
    let audit: [String]       // the full reviewed trail (gates, governance, MoS-vs-floor, verdict)
}

// MARK: - Holdings gateway (DIP)

/// Source of currently-held positions for the Gate-5 review. The use case owns this protocol; the
/// outer layer implements it (the paper-trading store today, a real brokerage later) — so source-code
/// dependencies still point inward, mirroring `DataProvider`.
protocol HoldingsProvider: Sendable {
    func heldPositions() async throws -> [HeldPosition]
}

// MARK: - The evaluator (pure)

/// Decides hold / trim / exit for ONE held name against its current data and the prevailing regime
/// policy. Pure: no I/O, no clock, no shared state — every input is passed in, so it is trivially and
/// deterministically testable (the buy engine's own discipline).
struct ExitEvaluator: Sendable {
    let config: SelectionConfig
    /// Same archetype seam as the engine (DIP): a held bank is reviewed with the financial profile's
    /// gates/valuator, an industrial with the Graham path. Defaults to the engine's own selector so the
    /// two stay in lock-step.
    let profileSelector: @Sendable (SecurityData) -> SelectionProfile

    init(config: SelectionConfig = .balanced,
         profileSelector: (@Sendable (SecurityData) -> SelectionProfile)? = nil) {
        self.config = config
        self.profileSelector = profileSelector ?? { StockSelectionEngine.defaultProfile(for: $0, config: config) }
    }

    func evaluate(_ position: HeldPosition, data s: SecurityData, policy: RegimePolicy) -> ExitDecision {
        let profile = profileSelector(s)
        var audit = ["review \(s.ticker): price \(s.price) vs cost \(position.avgCost)"]

        func decide(_ action: ExitAction, _ reason: String) -> ExitDecision {
            ExitDecision(ticker: s.ticker, action: action, reason: reason, audit: audit)
        }

        // TIER 1a — DETERIORATION. A buy-side hard gate now fails on current data: the business is no
        // longer the one we bought (Forensic = earnings quality broke / Lynch "the story changed";
        // Solvency/CapitalStrength = balance sheet weakened; DataIntegrity = the record went dark).
        if config.exit.honorHardGates {
            for g in profile.gates {
                if case let .fail(reason) = g.evaluate(s, config: config, policy: policy) {
                    audit.append("✗ \(g.name): \(reason)")
                    return decide(.exit, "\(g.name): \(reason)")
                }
            }
            audit.append("✓ gates [\(profile.archetype.rawValue)]")
        }

        // TIER 1b — INTEGRITY. The Gate-2 insider-selling / dilution veto fires on the current flags.
        // Fisher's Point-15 override: an integrity breach is an immediate sell, whatever the price.
        if config.exit.honorGovernanceVeto, let gov = s.governance,
           let reason = governanceVeto(gov, config: config.governance) {
            audit.append("✗ Governance: \(reason)")
            return decide(.exit, "Governance: \(reason)")
        }

        // TIER 2 — VALUATION (Graham). Price has run PAST the re-computed intrinsic value by the exit
        // band. Asymmetric vs the buy MoS floor on purpose (Fisher): a rising price alone is not a
        // sell, so this fires only at a NEGATIVE margin. A loss-maker / no-value name computes IV 0 ⇒
        // MoS −1 ⇒ exit, symmetric with the buy side that would never have bought it.
        let mos = profile.valuator.marginOfSafety(s, config: config)
        audit.append("MoS \(pctString(mos)) vs exit floor \(pctString(config.exit.exitMarginFloor))")
        if mos <= config.exit.exitMarginFloor {
            return decide(.exit, "price ran past intrinsic value (MoS \(pctString(mos)))")
        }

        // TIER 3 — REGIME (Marks). Deep risk-off has collapsed target exposure to zero ⇒ trim. Normal
        // risk-off SIZING is the paper-trading AllocationEngine's job (exposure bands); this is only
        // the floor case, so Gate-5 never double-counts that de-risking.
        if config.exit.regimeTrimOnRiskOff, policy.maxTotalExposure <= 0 {
            audit.append("regime \(policy.regime.rawValue): target exposure 0 → trim")
            return decide(.trim, "risk-off de-risking")
        }

        // TIER 4 — HOLD. The thesis is intact. Fisher's explicit NON-triggers land here as a
        // first-class, audited decision: a price drawdown, a temporary earnings dip, or market fear are
        // NOT reasons to sell. (`avgCost` was never consulted.)
        audit.append("thesis intact → hold")
        return decide(.hold, "thesis intact")
    }
}

// MARK: - The reviewer (sibling use case)

/// Reviews every held position against current data and the prevailing regime — the Gate-5 analogue
/// of `StockSelectionEngine.run()`. Composes the holdings gateway, the shared `DataProvider`, and the
/// pure `ExitEvaluator`; the regime is read once per review, exactly as the buy engine reads it once.
struct PositionReviewer: Sendable {
    let holdings: HoldingsProvider
    let provider: DataProvider
    let evaluator: ExitEvaluator

    init(holdings: HoldingsProvider, provider: DataProvider, evaluator: ExitEvaluator? = nil) {
        self.holdings = holdings
        self.provider = provider
        self.evaluator = evaluator ?? ExitEvaluator()
    }

    func review() async throws -> [ExitDecision] {
        let policy = RegimeAssessor.assess(try await provider.marketContext(), config: evaluator.config)
        var decisions: [ExitDecision] = []
        for position in try await holdings.heldPositions() {
            let data = try await provider.data(for: position.ticker)
            decisions.append(evaluator.evaluate(position, data: data, policy: policy))
        }
        return decisions
    }
}
