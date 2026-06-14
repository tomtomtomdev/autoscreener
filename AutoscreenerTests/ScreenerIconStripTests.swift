import Foundation
import Testing
@testable import Autoscreener

/// The pure, view-free logic behind the Watchlist screener-icon column: which screeners a row shows,
/// in what order, and that every kind has a renderable symbol + family.
@Suite struct ScreenerIconCatalogTests {

    @Test func displayedDropsVetoGatesAndKeepsCanonicalOrder() {
        // A scrambled insertion order including both liquidity veto gates and several signal screeners.
        let matched: Set<BandarScreenerKind> = [
            .roeQuality, .liquidityFloor, .accumulating, .intradayLiquidity, .volumeSpike, .foreignFlow3M,
        ]

        let shown = ScreenerIconCatalog.displayed(from: matched)

        // No veto gate survives…
        #expect(!shown.contains(.liquidityFloor))
        #expect(!shown.contains(.intradayLiquidity))
        // …and the rest come back in `allCases` declaration order, regardless of set insertion order.
        #expect(shown == [.accumulating, .foreignFlow3M, .volumeSpike, .roeQuality])
    }

    @Test func displayedIsEmptyForVetoOnlyRow() {
        // A row that only matched the two liquidity gates contributes no signal icons.
        #expect(ScreenerIconCatalog.displayed(from: [.liquidityFloor, .intradayLiquidity]).isEmpty)
    }

    @Test func everyKindHasANonEmptySymbol() {
        // Guards against an accidental "" that would render a blank icon.
        for kind in BandarScreenerKind.allCases {
            #expect(!ScreenerIconCatalog.symbol(for: kind).isEmpty,
                    "Missing SF Symbol for \(kind)")
        }
    }

    @Test func familyMapsRepresentativeKinds() {
        #expect(ScreenerIconCatalog.family(for: .accumulating) == .bandar)
        #expect(ScreenerIconCatalog.family(for: .foreignFlow1M) == .foreign)
        #expect(ScreenerIconCatalog.family(for: .volumeSpike) == .activity)
        #expect(ScreenerIconCatalog.family(for: .roeQuality) == .fundamental)
        #expect(ScreenerIconCatalog.family(for: .liquidityFloor) == .liquidity)
    }
}
