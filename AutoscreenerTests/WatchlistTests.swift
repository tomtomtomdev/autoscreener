import Foundation
import Testing
@testable import Autoscreener

// MARK: - Model

@Suite struct BandarScreenerKindTests {
    /// Pins the rule weights to the values in `bandar-master.json` (Ulysees repo).
    /// If any future edit silently changes these, the watchlist's score loses its
    /// link to the published spec.
    @Test func weightsMatchMasterJSONSpec() {
        #expect(BandarScreenerKind.accumulating.weight       == 2.0)
        #expect(BandarScreenerKind.aboveMA20.weight          == 1.5)
        #expect(BandarScreenerKind.shiftToday.weight         == 2.0)
        #expect(BandarScreenerKind.accumDistPositive.weight  == 1.5)
        #expect(BandarScreenerKind.foreignFlow1M.weight      == 1.0)
        #expect(BandarScreenerKind.foreignFlow6M.weight      == 1.5)
        #expect(BandarScreenerKind.foreignFlow3M.weight      == 1.0)
        #expect(BandarScreenerKind.foreignBuyStreak.weight   == 1.0)
        #expect(BandarScreenerKind.freshForeignBuy.weight    == 1.5)
        #expect(BandarScreenerKind.freqSpike.weight          == 1.0)
        #expect(BandarScreenerKind.volumeSpike.weight        == 1.0)
        #expect(BandarScreenerKind.above50MA.weight          == 0.5)
        #expect(BandarScreenerKind.above200MA.weight         == 1.0)
        #expect(BandarScreenerKind.earningsYield.weight      == 1.0)
        #expect(BandarScreenerKind.pbvBelow2.weight          == 1.0)
        #expect(BandarScreenerKind.roeQuality.weight         == 1.0)
        #expect(BandarScreenerKind.fcfPositive.weight        == 1.0)
        #expect(BandarScreenerKind.manageableDebt.weight     == 1.0)
        #expect(BandarScreenerKind.liquidityFloor.weight     == 0.5)
        #expect(BandarScreenerKind.intradayLiquidity.weight  == 0.5)
    }

    @Test func templateIDsMatchSidebarMapping() {
        // Must match SidebarItem.templateID and ScreenerTemplateService.defaultFilters
        // — otherwise the watchlist fetches a different filter set than the sidebar tabs.
        #expect(BandarScreenerKind.accumulating.templateID      == "6676213")
        #expect(BandarScreenerKind.aboveMA20.templateID         == "6676217")
        #expect(BandarScreenerKind.shiftToday.templateID        == "6676221")
        #expect(BandarScreenerKind.accumDistPositive.templateID == "6676223")
        #expect(BandarScreenerKind.foreignFlow1M.templateID     == "6676225")
        #expect(BandarScreenerKind.foreignFlow6M.templateID     == "6676228")
        #expect(BandarScreenerKind.foreignFlow3M.templateID     == "6676231")
        #expect(BandarScreenerKind.foreignBuyStreak.templateID  == "6676235")
        #expect(BandarScreenerKind.freshForeignBuy.templateID   == "6676238")
        #expect(BandarScreenerKind.freqSpike.templateID         == "6676260")
        #expect(BandarScreenerKind.volumeSpike.templateID       == "6676263")
        #expect(BandarScreenerKind.above50MA.templateID         == "6676264")
        #expect(BandarScreenerKind.above200MA.templateID        == "6676268")
        #expect(BandarScreenerKind.earningsYield.templateID     == "6676273")
        #expect(BandarScreenerKind.pbvBelow2.templateID         == "6676280")
        #expect(BandarScreenerKind.roeQuality.templateID        == "6676288")
        #expect(BandarScreenerKind.fcfPositive.templateID       == "6676291")
        #expect(BandarScreenerKind.manageableDebt.templateID    == "6676292")
        #expect(BandarScreenerKind.liquidityFloor.templateID    == "6676314")
        #expect(BandarScreenerKind.intradayLiquidity.templateID == "6676320")
    }

