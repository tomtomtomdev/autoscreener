import Foundation
import Testing
@testable import Autoscreener

// MARK: - Model

@Suite struct BandarScreenerKindTests {
    /// Pins the rule weights to the values in `bandar-master.json` (Ulysees repo).
    /// If any future edit silently changes these, the watchlist's score loses its
    /// link to the published spec.
    @Test func weightsMatchMasterJSONSpec() {
        #expect(BandarScreenerKind.accumulating.weight == 2.0)
        #expect(BandarScreenerKind.aboveMA20.weight == 1.5)
        #expect(BandarScreenerKind.shiftToday.weight == 2.0)
    }

    @Test func templateIDsMatchSidebarMapping() {
        // Must match SidebarItem.templateID and ScreenerTemplateService.defaultFilters
        // — otherwise the watchlist fetches a different filter set than the sidebar tabs.
        #expect(BandarScreenerKind.accumulating.templateID == "6676213")
        #expect(BandarScreenerKind.aboveMA20.templateID    == "6676217")
        #expect(BandarScreenerKind.shiftToday.templateID   == "6676221")
    }
}

@Suite struct WatchlistRowTests {
    @Test func scoreSumsWeightsOfMatchedScreeners() {
        let allThree = WatchlistRow(symbol: "X", name: "X",
                                    matchedScreeners: [.accumulating, .aboveMA20, .shiftToday])
        #expect(allThree.score == 5.5)

        let accAndShift = WatchlistRow(symbol: "Y", name: "Y",
                                       matchedScreeners: [.accumulating, .shiftToday])
        #expect(accAndShift.score == 4.0)

        let aboveOnly = WatchlistRow(symbol: "Z", name: "Z",
                                     matchedScreeners: [.aboveMA20])
        #expect(aboveOnly.score == 1.5)

        let accOnly = WatchlistRow(symbol: "W", name: "W",
                                   matchedScreeners: [.accumulating])
        #expect(accOnly.score == 2.0)

        let none = WatchlistRow(symbol: "N", name: "N", matchedScreeners: [])
        #expect(none.score == 0.0)
    }
}

// MARK: - ViewModel — thread-safe local fakes

/// Lock-protected paywall fake. The watchlist bootstrap awaits across `async let`,
/// so the existing FakePaywallService (which appends to a plain Array) would race.
final class WatchlistFakePaywall: PaywallServicing, @unchecked Sendable {
    var eligibility = PaywallEligibility(eligible: true, message: nil)
    private let lock = NSLock()
    private var _checkCalls: [PaywallFeature] = []
    private var _incrementCalls: [PaywallFeature] = []
    var checkCalls: [PaywallFeature] { lock.lock(); defer { lock.unlock() }; return _checkCalls }
    var incrementCalls: [PaywallFeature] { lock.lock(); defer { lock.unlock() }; return _incrementCalls }

    func check(_ feature: PaywallFeature) async -> PaywallEligibility {
        lock.lock(); _checkCalls.append(feature); lock.unlock()
        return eligibility
    }
    func increment(_ feature: PaywallFeature) async {
        lock.lock(); _incrementCalls.append(feature); lock.unlock()
    }
}

final class WatchlistFakeTemplates: ScreenerTemplateServicing, @unchecked Sendable {
    /// Lookup-only: deterministic and concurrency-safe (no mutation during `load`).
    var resultsByTemplateID: [String: Result<ScreenerInitialResult, Error>] = [:]
    private let lock = NSLock()
    private var _loadCalls: [String] = []
    var loadCalls: [String] { lock.lock(); defer { lock.unlock() }; return _loadCalls }

    func load(templateID: String) async throws -> ScreenerInitialResult {
        lock.lock(); _loadCalls.append(templateID); lock.unlock()
        guard let r = resultsByTemplateID[templateID] else {
            return ScreenerInitialResult(
                config: WatchlistTestHelpers.config(for: templateID),
                page: ScreenerPage(rows: [], total: 0, page: 1)
            )
        }
        return try r.get()
    }
}

final class WatchlistFakeScreener: ScreenerServicing, @unchecked Sendable {
    /// (screenerID, page) → rows. Lookup-only.
    var pages: [String: [Int: [ScreenerRow]]] = [:]
    /// If set, every call for the matching screenerID returns `count` synthetic rows.
    /// Used to drive the safety-cap test.
    var alwaysFullPage: (screenerID: String, count: Int)?
    private let lock = NSLock()
    private var _calls: [(screenerID: String, page: Int)] = []
    var calls: [(String, Int)] { lock.lock(); defer { lock.unlock() }; return _calls.map { ($0.screenerID, $0.page) } }
    func callCount(for screenerID: String) -> Int {
        calls.filter { $0.0 == screenerID }.count
    }

    func run(_ config: ScreenerConfig, page: Int) async throws -> ScreenerPage {
        lock.lock(); _calls.append((config.screenerID, page)); lock.unlock()
        if let f = alwaysFullPage, config.screenerID == f.screenerID {
            let rows = (0..<f.count).map {
                ScreenerRow(symbol: "FULL_\(config.screenerID)_\(page)_\($0)",
                            name: "x", values: [], lastPrice: nil, pctChange: nil)
            }
            return ScreenerPage(rows: rows, total: nil, page: page)
        }
        let rows = pages[config.screenerID]?[page] ?? []
        return ScreenerPage(rows: rows, total: nil, page: page)
    }
}

enum WatchlistTestHelpers {
    static func config(for templateID: String) -> ScreenerConfig {
        var c = ScreenerConfig()
        c.screenerID = templateID
        c.sequence = templateID == "6676221" ? [14399, 14425] : [14399, 14426]
        c.orderColumn = 2
        c.orderType = "desc"
        c.limit = 25
        return c
    }

