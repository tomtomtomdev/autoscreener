import Foundation
import Testing
@testable import Autoscreener

// MARK: - Gate-2 governance veto (insider selling / dilution)
//
// `governanceVeto` is the pure decision the engine's inline Gate-2 check calls. It eliminates a name
// ONLY on a `.concern`-severity insider-selling or dilution flag (when enabled in config). Lighter
// `.watch` flags, and the thin-float / concentration / related-party kinds, are context — never a
// veto here. These tests pin that contract in isolation; the engine wiring (nil ⇒ unchanged, concern
// ⇒ eliminated, clean ⇒ "governance OK") is proven in SelectionEngineOverlayModifierTests.

@Suite struct GovernanceVetoTests {

    private func flag(_ kind: GovernanceFlag.Kind, _ severity: GovernanceSeverity) -> GovernanceFlag {
        GovernanceFlag(kind: kind, severity: severity,
                       evidence: "e", whyItMatters: "w", whatToCheckNext: "c")
    }
    private func assessment(_ flags: [GovernanceFlag]) -> GovernanceAssessment {
        GovernanceAssessment(level: flags.isEmpty ? .clean : .significant, flags: flags, missingSections: [])
    }
    private let cfg = SelectionConfig.balanced.governance

    @Test func cleanAssessmentDoesNotVeto() {
        #expect(governanceVeto(assessment([]), config: cfg) == nil)
    }

    @Test func concernInsiderSellingVetoes() {
        #expect(governanceVeto(assessment([flag(.insiderSelling, .concern)]), config: cfg)
                == GovernanceFlag.Kind.insiderSelling.rawValue)
    }

    @Test func watchInsiderSellingDoesNotVeto() {
        #expect(governanceVeto(assessment([flag(.insiderSelling, .watch)]), config: cfg) == nil)
    }

    @Test func concernRecentDilutionVetoes() {
        #expect(governanceVeto(assessment([flag(.recentDilution, .concern)]), config: cfg)
                == GovernanceFlag.Kind.recentDilution.rawValue)
    }

    @Test func concernChronicDilutionVetoes() {
        #expect(governanceVeto(assessment([flag(.chronicDilution, .concern)]), config: cfg) != nil)
    }

    @Test func concentrationConcernIsContextNotAVeto() {
        // Thin-float / concentration / related-party are deliberately NOT Gate-2 vetoes.
        #expect(governanceVeto(assessment([flag(.ownershipConcentration, .concern)]), config: cfg) == nil)
        #expect(governanceVeto(assessment([flag(.thinFloat, .concern)]), config: cfg) == nil)
        #expect(governanceVeto(assessment([flag(.relatedParty, .concern)]), config: cfg) == nil)
    }

    @Test func disablingInsiderVetoInConfigLetsItThrough() {
        var c = cfg; c.vetoInsiderSelling = false
        #expect(governanceVeto(assessment([flag(.insiderSelling, .concern)]), config: c) == nil)
    }

    @Test func disablingDilutionVetoInConfigLetsItThrough() {
        var c = cfg; c.vetoDilution = false
        #expect(governanceVeto(assessment([flag(.recentDilution, .concern)]), config: c) == nil)
    }
}