    /// `fresh-foreign-buy` shares metric 13561 with `foreign-buy-streak` but is a
    /// distinct, heavier-weighted (1.5 vs 1.0) smart-money-flow rule — not a veto gate.
    @Test func freshForeignBuyIsNonVetoSmartMoneyRule() {
        #expect(BandarScreenerKind.freshForeignBuy.isVeto == false)
        #expect(BandarScreenerKind.freshForeignBuy.displayName == "Fresh Foreign Buy")
        // The two liquidity gates remain the only veto kinds.
        #expect(Set(BandarScreenerKind.allCases.filter(\.isVeto)) == [.liquidityFloor, .intradayLiquidity])
    }

    /// The tape-activity (freq/volume spike) and trend (above 50/200 MA) rules are
    /// scored contributors, never veto gates — adding them must not expand the veto
    /// set beyond the two liquidity floors.
    @Test func tapeAndTrendRulesAreNonVeto() {
        #expect(BandarScreenerKind.freqSpike.isVeto == false)
        #expect(BandarScreenerKind.volumeSpike.isVeto == false)
        #expect(BandarScreenerKind.above50MA.isVeto == false)
        #expect(BandarScreenerKind.above200MA.isVeto == false)
        #expect(BandarScreenerKind.freqSpike.displayName == "Frequency Spike")
        #expect(BandarScreenerKind.volumeSpike.displayName == "Volume Spike")
        #expect(BandarScreenerKind.above50MA.displayName == "Above 50MA")
        #expect(BandarScreenerKind.above200MA.displayName == "Above 200MA")
        #expect(Set(BandarScreenerKind.allCases.filter(\.isVeto)) == [.liquidityFloor, .intradayLiquidity])
    }

    /// The five fundamentals (proxseer "(1)" capture) are scored contributors at
    /// weight 1.0 each, group "fundamentals" in `bandar-master.json` — never veto
    /// gates. Adding them must not expand the veto set beyond the two liquidity floors.
    @Test func fundamentalRulesAreNonVetoWeightedOne() {
        for kind in [BandarScreenerKind.earningsYield, .pbvBelow2, .roeQuality, .fcfPositive, .manageableDebt] {
            #expect(kind.weight == 1.0)
            #expect(kind.isVeto == false)
        }
        #expect(BandarScreenerKind.earningsYield.displayName == "Earnings Yield ≥8%")
        #expect(BandarScreenerKind.pbvBelow2.displayName == "PBV ≤2")
        #expect(BandarScreenerKind.roeQuality.displayName == "ROE ≥12%")
        #expect(BandarScreenerKind.fcfPositive.displayName == "Positive FCF")
        #expect(BandarScreenerKind.manageableDebt.displayName == "DER <1.5")
        #expect(Set(BandarScreenerKind.allCases.filter(\.isVeto)) == [.liquidityFloor, .intradayLiquidity])
    }

    /// Regression: when the kind list grows, the WatchlistView toolbar shows the
    /// max possible composite score. Hardcoding it (e.g., "max 5.5") goes stale
    /// the moment a new kind is added — derive from `allCases` instead.
    @Test func maxCompositeScoreSumsAllKindWeights() {
        // 2.0+1.5+2.0+1.5+1.0+1.5+1.0+1.0+1.5 + 1.0+1.0+0.5+1.0 + 0.5+0.5 = 17.5
        // + fundamentals (5 × 1.0 = 5.0) = 22.5
        #expect(BandarScreenerKind.maxCompositeScore == 22.5)
    }
}