    static func initial(for kind: BandarScreenerKind, rows: [ScreenerRow], total: Int? = nil) -> ScreenerInitialResult {
        ScreenerInitialResult(
            config: config(for: kind.templateID),
            page: ScreenerPage(rows: rows, total: total, page: 1)
        )
    }

    static func row(_ symbol: String, name: String? = nil) -> ScreenerRow {
        ScreenerRow(symbol: symbol, name: name ?? "\(symbol) Co",
                    values: [1, 0], lastPrice: nil, pctChange: nil)
    }
}

@MainActor
@Suite struct WatchlistBootstrapTests {
    private func makeVM(paywall: WatchlistFakePaywall = WatchlistFakePaywall(),
                        templates: WatchlistFakeTemplates = WatchlistFakeTemplates(),
                        screener: WatchlistFakeScreener = WatchlistFakeScreener(),
                        safetyCap: Int = 20) -> WatchlistViewModel {
        WatchlistViewModel(paywall: paywall, templates: templates,
                           screener: screener, safetyCap: safetyCap)
    }

    @Test func bootstrapFiresPaywallIncrementExactlyOnceAcrossThreeFetches() async {
        let paywall = WatchlistFakePaywall()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
        ]
        let vm = makeVM(paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls == [.screener])
        #expect(paywall.incrementCalls == [.screener])
        #expect(Set(templates.loadCalls) == ["6676213", "6676217", "6676221"])
        #expect(templates.loadCalls.count == 3)
    }

    @Test func dedupesBySymbolAcrossThreeScreenersUnioningWeights() async {
        // BBCA returned by all 3 → score 5.5; BBRI returned by 2 → 3.5; CARE by 1 → 1.5.
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("BBRI")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("CARE")])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("BBRI")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        let byID = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.symbol, $0) })
        #expect(vm.rows.count == 3)
        #expect(byID["BBCA"]?.matchedScreeners == [.accumulating, .aboveMA20, .shiftToday])
        #expect(byID["BBCA"]?.score == 5.5)
        #expect(byID["BBRI"]?.matchedScreeners == [.accumulating, .shiftToday])
        #expect(byID["BBRI"]?.score == 4.0)
        #expect(byID["CARE"]?.matchedScreeners == [.aboveMA20])
        #expect(byID["CARE"]?.score == 1.5)
    }

    @Test func sortsDescendingByScoreThenAscendingBySymbol() async {
        // AAA and ZZZ both in all 3 (tie 5.5 → AAA first by symbol). MMM in only accumulating (2.0).
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("MMM"), WatchlistTestHelpers.row("ZZZ")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("ZZZ")])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("ZZZ")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.rows.map(\.symbol) == ["AAA", "ZZZ", "MMM"])
    }

    @Test func autoPaginatesEachScreenerUntilPartialPage() async {
        // accumulating: page1=25 (full), page2=25 (full), page3=12 (partial → done).
        // Other two screeners: empty page 1 → no POST.
        let templates = WatchlistFakeTemplates()
        let page1Acc = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1Acc)),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
        ]
        let screener = WatchlistFakeScreener()
        screener.pages["6676213"] = [
            2: (0..<25).map { WatchlistTestHelpers.row("ACC2_\($0)") },
            3: (0..<12).map { WatchlistTestHelpers.row("ACC3_\($0)") },
        ]
        let vm = makeVM(templates: templates, screener: screener)

        await vm.autoRunIfNeeded()

        #expect(vm.rows.count == 62)  // 25 + 25 + 12
        #expect(vm.rows.allSatisfy { $0.matchedScreeners == [.accumulating] })
        #expect(screener.callCount(for: "6676213") == 2)  // pages 2 and 3
        #expect(screener.callCount(for: "6676217") == 0)
        #expect(screener.callCount(for: "6676221") == 0)
    }

    @Test func partialScreenerFailureKeepsOtherTwoAndSurfacesError() async {
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .failure(ScreenerError.malformedResponse),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("BBCA")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.rows.count == 1)
        #expect(vm.rows.first?.matchedScreeners == [.accumulating, .shiftToday])
        #expect(vm.rows.first?.score == 4.0)
        #expect(vm.error != nil)
        // Error message names the failed screener so the user knows what's missing.
        #expect(vm.error?.contains("Bandar Above MA20") == true)
    }

    @Test func autoRunIsIdempotentAcrossMultipleCalls() async {
        let paywall = WatchlistFakePaywall()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
        ]
        let vm = makeVM(paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls.count == 1)
        #expect(paywall.incrementCalls.count == 1)
        #expect(templates.loadCalls.count == 3)
    }

    @Test func paywallIneligibleSurfacesBannerButRunsAnyway() async {
        let paywall = WatchlistFakePaywall()
        paywall.eligibility = PaywallEligibility(eligible: false, message: "Upgrade to use the screener.")
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
        ]
        let vm = makeVM(paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.paywallMessage == "Upgrade to use the screener.")
        #expect(vm.rows.count == 1)
    }

    @Test func safetyCapBoundsPagesPerScreener() async {
        // Page 1 returns a full page; all subsequent POSTs return a full page too → would
        // loop forever. The VM's safetyCap stops it.
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("P1_\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
        ]
        let screener = WatchlistFakeScreener()
        screener.alwaysFullPage = ("6676213", 25)
        // safetyCap=5 → pages 2,3,4,5 POSTed = 4 calls; page 6 not visited.
        let vm = makeVM(templates: templates, screener: screener, safetyCap: 5)

        await vm.autoRunIfNeeded()

        #expect(screener.callCount(for: "6676213") == 4)  // pages 2..5
        #expect(vm.rows.count == 25 + 4 * 25)  // 125
    }
}
