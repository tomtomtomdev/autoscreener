import Foundation
import Testing
@testable import Autoscreener

/// Search behavior on the `WatchlistViewModel`. The watchlist isn't paginated,
/// so `visibleRows` is a pure filter over the already-complete `rows`.
@MainActor
@Suite struct WatchlistSearchTests {
    private func makeVM() -> WatchlistViewModel {
        WatchlistViewModel(paywall: WatchlistFakePaywall(),
                           templates: WatchlistFakeTemplates(),
                           screener: WatchlistFakeScreener())
    }

    private func row(_ symbol: String, _ name: String) -> WatchlistRow {
        WatchlistRow(symbol: symbol, name: name, matchedScreeners: [.accumulating])
    }

    @Test func blankSearchShowsAllRows() {
        let vm = makeVM()
        vm.rows = [row("BBCA", "BCA"), row("BBRI", "BRI"), row("TLKM", "Telkom")]
        #expect(vm.visibleRows.count == 3)
    }

    @Test func searchFiltersBySymbolCaseInsensitively() {
        let vm = makeVM()
        vm.rows = [row("BBCA", "BCA"), row("BBRI", "BRI"), row("TLKM", "Telkom")]
        vm.searchText = "bb"
        #expect(Set(vm.visibleRows.map(\.symbol)) == ["BBCA", "BBRI"])
    }

    @Test func searchMatchesSymbolNotCompanyName() {
        let vm = makeVM()
        vm.rows = [row("TLKM", "Telkom Indonesia")]
        vm.searchText = "Telkom"  // appears in the name, not the symbol
        #expect(vm.visibleRows.isEmpty)
    }
}