@Suite struct WatchlistRowTests {
    @Test func scoreSumsWeightsOfMatchedScreeners() {
        let allFour = WatchlistRow(symbol: "Q", name: "Q",
                                   matchedScreeners: [.accumulating, .aboveMA20, .shiftToday, .accumDistPositive])
        // 2.0 + 1.5 + 2.0 + 1.5 = 7.0
        #expect(allFour.score == 7.0)

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

/// Captures every throttle-delay value the VM emits. Concurrency-safe via actor isolation.
actor SleepRecorder {
    private(set) var delays: [UInt64] = []
    func record(_ ns: UInt64) { delays.append(ns) }
}

/// Sleeper that throws `CancellationError` on its `failAfter`-th call onwards.
/// Simulates the SwiftUI `.task` being torn down mid-bootstrap when the user
/// switches tabs while the throttled four-screener fetch is still running.
final class CancellingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failAfter: Int
    init(failAfter: Int) { self.failAfter = failAfter }
    func tick() throws {
        lock.lock(); count += 1; let n = count; lock.unlock()
        if n >= failAfter { throw CancellationError() }
    }
}

enum WatchlistTestHelpers {
    static func config(for templateID: String) -> ScreenerConfig {
        var c = ScreenerConfig()
        c.screenerID = templateID
        switch templateID {
        case "6676221": c.sequence = [14399, 14425]
        case "6676223": c.sequence = [14400]
        case "6676225": c.sequence = [13580]
        case "6676228": c.sequence = [13582]
        case "6676231": c.sequence = [13581]
        case "6676235": c.sequence = [13561]
        case "6676238": c.sequence = [13561]
        case "6676260": c.sequence = [15396, 15394]
        case "6676263": c.sequence = [12469, 12464]
        case "6676264": c.sequence = [2661, 12460]
        case "6676268": c.sequence = [2661, 12462]
        case "6676273": c.sequence = [2898]
        case "6676280": c.sequence = [2896]
        case "6676288": c.sequence = [1461]
        case "6676291": c.sequence = [2538]
        case "6676292": c.sequence = [1508]
        case "6676314": c.sequence = [16454]
        case "6676320": c.sequence = [13620]
        default:        c.sequence = [14399, 14426]
        }
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
                        safetyCap: Int = 20,
                        sleeper: @escaping WatchlistViewModel.Sleeper = { _ in }) -> WatchlistViewModel {
        WatchlistViewModel(paywall: paywall, templates: templates,
                           screener: screener, safetyCap: safetyCap,
                           sleeper: sleeper)
    }

    @Test func bootstrapFiresPaywallIncrementExactlyOnceAcrossAllFetches() async {
        let paywall = WatchlistFakePaywall()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
            "6676225": .success(WatchlistTestHelpers.initial(for: .foreignFlow1M, rows: [])),
            "6676228": .success(WatchlistTestHelpers.initial(for: .foreignFlow6M, rows: [])),
            "6676231": .success(WatchlistTestHelpers.initial(for: .foreignFlow3M, rows: [])),
        ]
        let vm = makeVM(paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls == [.screener])
        #expect(paywall.incrementCalls == [.screener])
        #expect(Set(templates.loadCalls) == ["6676213", "6676217", "6676221", "6676223", "6676225", "6676228", "6676231", "6676235", "6676238", "6676260", "6676263", "6676264", "6676268", "6676273", "6676280", "6676288", "6676291", "6676292", "6676314", "6676320"])
        #expect(templates.loadCalls.count == 20)
    }

