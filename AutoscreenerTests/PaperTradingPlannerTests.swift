import Foundation
import Testing
@testable import Autoscreener

/// The pure glue that flattens Tier-A `Recommendation`s into the allocator's `AllocationCandidate` buy
/// universe. The price the selection engine valued each name at must survive the flattening so the
/// allocator can size a name even when the screener snapshot carries no last price for it.
@Suite struct PaperTradingPlannerTests {

    private func rec(_ ticker: String, price: Double?) -> Recommendation {
        Recommendation(ticker: ticker, compositeScore: 0.6, intrinsicValue: 10_000, price: price,
                       marginOfSafety: 0.3, conviction: 0.6, suggestedWeight: 0.1, audit: [])
    }

    @Test func candidateCarriesTheRecommendationPriceAsItsReferencePrice() {
        let candidates = PaperTradingPlanner.candidates(from: [rec("GOTO", price: 80)],
                                                        names: ["GOTO": "GoTo"])
        #expect(candidates.first?.symbol == "GOTO")
        #expect(candidates.first?.name == "GoTo")
        #expect(candidates.first?.referencePrice == 80)
    }

    @Test func aRecommendationWithoutAPriceLeavesTheReferencePriceNil() {
        let candidates = PaperTradingPlanner.candidates(from: [rec("GOTO", price: nil)], names: [:])
        #expect(candidates.first?.referencePrice == nil)
    }
}
