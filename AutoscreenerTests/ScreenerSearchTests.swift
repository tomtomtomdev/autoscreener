import Foundation
import Testing
@testable import Autoscreener

/// Search behavior on the `ScreenerViewModel` — `visibleRows` filtering and the
/// page-exhaust that backs a search on a paginated screener.
@MainActor
@Suite struct ScreenerSearchTests {

    // GET (page 1) returns a full page so `hasMore` is true off the bat.
    private final class PagedTemplates: ScreenerTemplateServicing, @unchecked Sendable {
        func load(templateID: String) async throws -> ScreenerInitialResult {
            var config = ScreenerConfig()
            config.screenerID = templateID
            let rows = ScreenerSearchTests.makeRows(prefix: "P1", count: config.limit)
            return ScreenerInitialResult(config: config, page: ScreenerPage(rows: rows, total: nil, page: 1))
        }
    }

    // GET (page 1) returns exactly two named rows as a complete page (total == 2),
    // so a search filters over a complete, single-page set with no pagination.
    private final class TwoRowTemplates: ScreenerTemplateServicing, @unchecked Sendable {
        func load(templateID: String) async throws -> ScreenerInitialResult {
            var config = ScreenerConfig()
            config.screenerID = templateID
            let rows = [
                ScreenerRow(symbol: "BBCA", name: "BCA", values: [], lastPrice: nil, pctChange: nil),
                ScreenerRow(symbol: "BBRI", name: "BRI", values: [], lastPrice: nil, pctChange: nil),
            ]
            return ScreenerInitialResult(config: config, page: ScreenerPage(rows: rows, total: 2, page: 1))
        }
    }

    // POST pages: page 2 is full, page 3 is partial — which ends pagination.
    private final class PagedService: ScreenerServicing, @unchecked Sendable {
        func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
            let count = page == 2 ? config.limit : 10
            return ScreenerPage(rows: ScreenerSearchTests.makeRows(prefix: "P\(page)", count: count),
                                total: nil, page: page)
        }
    }

    private nonisolated static func makeRows(prefix: String, count: Int) -> [ScreenerRow] {
        (0..<count).map {
            ScreenerRow(symbol: "\(prefix)-\($0)", name: "n", values: [], lastPrice: nil, pctChange: nil)
        }
    }

    @Test func visibleRowsReflectSearchText() async {
        let vm = ScreenerViewModel(service: PagedService(), paywall: nil,
                                   templates: TwoRowTemplates(), templateID: "6676314")
        await vm.autoRunIfNeeded()  // live-loads the two rows (a single complete page)

        #expect(vm.visibleRows.count == 2)
        vm.searchText = "bbr"
        #expect(vm.visibleRows.map(\.symbol) == ["BBRI"])
        vm.searchText = "   "
        #expect(vm.visibleRows.count == 2)  // blank → unfiltered
    }

    @Test func loadAllForSearchExhaustsEveryPage() async {
        let vm = ScreenerViewModel(service: PagedService(), paywall: nil,
                                   templates: PagedTemplates(), templateID: "6676314")
        await vm.autoRunIfNeeded()  // bootstrap loads page 1 (a full page)
        let firstPageCount = vm.rows.count
        #expect(vm.hasMore == true)

        await vm.loadAllForSearch()

        // page 1 (full) + page 2 (full) + page 3 (partial, 10) — and pagination is done.
        #expect(vm.rows.count == firstPageCount * 2 + 10)
        #expect(vm.hasMore == false)
    }
}