    @Test func dedupesBySymbolAcrossAllScreenersUnioningWeights() async {
        // BBCA returned by all 4 → score 7.0 (2.0+1.5+2.0+1.5).
        // BBRI returned by accumulating + shiftToday → 4.0.
        // CARE returned by aboveMA20 only → 1.5.
        // DSSA returned by accumDistPositive only → 1.5.
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("BBRI")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("CARE")])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("BBRI")])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("DSSA")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        let byID = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.symbol, $0) })
        #expect(vm.rows.count == 4)
        #expect(byID["BBCA"]?.matchedScreeners == [.accumulating, .aboveMA20, .shiftToday, .accumDistPositive])
        #expect(byID["BBCA"]?.score == 7.0)
        #expect(byID["BBRI"]?.matchedScreeners == [.accumulating, .shiftToday])
        #expect(byID["BBRI"]?.score == 4.0)
        #expect(byID["CARE"]?.matchedScreeners == [.aboveMA20])
        #expect(byID["CARE"]?.score == 1.5)
        #expect(byID["DSSA"]?.matchedScreeners == [.accumDistPositive])
        #expect(byID["DSSA"]?.score == 1.5)
    }

    @Test func sortsDescendingByScoreThenAscendingBySymbol() async {
        // AAA and ZZZ both in all 4 (tie 7.0 → AAA first by symbol). MMM in only accumulating (2.0).
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("MMM"), WatchlistTestHelpers.row("ZZZ")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("ZZZ")])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("ZZZ")])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive,
                rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("ZZZ")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.rows.map(\.symbol) == ["AAA", "ZZZ", "MMM"])
    }

    @Test func autoPaginatesEachScreenerUntilPartialPage() async {
        // accumulating: page1=25 (full), page2=25 (full), page3=12 (partial → done).
        // Other three screeners: empty page 1 → no POST.
        let templates = WatchlistFakeTemplates()
        let page1Acc = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1Acc)),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
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
        #expect(screener.callCount(for: "6676223") == 0)
    }

    @Test func partialScreenerFailureKeepsRemainingAndSurfacesError() async {
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .failure(ScreenerError.malformedResponse),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive,
                rows: [WatchlistTestHelpers.row("BBCA")])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        #expect(vm.rows.count == 1)
        #expect(vm.rows.first?.matchedScreeners == [.accumulating, .shiftToday, .accumDistPositive])
        // 2.0 + 2.0 + 1.5 = 5.5 (aboveMA20's 1.5 missing due to failure)
        #expect(vm.rows.first?.score == 5.5)
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
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
            "6676225": .success(WatchlistTestHelpers.initial(for: .foreignFlow1M, rows: [])),
            "6676228": .success(WatchlistTestHelpers.initial(for: .foreignFlow6M, rows: [])),
            "6676231": .success(WatchlistTestHelpers.initial(for: .foreignFlow3M, rows: [])),
        ]
        let vm = makeVM(paywall: paywall, templates: templates)

        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()
        await vm.autoRunIfNeeded()

        #expect(paywall.checkCalls.count == 1)
        #expect(paywall.incrementCalls.count == 1)
        #expect(templates.loadCalls.count == 20)
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
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
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
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
        ]
        let screener = WatchlistFakeScreener()
        screener.alwaysFullPage = ("6676213", 25)
        // safetyCap=5 → pages 2,3,4,5 POSTed = 4 calls; page 6 not visited.
        let vm = makeVM(templates: templates, screener: screener, safetyCap: 5)

        await vm.autoRunIfNeeded()

        #expect(screener.callCount(for: "6676213") == 4)  // pages 2..5
        #expect(vm.rows.count == 25 + 4 * 25)  // 125
    }

    /// Throttle: every outgoing screener request except the very first one in a
    /// bootstrap is preceded by a randomized 1000–1500ms sleep. This holds *across*
    /// kinds (gap between kind A's last page and kind B's page 1) AND *within* a
    /// kind (gap between page N and page N+1). Stockbit has rate-limited bursts
    /// in the past; the pacing keeps a 4-screener watchlist fetch under the radar.
    @Test func throttlesEveryRequestExceptFirstWithRandomizedDelay() async {
        // accumulating: page 1 full (25) + page 2 partial (5 → done) = 2 requests
        // 19 other kinds: empty page 1 → 1 request each
        // Total = 21 requests → 20 throttled sleeps.
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
            "6676225": .success(WatchlistTestHelpers.initial(for: .foreignFlow1M, rows: [])),
            "6676228": .success(WatchlistTestHelpers.initial(for: .foreignFlow6M, rows: [])),
            "6676231": .success(WatchlistTestHelpers.initial(for: .foreignFlow3M, rows: [])),
        ]
        let screener = WatchlistFakeScreener()
        screener.pages["6676213"] = [
            2: (0..<5).map { WatchlistTestHelpers.row("ACC2_\($0)") },  // partial → done
        ]
        let recorder = SleepRecorder()
        let vm = makeVM(templates: templates, screener: screener,
                        sleeper: { ns in await recorder.record(ns) })

        await vm.autoRunIfNeeded()

        let delays = await recorder.delays
        #expect(delays.count == 20)
        #expect(delays.allSatisfy { (1_000_000_000...1_500_000_000).contains($0) })
    }

    /// Regression: SwiftUI's `.task` modifier cancels its task when the view
    /// disappears, which throws `CancellationError` from `Task.sleep` inside the
    /// throttle. Before the fix, that error became "Couldn't load: Bandar Shift
    /// Today (CancellationError()) · Accum/Dist Positive (CancellationError())"
    /// in the user-facing banner. The fix: treat cancellation as internal noise
    /// — keep partial rows visible, suppress the banner, and reset `didAutoRun`
    /// so the next view appearance retries from scratch.
    @Test func cancellationMidBootstrapDoesNotSurfaceAsUserFacingError() async {
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday,
                rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive,
                rows: [WatchlistTestHelpers.row("BBCA")])),
        ]
        // First two GETs use throttle calls #1 (skipped, first request) and #2
        // (success), then throttle #3 (the gap before shiftToday's GET) throws —
        // mirrors the user's screenshot where the first two kinds completed.
        let canceller = CancellingSleeper(failAfter: 2)
        let sleeper: WatchlistViewModel.Sleeper = { _ in try canceller.tick() }
        let vm = makeVM(templates: templates, sleeper: sleeper)

        await vm.autoRunIfNeeded()

        // No user-facing banner mentioning the cancellation.
        #expect(vm.error == nil)
        // BBCA matched accumulating (2.0) + aboveMA20 (1.5) before cancellation.
        #expect(vm.rows.first?.symbol == "BBCA")
        #expect(vm.rows.first?.score == 3.5)
        // didAutoRun reset so the next view-appearance retries from scratch.
        // Verified indirectly: a fresh autoRunIfNeeded re-loads all four templates.
        await vm.autoRunIfNeeded()
        #expect(templates.loadCalls.filter { $0 == "6676213" }.count == 2)
    }

    /// Serialisation regression: replacing the `async let` fan-out with a sequential
    /// loop must keep the deterministic kind order (accumulating → aboveMA20 →
    /// shiftToday → accumDistPositive → foreignFlow1M → foreignFlow6M →
    /// foreignFlow3M → foreignBuyStreak → freshForeignBuy → freqSpike →
    /// volumeSpike → above50MA → above200MA → earningsYield → pbvBelow2 →
    /// roeQuality → fcfPositive → manageableDebt → liquidityFloor →
    /// intradayLiquidity).
    /// If a future refactor accidentally reverses or interleaves, this asserts the
    /// contract.
    @Test func fetchesScreenersSequentiallyInDeclaredOrder() async {
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [])),
            "6676221": .success(WatchlistTestHelpers.initial(for: .shiftToday, rows: [])),
            "6676223": .success(WatchlistTestHelpers.initial(for: .accumDistPositive, rows: [])),
            "6676225": .success(WatchlistTestHelpers.initial(for: .foreignFlow1M, rows: [])),
            "6676228": .success(WatchlistTestHelpers.initial(for: .foreignFlow6M, rows: [])),
            "6676231": .success(WatchlistTestHelpers.initial(for: .foreignFlow3M, rows: [])),
        ]
        let vm = makeVM(templates: templates)

        await vm.autoRunIfNeeded()

        #expect(templates.loadCalls == ["6676213", "6676217", "6676221", "6676223", "6676225", "6676228", "6676231", "6676235", "6676238", "6676260", "6676263", "6676264", "6676268", "6676273", "6676280", "6676288", "6676291", "6676292", "6676314", "6676320"])
    }
}

