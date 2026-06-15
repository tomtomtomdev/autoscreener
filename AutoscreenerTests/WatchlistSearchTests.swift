import Foundation
import Testing
@testable import Autoscreener

/// Search behavior on `WatchlistViewModel`. The composite isn't paginated, so
/// `visibleRows` is a pure filter over the already-complete composed `rows`.
@MainActor
@Suite struct WatchlistSearchTests {
    private func makeVM(_ symbols: [String]) -> WatchlistViewModel {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        // Seed a single non-veto screener so every symbol survives composition.
        let rows = symbols.map { ScreenerRow(symbol: $0, name: "\($0) Co", values: [1, 0], lastPrice: nil, pctChange: nil) }
        store.apply(ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: Date(timeIntervalSince1970: 0)),
                    for: .accumulating)
        return WatchlistViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store))
    }

    @Test func blankSearchShowsAllRows() {
        let vm = makeVM(["BBCA", "BBRI", "TLKM"])
        #expect(vm.visibleRows.count == 3)
    }

    @Test func searchFiltersBySymbolCaseInsensitively() {
        let vm = makeVM(["BBCA", "BBRI", "TLKM"])
        vm.searchText = "bb"
        #expect(Set(vm.visibleRows.map(\.symbol)) == ["BBCA", "BBRI"])
    }

    @Test func searchMatchesSymbolNotCompanyName() {
        let vm = makeVM(["TLKM"])
        vm.searchText = "Telkom"  // appears in the name, not the symbol
        #expect(vm.visibleRows.isEmpty)
    }
}
