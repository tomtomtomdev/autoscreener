import Foundation

// MARK: - The read (output)

/// How aggressive to be given where the IDX sits in its own cycle — the regime
/// "read" `idx-investing-research.md` §3 asks for. Deliberately a *posture*, not
/// a forecast: per Howard Marks you can gauge where the pendulum is, never
/// predict where it swings next ("You can't predict. You can prepare.").
nonisolated enum RegimeStance: String, Sendable, CaseIterable {
    case riskOn = "Risk-on"
    case neutral = "Neutral"
    case riskOff = "Risk-off"

    /// Marks's "aggressiveness dial" framing — what the posture implies for sizing.
    var guidance: String {
        switch self {
        case .riskOn:
            "Conditions favour offence — the distribution of outcomes skews favourable. Press good ideas, but never go all-in."
        case .neutral:
            "Balanced — the cycle gives no edge either way. Size normally and stay selective."
        case .riskOff:
            "Conditions favour defence — the distribution skews unfavourable. Protect capital and keep dry powder."
        }
    }
}

/// One factor's contribution. The numeric `vote` (+1 / 0 / −1) is what the
/// synthesiser sums; the case carries the meaning.
nonisolated enum RegimeSignal: String, Sendable {
    case riskOn = "Risk-on"
    case neutral = "Neutral"
    case riskOff = "Risk-off"

    var vote: Int {
        switch self {
        case .riskOn: 1
        case .neutral: 0
        case .riskOff: -1
        }
    }
}

/// A single named input to the read: its signal plus a one-line rationale. Kept
/// transparent on purpose — second-level thinking is explainable, not a black box.
nonisolated struct RegimeFactor: Sendable, Equatable, Identifiable {
    let kind: Kind
    let signal: RegimeSignal
    /// Human rationale with the figure that drove the signal, e.g.
    /// "Composite P/E·P/B at the 42nd percentile of its 10y range (cheap-ish)".
    let detail: String
    var id: String { kind.rawValue }

    nonisolated enum Kind: String, Sendable, CaseIterable {
        case valuation = "Valuation"           // index P/E·P/B percentile — dominant driver
        case policyRate = "BI rate"
        case foreignFlow = "Foreign flow"
        case trend = "IHSG trend"
        case rupiah = "Rupiah (USD/IDR)"
        case breadth = "Breadth (LQ45)"

        /// Marks: valuation is the dominant driver of *future* risk, so it carries
        /// more weight than the coincident sentiment/momentum factors.
        var weight: Int { self == .valuation ? 2 : 1 }
    }
}

/// The synthesised regime read: an overall stance, the normalised score that
/// produced it, and the transparent factor breakdown. `asOf` is the freshest
/// dated input that fed it (the server snapshot's date when present).
nonisolated struct RegimeRead: Sendable, Equatable {
    let stance: RegimeStance
    /// Normalised weighted vote ∈ [−1, +1]; positive = risk-on.
    let score: Double
    let factors: [RegimeFactor]
    let asOf: String?
    /// `true` when the late-cycle guard fired — an otherwise risk-on tape was held
    /// to neutral because valuation is stretched (see `RegimeSynthesizer.read`).
    let valuationCapped: Bool
}

// MARK: - regime.json contract (server-side scraper output)

/// Direction of Bank Indonesia's last policy-rate move. Easing (`cut`) supports
/// equity multiples and liquidity; tightening (`hike`) is the macro headwind that,
/// with foreign outflow, forms the classic IDX risk-off combo (`idx-investing-research.md` §3).
nonisolated enum BIRateDirection: String, Sendable, Decodable {
    case cut, hold, hike
}

/// The static JSON a server-side monthly job produces and the app fetches read-only
/// (`idx-regime-data-research.md` §6). Carries the two regime inputs the app cannot
/// source on-device: the BI policy rate and the cap-weighted index P/E·P/B
/// percentile vs. the index's own history. Every ratio is optional — absence is
/// information (a snapshot that hasn't been built yet, or a loss-making index leg).
nonisolated struct RegimeSnapshot: Sendable, Equatable, Decodable {
    let asOf: String
    let biRate: BIRate?
    let indices: [String: IndexValuation]

    nonisolated struct BIRate: Sendable, Equatable, Decodable {
        let value: Double
        let direction: BIRateDirection
        let asOf: String
    }

    nonisolated struct IndexValuation: Sendable, Equatable, Decodable {
        let pe: Double?
        let pb: Double?
        let pePctile: Double?
        let pbPctile: Double?
    }
}

extension RegimeSnapshot {
    /// Key for the whole-market composite (IHSG) — the doc's actual requirement.
    static let compositeKey = "COMPOSITE"
    nonisolated var composite: IndexValuation? { indices[Self.compositeKey] }
}

extension RegimeSnapshot.IndexValuation {
    /// Mean of the percentiles that are present (P/E and/or P/B), 0…1, or `nil`
    /// when neither is available. The single number the valuation factor scores.
    nonisolated var valuationPercentile: Double? {
        let present = [pePctile, pbPctile].compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +) / Double(present.count)
    }
}
