import Foundation
import Testing
@testable import Autoscreener

// MARK: - Fixtures / builders

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian),
                   timeZone: TimeZone(identifier: "UTC"),
                   year: y, month: m, day: d).date!
}

private let now = date(2026, 6, 5)

private func holder(_ name: String = "X",
                    insider: Bool = true,
                    own: Double? = nil,
                    change: Double? = nil) -> MajorHolder {
    MajorHolder(name: name, isInsider: insider, insiderID: nil,
                ownershipPercent: own, changeInOwnershipPct: change, pledgedPercent: nil)
}

// MARK: - Per-flag classifiers

@Suite struct GovernanceFlagClassifierTests {
    @Test func thinFloatWatchAndConcernBands() {
        #expect(GovernanceRules.thinFloatFlag(.init(publicFloatPercent: 25, foreignPercent: nil)) == nil)          // healthy
        #expect(GovernanceRules.thinFloatFlag(.init(publicFloatPercent: 12, foreignPercent: nil))?.severity == .watch)
        #expect(GovernanceRules.thinFloatFlag(.init(publicFloatPercent: 5, foreignPercent: nil))?.severity == .concern)
        #expect(GovernanceRules.thinFloatFlag(nil) == nil)                                                          // absent
    }

    @Test func thinFloatToleratesFractionOrPercent() {
        #expect(GovernanceRules.thinFloatFlag(.init(publicFloatPercent: 0.05, foreignPercent: nil))?.severity == .concern)
    }

    @Test func concentrationControllingAndDominant() {
        #expect(GovernanceRules.concentrationFlag([holder(own: 40)]) == nil)
        #expect(GovernanceRules.concentrationFlag([holder(own: 60)])?.severity == .watch)
        #expect(GovernanceRules.concentrationFlag([holder(own: 85)])?.severity == .concern)
        #expect(GovernanceRules.concentrationFlag([]) == nil)
    }

    @Test func insiderSellingCountsOnlyInsidersAndOnlyNetSelling() {
        let bigSell = [holder("A", own: 30, change: -2), holder("B", own: 10, change: -4)]
        #expect(GovernanceRules.insiderSellingFlag(bigSell, period: .oneYear)?.severity == .concern)   // −6pp net

        #expect(GovernanceRules.insiderSellingFlag([holder(change: -1)], period: .oneYear)?.severity == .watch)
        #expect(GovernanceRules.insiderSellingFlag([holder(change: 3)], period: .oneYear) == nil)       // net buying
        #expect(GovernanceRules.insiderSellingFlag([holder(insider: false, change: -9)], period: .oneYear) == nil) // not an insider
        #expect(GovernanceRules.insiderSellingFlag([holder(change: nil)], period: .oneYear) == nil)     // no data
    }

    @Test func recentDilutionAndPrivatePlacementSeverity() {
        let rights = [CorpAction(type: .rightsIssue, date: date(2026, 3, 1), detail: nil)]
        let r = GovernanceRules.dilutionFlags(rights, now: now)
        #expect(r.contains { $0.kind == .recentDilution && $0.severity == .watch })

        let pp = [CorpAction(type: .privatePlacement, date: date(2026, 3, 1), detail: nil)]
        #expect(GovernanceRules.dilutionFlags(pp, now: now).contains { $0.kind == .recentDilution && $0.severity == .concern })
    }

    @Test func nonDilutiveActionsAreNotFlagged() {
        let cosmetic = [
            CorpAction(type: .split, date: date(2026, 3, 1), detail: nil),
            CorpAction(type: .cashDividend, date: date(2026, 3, 1), detail: nil),
            CorpAction(type: .bonusShares, date: date(2026, 3, 1), detail: nil),
        ]
        #expect(GovernanceRules.dilutionFlags(cosmetic, now: now).isEmpty)
    }

    @Test func chronicDilutionAcrossThreeYears() {
        let actions = [
            CorpAction(type: .rightsIssue, date: date(2024, 5, 1), detail: nil),
            CorpAction(type: .rightsIssue, date: date(2025, 9, 1), detail: nil),
        ]
        #expect(GovernanceRules.dilutionFlags(actions, now: now).contains { $0.kind == .chronicDilution && $0.severity == .concern })
    }

    @Test func staleDilutionIsIgnored() {
        let old = [CorpAction(type: .rightsIssue, date: date(2018, 1, 1), detail: nil)]
        #expect(GovernanceRules.dilutionFlags(old, now: now).isEmpty)
    }

    @Test func relatedPartyCrossHoldingIsWatchManySubsidiariesIsInfo() {
        let ch = [CrossHolding(holderName: "Owner", symbol: "AAAA", ownershipPercent: 20)]
        #expect(GovernanceRules.relatedPartyFlag(subsidiaries: [], crossHoldings: ch)?.severity == .watch)

        let manySubs = (0..<12).map { Subsidiary(name: "S\($0)", ownershipPercent: 99) }
        #expect(GovernanceRules.relatedPartyFlag(subsidiaries: manySubs, crossHoldings: [])?.severity == .info)

        #expect(GovernanceRules.relatedPartyFlag(subsidiaries: [Subsidiary(name: "S", ownershipPercent: 99)], crossHoldings: []) == nil)
    }
}

// MARK: - Synthesis

@Suite struct GovernanceAssessmentTests {
    @Test func cleanWhenNothingFires() {
        let data = GovernanceData(
            symbol: "OK", period: .oneYear,
            majorHolders: [holder(own: 30, change: 1)],
            composition: .init(publicFloatPercent: 40, foreignPercent: nil))
        #expect(GovernanceRules.assess(data, now: now).level == .clean)
    }

    @Test func anyConcernEscalatesToSignificant() {
        let data = GovernanceData(
            symbol: "BAD", period: .oneYear,
            majorHolders: [holder(own: 88)],
            composition: .init(publicFloatPercent: 5, foreignPercent: nil))
        let assessment = GovernanceRules.assess(data, now: now)
        #expect(assessment.level == .significant)
        #expect(assessment.flags.count >= 2)   // thin float + dominant concentration
    }

    @Test func missingSectionsArePropagated() {
        let data = GovernanceData(symbol: "X", period: .oneYear, missingSections: ["composition", "corpActions"])
        #expect(GovernanceRules.assess(data, now: now).missingSections == ["composition", "corpActions"])
    }
}