// MARK: - Cache-aggregation (scheduled modes)

/// Under any non-onDemand schedule the per-screener caches are kept fresh by the
/// ScreenerScheduler, so the watchlist composes from those caches instead of
/// re-running its own throttled network fan-out. These tests pin that routing.
@MainActor
@Suite struct WatchlistCacheAggregationTests {
    private func seed(_ store: FakeSnapshotStore, _ kind: BandarScreenerKind,
                      rows: [String], fetchedAt: Date = Date(timeIntervalSince1970: 1_000)) {
        store.seedScreener(ScreenerSnapshot(
            templateID: kind.templateID,
            config: WatchlistTestHelpers.config(for: kind.templateID),
            rows: rows.map { WatchlistTestHelpers.row($0) },
            total: nil,
            fetchedAt: fetchedAt))
    }

    private func makeVM(store: FakeSnapshotStore,
                        templates: WatchlistFakeTemplates,
                        screener: WatchlistFakeScreener = WatchlistFakeScreener(),
                        paywall: WatchlistFakePaywall = WatchlistFakePaywall()) -> WatchlistViewModel {
        WatchlistViewModel(paywall: paywall, templates: templates, screener: screener,
                           snapshots: store, sleeper: { _ in })
    }

    /// `aggregateFromCache` unions the per-screener caches by symbol and scores by
    /// weight — with **zero** template/network calls. AAA is in both caches
    /// (accumulating 2.0 + freqSpike 1.0 = 3.0); BBB only in freqSpike (1.0).
    @Test func aggregateFromCacheUnionsCachesWithoutNetwork() async {
        let store = FakeSnapshotStore()
        let templates = WatchlistFakeTemplates()
        seed(store, .accumulating, rows: ["AAA"])
        seed(store, .freqSpike, rows: ["AAA", "BBB"])
        let vm = makeVM(store: store, templates: templates)

        let found = await vm.aggregateFromCache()

        #expect(found == true)
        #expect(templates.loadCalls.isEmpty)             // no network
        #expect(vm.rows.map(\.symbol) == ["AAA", "BBB"]) // 3.0 then 1.0
        #expect(vm.rows.first?.score == 3.0)
        #expect(vm.rows.first?.matchedScreeners == [.accumulating, .freqSpike])
        // Composite persisted for instant boot next launch.
        let saved = await store.loadWatchlist()
        #expect(saved?.rows.count == 2)
    }

