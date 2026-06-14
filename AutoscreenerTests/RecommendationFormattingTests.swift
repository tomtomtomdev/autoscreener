import SwiftUI
import Testing
@testable import Autoscreener

// `RecommendationFormatting.gateBadges` surfaces Gate-2 (governance) and Gate-3 (consensus) as chips by
// reading the engine's existing audit lines — no engine change, so the locked golden master is
// untouched. These pin the parsing contract directly (pure data in, pure data out). The helper moved
// here from the (now-merged) Today's Picks view when its card UI folded into the unified Recommendations
// row.

@Suite @MainActor struct RecommendationFormattingTests {
    private typealias Badge = RecommendationFormatting.GateBadge

    @Test func governanceOKLineYieldsAGovernanceChip() {
        let badges = RecommendationFormatting.gateBadges([
            "regime=Neutral", "governance OK [significant · 2 flag(s)]", "MoS 31% vs req 25%",
        ])
        #expect(badges.contains(Badge(kind: .governance, label: "Governance ✓")))
    }

    @Test func consensusLineYieldsAFadeChipCarryingTheTilt() {
        let badges = RecommendationFormatting.gateBadges([
            "consensus -3% [Buy B/H/S 5/2/1 · tgt +12% · fade]",
        ])
        #expect(badges.contains(Badge(kind: .consensus, label: "Consensus fade -3%")))
    }

    @Test func bothGateLinesProduceBothChips() {
        let badges = RecommendationFormatting.gateBadges([
            "governance OK [watch · 0 flag(s)]", "consensus +2% [Hold B/H/S 1/4/1 · tgt +3% · fade]",
        ])
        #expect(badges.count == 2)
        #expect(badges.map(\.kind) == [.governance, .consensus])   // governance first, consensus second
    }

    @Test func anAuditWithoutGateLinesProducesNoChips() {
        let badges = RecommendationFormatting.gateBadges([
            "regime=Neutral", "✓ DataIntegrity", "MoS 31% vs req 25%", "→ conviction 0.74 weight 9%",
        ])
        #expect(badges.isEmpty)
    }
}
