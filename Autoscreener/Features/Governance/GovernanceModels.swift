import Foundation

// MARK: - Query parameters

/// Window for the major-holder endpoint's ownership-change view
/// (`insider/company/majorholder?period_type=…`). Mirrors `BrokerSummaryPeriod`'s
/// query-rawValue pattern. A longer window makes sustained accumulation/distribution by
/// insiders legible; a one-week blip is mostly noise.
nonisolated enum GovernancePeriod: String, Sendable, CaseIterable {
    case sevenDay = "PERIOD_TYPE_7_DAY"
    case oneMonth = "PERIOD_TYPE_1_MONTH"
    case oneYear = "PERIOD_TYPE_1_YEAR"
}

// MARK: - Raw governance facts (assembled from the insider / corpaction endpoints)

/// One major / insider holder of the company. `ownershipPercent` is the stake now;
/// `changeInOwnershipPct` is the change in percentage-points of the company owned over the
/// requested `GovernancePeriod` (negative = the holder reduced — i.e. selling).
/// `pledgedPercent` is the share of *their* stake reported pledged/encumbered when disclosed
/// (forced-sale risk). `insiderID` keys the cross-holding lookup. Figures are optional —
/// absence is information, not zero.
nonisolated struct MajorHolder: Sendable, Equatable {
    let name: String
    let isInsider: Bool            // director / commissioner / affiliate vs. ordinary >5% holder
    let insiderID: String?
    let ownershipPercent: Double?
    let changeInOwnershipPct: Double?
    let pledgedPercent: Double?
}

/// Shareholding composition — the ownership breakdown (named ≥5% holders + category
/// buckets like "Individual"/"Corporate") as returned by the composition endpoint. The feed
/// has *no single public-float field*, so both free float and concentration are derived from
/// this list in `GovernanceRules` (`idx-investing-research.md` §4).
nonisolated struct ShareholdingComposition: Sendable, Equatable {
    let holders: [HolderSlice]

    nonisolated struct HolderSlice: Sendable, Equatable {
        let label: String
        let percent: Double?   // percent of shares, e.g. 30.57
    }
}

/// A corporate action. `type.isDilutive` marks the ones that issue new shares against
/// existing holders (rights, private placement, warrants/ESOP) — as opposed to cosmetic
/// actions (splits, bonus shares) or cash dividends.
nonisolated struct CorpAction: Sendable, Equatable {
    let type: CorpActionType
    let date: Date?
    let detail: String?

    nonisolated enum CorpActionType: String, Sendable, Equatable {
        case rightsIssue
        case privatePlacement      // non-preemptive — dilutes minorities hardest
        case warrant
        case employeeStock         // ESOP / MESOP
        case cashDividend
        case stockDividend
        case bonusShares
        case split
        case reverseSplit
        case other

        /// True when the action issues new shares against existing holders.
        var isDilutive: Bool {
            switch self {
            case .rightsIssue, .privatePlacement, .warrant, .employeeStock: true
            default: false
            }
        }
    }
}

/// A subsidiary in the group structure. A sprawling subsidiary web is where related-party
/// transactions hide (`financial-shenanigans` EM2: "revenue from entities the company also pays").
nonisolated struct Subsidiary: Sendable, Equatable {
    let name: String
    let ownershipPercent: Double?
}

/// Another listed company a major holder of *this* company also owns — a cross-holding.
/// Common control across listed entities is the classic related-party channel: goods,
/// loans, or guarantees can move between them on non-arm's-length terms.
nonisolated struct CrossHolding: Sendable, Equatable {
    let holderName: String
    let symbol: String
    let ownershipPercent: Double?
}

/// The assembled per-stock governance facts. Each section can be empty / `nil` — a paywalled
/// or unavailable endpoint degrades that section without failing the whole report (the same
/// graceful-degradation contract the regime read uses). `missingSections` records which ones
/// failed so a sparse fetch can't masquerade as a clean bill of health.
nonisolated struct GovernanceData: Sendable, Equatable {
    let symbol: String
    let period: GovernancePeriod
    var majorHolders: [MajorHolder] = []
    var composition: ShareholdingComposition?
    var corpActions: [CorpAction] = []
    var subsidiaries: [Subsidiary] = []
    var crossHoldings: [CrossHolding] = []
    var missingSections: [String] = []
}

// MARK: - Governance read (output of GovernanceRules)

/// Severity of a single governance flag. Ordered: a `.concern` outranks a `.watch`.
nonisolated enum GovernanceSeverity: Int, Sendable, Comparable {
    case info = 0, watch = 1, concern = 2
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One governance red flag. Carries the evidence and — per the `financial-shenanigans`
/// presentation discipline — *why it matters* and *what to check next*, framed as a question
/// to investigate, never an accusation.
nonisolated struct GovernanceFlag: Sendable, Equatable, Identifiable {
    let kind: Kind
    let severity: GovernanceSeverity
    let evidence: String
    let whyItMatters: String
    let whatToCheckNext: String
    var id: String { kind.rawValue }

    nonisolated enum Kind: String, Sendable, CaseIterable {
        case thinFloat = "Thin free float"
        case ownershipConcentration = "Ownership concentration"
        case insiderSelling = "Insider / major-holder selling"
        case recentDilution = "Recent dilution"
        case chronicDilution = "Chronic dilution"
        case relatedParty = "Related-party / group complexity"
    }
}

/// Overall governance posture — the count-and-severity synthesis of the flags. A posture,
/// not a verdict: "one flag is a question, a pattern is a thesis."
nonisolated enum GovernanceLevel: String, Sendable {
    case clean = "Clean"
    case watch = "Watch"
    case significant = "Significant concerns"
}

nonisolated struct GovernanceAssessment: Sendable, Equatable {
    let level: GovernanceLevel
    let flags: [GovernanceFlag]
    /// Sections that returned no data (paywall / 404 / empty) — caveats the read.
    let missingSections: [String]
}

// MARK: - Errors

nonisolated enum GovernanceError: Error, Equatable {
    case unauthorized
    case paywall
    case network(String)
    case malformedResponse
}