    /// Cold start — no caches yet — returns false so callers can populate first.
    @Test func aggregateFromCacheReturnsFalseWhenNoCaches() async {
        let store = FakeSnapshotStore()
        let vm = makeVM(store: store, templates: WatchlistFakeTemplates())

        let found = await vm.aggregateFromCache()

        #expect(found == false)
        #expect(vm.rows.isEmpty)
    }

    /// Under a schedule (persistence enabled) with warm caches, `refresh()` must NOT
    /// touch the network — it just re-unions the per-screener caches. This is the
    /// core "watchlist doesn't fetch in sequence, it aggregates local cache" contract.
    @Test func refreshUnderScheduleAggregatesFromCacheWithoutFetching() async {
        let store = FakeSnapshotStore()  // enabled == true by default
        let templates = WatchlistFakeTemplates()
        let paywall = WatchlistFakePaywall()
        seed(store, .accumulating, rows: ["AAA", "CCC"])
        seed(store, .volumeSpike, rows: ["AAA"])
        let vm = makeVM(store: store, templates: templates, paywall: paywall)

        await vm.refresh()

        #expect(templates.loadCalls.isEmpty)                  // no sequential fetch
        #expect(paywall.incrementCalls.isEmpty)               // no paywall hit either
        #expect(Set(vm.rows.map(\.symbol)) == ["AAA", "CCC"])
    }

