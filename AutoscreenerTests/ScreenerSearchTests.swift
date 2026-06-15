import Foundation
import Testing
@testable import Autoscreener

/// Search behavior on `ScreenerViewModel`. The cached snapshot holds the full result
/// set (no pagination), so `visibleRows` is a pure filter over `rows`.
@MainActor
@Suite struct ScreenerSearchTests {
    private func makeVM(_ symbols: [String]) -> ScreenerViewModel {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let rows = symbols.map { ScreenerRow(symbol: $0, name: $0, values: [1, 0], lastPrice: nil, pctChange: nil) }
        store.apply(ScreenerSnapshot(config: ScreenerConfig(), rows: rows, fetchedAt: Date(timeIntervalSince1970: 0)),
                    for: .intradayLiquidity)
        return ScreenerViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store), kind: .intradayLiquidity)
    }

    @Test func visibleRowsReflectSearchText() {
        let vm = makeVM(["BBCA", "BBRI"])
        #expect(vm.visibleRows.count == 2)
        vm.searchText = "bbr"
        #expect(vm.visibleRows.map(\.symbol) == ["BBRI"])
        vm.searchText = "   "
        #expect(vm.visibleRows.count == 2)  // blank → unfiltered
    }

    @Test func searchMatchesSymbolNotName() {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        store.apply(ScreenerSnapshot(config: ScreenerConfig(),
                                     rows: [ScreenerRow(symbol: "TLKM", name: "Telkom Indonesia", values: [1, 0], lastPrice: nil, pctChange: nil)],
                                     fetchedAt: Date(timeIntervalSince1970: 0)), for: .intradayLiquidity)
        let vm = ScreenerViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store), kind: .intradayLiquidity)
        vm.searchText = "Telkom"  // in the name, not the symbol
        #expect(vm.visibleRows.isEmpty)
    }
}
