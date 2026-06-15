import Foundation

/// Turns assembled `GovernanceData` into governance red flags — the bottom-up
/// governance/related-party screen `idx-investing-research.md` §4 calls for, grounded in
/// the `financial-shenanigans` skill's governance cues.
///
/// Pure and deterministic (the clock is passed in, never read), mirroring
/// `RegimeSynthesizer`: per-flag classifiers each return `GovernanceFlag?` (nil = clean on
/// that axis, or input unavailable), and `assess(_:now:)` collects them into a posture.
/// Thresholds are starting points — tune against a known-clean and a known-problem IDX
/// name. Every flag is framed as a question to investigate, never an accusation.
nonisolated enum GovernanceRules {
    enum Threshold {
        /// Free float: below 15% is a minority-protection + liquidity worry; below 7.5% acute.
        static let floatWatch = 0.15
        static let floatConcern = 0.075
        /// A holder above 50% controls; above 80% leaves minorities almost no say.
        static let controlling = 0.50
        static let dominant = 0.80
        /// Net insider reduction over the window, in percentage-points of the company.
        static let insiderSellWatch = 0.0      // any net reduction
        static let insiderSellConcern = 5.0    // ≥5pp of the company sold by insiders
        /// Dilution recency / chronicity windows (months) and the chronic count.
        static let dilutionRecentMonths = 12.0
        static let chronicWindowMonths = 36.0
        static let chronicCount = 2
        /// Subsidiary count above which a group's complexity is worth noting.
        static let complexGroupSubsidiaries = 10
    }

    // MARK: - Per-flag classifiers

    /// Free float ≈ 100% − the sum of every holder at or above 5% (the
    /// non-substantial-shareholder proxy). Returned as a percent (0…100), or `nil` when the
    /// composition is unavailable. The composition feed has no single public-float field, so
    /// this is the agreed derivation.
    static func freeFloat(_ composition: ShareholdingComposition?) -> Double? {
        guard let holders = composition?.holders, !holders.isEmpty else { return nil }
        let substantial = holders.compactMap(\.percent).filter { $0 >= 5 }.reduce(0, +)
        return max(0, 100 - substantial)
    }

    /// Thin derived free float → thin-float flag. Tolerates the value as `9.05` or `0.0905`.
    static func thinFloatFlag(_ composition: ShareholdingComposition?) -> GovernanceFlag? {
        guard let free = freeFloat(composition) else { return nil }
        let pct = free > 1 ? free / 100 : free
        guard pct <= Threshold.floatWatch else { return nil }
        let severity: GovernanceSeverity = pct <= Threshold.floatConcern ? .concern : .watch
        return GovernanceFlag(
            kind: .thinFloat, severity: severity,
            evidence: "Free float ≈ \(pct.asPercent) (100% − holders ≥5%).",
            whyItMatters: "A thin float concentrates control and makes a clean exit hard — minority holders are price-takers and can be squeezed in a delisting or take-private.",
            whatToCheckNext: "Confirm the float against the latest KSEI/IDX composition and check daily value traded against the screener's liquidity floor.")
    }

    /// Largest holder above the controlling threshold → concentration flag. Reads the
    /// composition breakdown (the movement feed only carries small director trades).
    static func concentrationFlag(_ composition: ShareholdingComposition?) -> GovernanceFlag? {
        let percents: [Double] = (composition?.holders ?? []).compactMap(\.percent)
        let top = percents.map { $0 > 1 ? $0 / 100 : $0 }.max()
        guard let top, top >= Threshold.controlling else { return nil }
        let severity: GovernanceSeverity = top >= Threshold.dominant ? .concern : .watch
        return GovernanceFlag(
            kind: .ownershipConcentration, severity: severity,
            evidence: "Largest holder owns ≈ \(top.asPercent).",
            whyItMatters: "A controlling shareholder can set related-party terms, the board, and dividend policy over minority objections — governance risk rises with concentration.",
            whatToCheckNext: "Read related-party-transaction and board-independence disclosures; check whether minorities have any protective provisions.")
    }

    /// Net reduction by *insiders* over the window → insider-selling flag. Only insiders
    /// count (an index fund trimming is not a governance signal).
    static func insiderSellingFlag(_ holders: [MajorHolder], period: GovernancePeriod) -> GovernanceFlag? {
        let deltas = holders.filter(\.isInsider).compactMap(\.changeInOwnershipPct)
        guard !deltas.isEmpty else { return nil }
        let net = deltas.reduce(0, +)   // percentage-points of the company; negative = net selling
        guard net < Threshold.insiderSellWatch else { return nil }
        let severity: GovernanceSeverity = (-net) >= Threshold.insiderSellConcern ? .concern : .watch
        return GovernanceFlag(
            kind: .insiderSelling, severity: severity,
            evidence: "Insiders net reduced ≈ \((-net).asPoints) of the company over the \(period.humanWindow).",
            whyItMatters: "Insiders sell for many reasons, but sustained net selling by those closest to the business is a motive/opportunity amplifier — it weakens, never strengthens, a bull thesis.",
            whatToCheckNext: "Pull the filing-level insider transactions; distinguish open-market sales from pledges, inheritance, or corporate restructuring.")
    }

    /// Recent and chronic dilution from the corporate-action history (relative to `now`).
    static func dilutionFlags(_ actions: [CorpAction], now: Date) -> [GovernanceFlag] {
        let dilutive = actions.filter { $0.type.isDilutive }
        var flags: [GovernanceFlag] = []

        let recent = dilutive.filter { within($0.date, months: Threshold.dilutionRecentMonths, of: now) }
        if !recent.isEmpty {
            let worst = recent.max { rank($0.type) < rank($1.type) }!
            let hasPrivatePlacement = recent.contains { $0.type == .privatePlacement }
            flags.append(GovernanceFlag(
                kind: .recentDilution, severity: hasPrivatePlacement ? .concern : .watch,
                evidence: "\(recent.count) dilutive action(s) in the last 12 months (latest: \(worst.type.label)).",
                whyItMatters: hasPrivatePlacement
                    ? "A non-preemptive private placement dilutes existing minorities directly and can transfer value to the buyer at a discount."
                    : "Recent share issuance dilutes per-share value; the test is whether the raised capital earns more than it dilutes.",
                whatToCheckNext: "Check the issue price vs. market, the use of proceeds, and whether minorities had pre-emptive rights."))
        }

        let chronicCount = dilutive.filter { within($0.date, months: Threshold.chronicWindowMonths, of: now) }.count
        if chronicCount >= Threshold.chronicCount {
            flags.append(GovernanceFlag(
                kind: .chronicDilution, severity: .concern,
                evidence: "\(chronicCount) dilutive actions in the last 3 years.",
                whyItMatters: "Serial equity raises are a cash-burn tell — the business may not self-fund, and each round resets minority ownership lower.",
                whatToCheckNext: "Trace whether each raise was followed by the promised return on capital, or just funded operating losses."))
        }
        return flags
    }

    /// Cross-holdings (a major holder also owning other listed entities) → related-party
    /// watch; a merely large subsidiary count → an informational note.
    static func relatedPartyFlag(subsidiaries: [Subsidiary], crossHoldings: [CrossHolding]) -> GovernanceFlag? {
        if !crossHoldings.isEmpty {
            let names = crossHoldings.prefix(3).map(\.symbol).joined(separator: ", ")
            let more = crossHoldings.count > 3 ? ", …" : ""
            return GovernanceFlag(
                kind: .relatedParty, severity: .watch,
                evidence: "A major holder also owns other listed entities (\(names)\(more)).",
                whyItMatters: "Common control across listed entities is the classic related-party channel — sales, loans, or guarantees can move between them on non-arm's-length terms (Schilit EM2).",
                whatToCheckNext: "Read the related-party-transaction note; quantify revenue/receivables/payables with affiliated entities as a share of the total.")
        }
        if subsidiaries.count >= Threshold.complexGroupSubsidiaries {
            return GovernanceFlag(
                kind: .relatedParty, severity: .info,
                evidence: "\(subsidiaries.count) subsidiaries in the group.",
                whyItMatters: "A complex group structure isn't a problem by itself, but it widens the surface for related-party transactions and consolidation opacity.",
                whatToCheckNext: "Skim the subsidiary list for entities in unrelated businesses or jurisdictions, and check intra-group transaction disclosures.")
        }
        return nil
    }

    // MARK: - Synthesis

    /// Collects every flag and synthesises the overall posture. `.significant` when any flag
    /// is a `.concern` or a *pattern* of three-plus non-trivial flags lines up; `.watch` for
    /// anything lighter; `.clean` only when nothing fires.
    static func assess(_ data: GovernanceData, now: Date) -> GovernanceAssessment {
        var flags: [GovernanceFlag] = []
        if let f = thinFloatFlag(data.composition) { flags.append(f) }
        if let f = concentrationFlag(data.composition) { flags.append(f) }
        if let f = insiderSellingFlag(data.majorHolders, period: data.period) { flags.append(f) }
        flags.append(contentsOf: dilutionFlags(data.corpActions, now: now))
        if let f = relatedPartyFlag(subsidiaries: data.subsidiaries, crossHoldings: data.crossHoldings) { flags.append(f) }

        let hasConcern = flags.contains { $0.severity == .concern }
        let nonTrivial = flags.filter { $0.severity > .info }.count
        let level: GovernanceLevel = hasConcern || nonTrivial >= 3 ? .significant
            : (flags.isEmpty ? .clean : .watch)

        return GovernanceAssessment(level: level, flags: flags, missingSections: data.missingSections)
    }

    // MARK: - Helpers

    /// Worst-first ranking of dilution types (private placement worst).
    private static func rank(_ type: CorpAction.CorpActionType) -> Int {
        switch type {
        case .privatePlacement: 3
        case .rightsIssue: 2
        case .warrant: 1
        default: 0
        }
    }

    /// True when `date` is present and falls within the last `months` before `now`.
    private static func within(_ date: Date?, months: Double, of now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date) / (30.44 * 24 * 3_600)
        return elapsed >= 0 && elapsed <= months
    }
}

// MARK: - Formatting helpers

private extension Double {
    /// A fraction (0…1) rendered as a percent, e.g. 0.125 → "12.5%".
    var asPercent: String { String(format: "%.1f%%", self * 100) }
    /// A percentage-points figure rendered as-is, e.g. 6.0 → "6.0pp".
    var asPoints: String { String(format: "%.1fpp", self) }
}

private extension GovernancePeriod {
    var humanWindow: String {
        switch self {
        case .sevenDay: "past week"
        case .oneMonth: "past month"
        case .oneYear: "past year"
        }
    }
}

private extension CorpAction.CorpActionType {
    var label: String {
        switch self {
        case .rightsIssue: "rights issue"
        case .privatePlacement: "private placement"
        case .warrant: "warrant"
        case .employeeStock: "ESOP/MESOP"
        default: rawValue
        }
    }
}