    /// Cold start under a schedule: `refresh()` has no caches to union, so it falls
    /// back to one populate (throttled fan-out → writes caches) and then aggregates.
    @Test func refreshUnderScheduleColdStartPopulatesThenAggregates() async {
        let store = FakeSnapshotStore()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                                                             rows: [WatchlistTestHelpers.row("AAA")])),
        ]
        let vm = makeVM(store: store, templates: templates)

        await vm.refresh()

        // Populated every screener cache (20 template loads) on the cold path...
        #expect(templates.loadCalls.count == 20)
        // ...and the freshly-written cache is now readable + composed.
        #expect(await store.loadScreener(templateID: "6676213")?.rows.count == 1)
        #expect(vm.rows.map(\.symbol) == ["AAA"])
    }

    /// The scheduler entry point fetches every per-screener cache (throttled), then
    /// rebuilds the composite from those caches and persists `watchlist.json`.
    @Test func scheduledRefreshFetchesEachCacheThenAggregates() async {
        let store = FakeSnapshotStore()
        let templates = WatchlistFakeTemplates()
        let paywall = WatchlistFakePaywall()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                                                             rows: [WatchlistTestHelpers.row("AAA")])),
            "6676263": .success(WatchlistTestHelpers.initial(for: .volumeSpike,
                                                             rows: [WatchlistTestHelpers.row("AAA")])),
        ]
        let vm = makeVM(store: store, templates: templates, paywall: paywall)

        await vm.scheduledRefresh()

        #expect(templates.loadCalls.count == 20)        // fetched every screener
        #expect(paywall.incrementCalls.count == 1)      // one increment for the sweep
        #expect(await store.loadScreener(templateID: "6676213")?.rows.count == 1)  // cached
        // AAA matched by accumulating (2.0) + volumeSpike (1.0) = 3.0.
        #expect(vm.rows.map(\.symbol) == ["AAA"])
        #expect(vm.rows.first?.score == 3.0)
        #expect(await store.loadWatchlist()?.rows.count == 1)
    }

    /// Regression: a veto gate whose cache is **stale** (an older generation than the
    /// rest — e.g. the scheduler refreshed 19/20 screeners but failed/cancelled before
    /// the last gate) must NOT be enforced. Otherwise every liquid name is missing that
    /// gate and gets falsely flagged ILLIQUID — the "watchlist shows all illiquid" bug.
    @Test func staleVetoGateMustNotFlagLiquidNamesIlliquid() async {
        let store = FakeSnapshotStore()
        let fresh = Date(timeIntervalSince1970: 2_000)
        let stale = Date(timeIntervalSince1970: 1_000)
        seed(store, .accumulating, rows: ["AAA", "BBB"], fetchedAt: fresh)
        seed(store, .liquidityFloor, rows: ["AAA", "BBB"], fetchedAt: fresh)
        seed(store, .intradayLiquidity, rows: ["OLD"], fetchedAt: stale)  // not refreshed this gen
        let vm = makeVM(store: store, templates: WatchlistFakeTemplates())

        await vm.aggregateFromCache()

        // AAA/BBB pass the fresh floor gate; the intraday gate is stale → not enforced.
        #expect(vm.rows.first { $0.symbol == "AAA" }?.isVetoed == false)
        #expect(vm.rows.first { $0.symbol == "BBB" }?.isVetoed == false)
        // The skipped gate is surfaced so the user knows liquidity isn't fully enforced.
        #expect(vm.vetoNotice != nil)
    }

    /// A veto gate that IS in the current generation still flags names missing from it.
    /// AAA passes both fresh gates; BBB is absent from the fresh floor gate → ILLIQUID.
    @Test func freshVetoGateStillFlagsNamesMissingFromIt() async {
        let store = FakeSnapshotStore()
        let t = Date(timeIntervalSince1970: 2_000)
        seed(store, .accumulating, rows: ["AAA", "BBB"], fetchedAt: t)
        seed(store, .liquidityFloor, rows: ["AAA"], fetchedAt: t)        // BBB misses the floor
        seed(store, .intradayLiquidity, rows: ["AAA", "BBB"], fetchedAt: t)  // both pass intraday
        let vm = makeVM(store: store, templates: WatchlistFakeTemplates())

        await vm.aggregateFromCache()

        #expect(vm.rows.first { $0.symbol == "AAA" }?.isVetoed == false)
        #expect(vm.rows.first { $0.symbol == "BBB" }?.isVetoed == true)
        // BBB fails ONLY the floor gate (it's in intraday) — both gates were evaluated.
        #expect(vm.rows.first { $0.symbol == "BBB" }?.failedVetoGates == [.liquidityFloor])
        #expect(vm.vetoNotice == nil)  // both gates fresh → fully enforced
    }

    /// On-demand (persistence disabled) keeps the legacy live fan-out: a manual
    /// refresh fetches every screener over the network, never the cache shortcut.
    @Test func onDemandRefreshStillLiveFansOut() async {
        let store = FakeSnapshotStore()
        store.enabled = false  // onDemand: no persistence
        let templates = WatchlistFakeTemplates()
        // Seed a cache that MUST be ignored on the on-demand path.
        seed(store, .accumulating, rows: ["STALE"])
        let vm = makeVM(store: store, templates: templates)

        await vm.refresh()

        #expect(templates.loadCalls.count == 20)             // live fan-out
        #expect(!vm.rows.contains { $0.symbol == "STALE" })  // cache not used
    }
}
