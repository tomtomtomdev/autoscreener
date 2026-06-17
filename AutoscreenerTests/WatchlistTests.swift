import Foundation
import Testing
@testable import Autoscreener

// MARK: - Model

@Suite struct BandarScreenerKindTests {
    /// Pins the rule weights to 2× the `bandar-master.json` spec ratios (Ulysees repo) —
    /// scaled so the minimum weight is 1.0 and composite scores are whole numbers, while
    /// the relative ranking matches the published spec. If any future edit silently
    /// changes these, the watchlist's score loses its link to the published spec.
    @Test func weightsMatchMasterJSONSpec() {
        #expect(BandarScreenerKind.accumulating.weight       == 4.0)
        #expect(BandarScreenerKind.aboveMA20.weight          == 3.0)
        #expect(BandarScreenerKind.shiftToday.weight         == 4.0)
        #expect(BandarScreenerKind.accumDistPositive.weight  == 3.0)
        #expect(BandarScreenerKind.foreignFlow1M.weight      == 2.0)
        #expect(BandarScreenerKind.foreignFlow6M.weight      == 3.0)
        #expect(BandarScreenerKind.foreignFlow3M.weight      == 2.0)
        #expect(BandarScreenerKind.foreignBuyStreak.weight   == 2.0)
        #expect(BandarScreenerKind.freshForeignBuy.weight    == 3.0)
        #expect(BandarScreenerKind.freqSpike.weight          == 2.0)
        #expect(BandarScreenerKind.volumeSpike.weight        == 2.0)
        #expect(BandarScreenerKind.above50MA.weight          == 1.0)
        #expect(BandarScreenerKind.above200MA.weight         == 2.0)
        #expect(BandarScreenerKind.earningsYield.weight      == 2.0)
        #expect(BandarScreenerKind.pbvBelow2.weight          == 2.0)
        #expect(BandarScreenerKind.roeQuality.weight         == 2.0)
        #expect(BandarScreenerKind.fcfPositive.weight        == 2.0)
        #expect(BandarScreenerKind.manageableDebt.weight     == 2.0)
        #expect(BandarScreenerKind.liquidityFloor.weight     == 1.0)
        #expect(BandarScreenerKind.intradayLiquidity.weight  == 1.0)
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
    /// distinct, heavier-weighted (3.0 vs 2.0) smart-money-flow rule — not a veto gate.
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
            #expect(kind.weight == 2.0)
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
        // 2× the spec ratios: 4+3+4+3+2+3+2+2+3 + 2+2+1+2 + 1+1 = 35
        // + fundamentals (5 × 2.0 = 10) = 45
        #expect(BandarScreenerKind.maxCompositeScore == 45.0)
    }
}

@Suite struct WatchlistRowTests {
    @Test func scoreSumsWeightsOfMatchedScreeners() {
        let allFour = WatchlistRow(symbol: "Q", name: "Q",
                                   matchedScreeners: [.accumulating, .aboveMA20, .shiftToday, .accumDistPositive])
        // 4.0 + 3.0 + 4.0 + 3.0 = 14.0
        #expect(allFour.score == 14.0)

        let allThree = WatchlistRow(symbol: "X", name: "X",
                                    matchedScreeners: [.accumulating, .aboveMA20, .shiftToday])
        #expect(allThree.score == 11.0)

        let accAndShift = WatchlistRow(symbol: "Y", name: "Y",
                                       matchedScreeners: [.accumulating, .shiftToday])
        #expect(accAndShift.score == 8.0)

        let aboveOnly = WatchlistRow(symbol: "Z", name: "Z",
                                     matchedScreeners: [.aboveMA20])
        #expect(aboveOnly.score == 3.0)

        let accOnly = WatchlistRow(symbol: "W", name: "W",
                                   matchedScreeners: [.accumulating])
        #expect(accOnly.score == 4.0)

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

/// Snapshots the VM's published row count and completed-screener count at each
/// throttle point — i.e. just before every request after the first. Lets a test
/// prove the table fills in progressively (and the "x/y" progress advances)
/// instead of all at once. MainActor-isolated because it reads the MainActor VM;
/// safe to call from the @Sendable sleeper via `await`.
@MainActor
final class IncrementalRowProbe {
    private(set) var rowCounts: [Int] = []
    private(set) var loadedCounts: [Int] = []
    weak var vm: WatchlistViewModel?
    func snapshot() {
        rowCounts.append(vm?.rows.count ?? -1)
        loadedCounts.append(vm?.loadedScreenerCount ?? -1)
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

// MARK: - Composite compose + veto exclusion

@MainActor
@Suite struct WatchlistComposerTests {
    private func snap(_ kind: BandarScreenerKind, _ symbols: [String]) -> ScreenerSnapshot {
        ScreenerSnapshot(config: WatchlistTestHelpers.config(for: kind.templateID),
                         rows: symbols.map { WatchlistTestHelpers.row($0) },
                         fetchedAt: Date(timeIntervalSince1970: 0))
    }

    /// No veto gates present ⇒ no exclusion: union by symbol, sum the weights.
    @Test func dedupesBySymbolAcrossScreenersUnioningWeights() {
        let result = WatchlistComposer.compose([
            .accumulating: snap(.accumulating, ["BBCA", "BBRI"]),
            .aboveMA20: snap(.aboveMA20, ["BBCA", "CARE"]),
            .shiftToday: snap(.shiftToday, ["BBCA", "BBRI"]),
            .accumDistPositive: snap(.accumDistPositive, ["BBCA", "DSSA"]),
        ])
        let byID = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.symbol, $0) })
        #expect(result.rows.count == 4)
        #expect(byID["BBCA"]?.score == 14.0)  // 4.0+3.0+4.0+3.0
        #expect(byID["BBRI"]?.score == 8.0)   // 4.0+4.0
        #expect(byID["CARE"]?.score == 3.0)
        #expect(byID["DSSA"]?.score == 3.0)
    }

    @Test func sortsByScoreDescThenSymbolAsc() {
        let result = WatchlistComposer.compose([
            .accumulating: snap(.accumulating, ["AAA", "MMM", "ZZZ"]),
            .aboveMA20: snap(.aboveMA20, ["AAA", "ZZZ"]),
            .shiftToday: snap(.shiftToday, ["AAA", "ZZZ"]),
            .accumDistPositive: snap(.accumDistPositive, ["AAA", "ZZZ"]),
        ])
        #expect(result.rows.map(\.symbol) == ["AAA", "ZZZ", "MMM"])  // 14.0, 14.0(tie→symbol), 4.0
    }

    /// With both veto gates present, a stock must appear in BOTH to survive.
    @Test func vetoExclusionDropsStocksMissingFromAnEvaluableGate() {
        let result = WatchlistComposer.compose([
            .accumulating: snap(.accumulating, ["FULL", "HALF", "NONE"]),
            .liquidityFloor: snap(.liquidityFloor, ["FULL", "HALF"]),
            .intradayLiquidity: snap(.intradayLiquidity, ["FULL"]),
        ])
        // FULL is in both gates → survives. HALF misses intraday → dropped. NONE misses both → dropped.
        #expect(result.rows.map(\.symbol) == ["FULL"])
        #expect(result.vetoNotice == nil)  // both gates evaluable
    }

    /// A veto gate with no snapshot isn't enforced (so the list isn't wrongly emptied);
    /// the notice warns which gate was skipped.
    @Test func missingVetoGateIsNotEnforcedAndSurfacesNotice() {
        let result = WatchlistComposer.compose([
            .accumulating: snap(.accumulating, ["FULL", "HALF"]),
            .liquidityFloor: snap(.liquidityFloor, ["FULL", "HALF"]),
            // intradayLiquidity snapshot absent → not enforced.
        ])
        #expect(Set(result.rows.map(\.symbol)) == ["FULL", "HALF"])
        #expect(result.vetoNotice?.contains("Intraday Liquidity") == true)
    }

    @Test func noVetoSnapshotsMeansNoExclusionButNoticeNamesBothGates() {
        let result = WatchlistComposer.compose([.accumulating: snap(.accumulating, ["AAA", "BBB"])])
        #expect(result.rows.count == 2)
        #expect(result.vetoNotice?.contains("Liquidity Floor") == true)
        #expect(result.vetoNotice?.contains("Intraday Liquidity") == true)
    }
}

// MARK: - WatchlistViewModel as a store projection

@MainActor
@Suite struct WatchlistViewModelProjectionTests {
    private func seededStore(_ entries: [(BandarScreenerKind, [String])]) -> ScreenerStore {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        for (kind, symbols) in entries {
            store.apply(ScreenerSnapshot(config: WatchlistTestHelpers.config(for: kind.templateID),
                                         rows: symbols.map { WatchlistTestHelpers.row($0) },
                                         fetchedAt: Date(timeIntervalSince1970: 0)), for: kind)
        }
        return store
    }

    @Test func rowsReflectComposedStoreWithVetoExclusion() {
        let store = seededStore([
            (.accumulating, ["FULL", "HALF"]),
            (.liquidityFloor, ["FULL", "HALF"]),
            (.intradayLiquidity, ["FULL"]),
        ])
        let vm = WatchlistViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store))
        #expect(vm.rows.map(\.symbol) == ["FULL"])
    }

    @Test func rowsRecomputeWhenStoreChanges() {
        let store = seededStore([(.accumulating, ["AAA"])])
        let vm = WatchlistViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store))
        #expect(vm.rows.map(\.symbol) == ["AAA"])  // primes the memo

        store.apply(ScreenerSnapshot(config: WatchlistTestHelpers.config(for: BandarScreenerKind.accumulating.templateID),
                                     rows: [WatchlistTestHelpers.row("AAA"), WatchlistTestHelpers.row("BBB")],
                                     fetchedAt: Date(timeIntervalSince1970: 0)), for: .accumulating)
        #expect(Set(vm.rows.map(\.symbol)) == ["AAA", "BBB"])  // memo invalidated by version bump
    }

    @Test func searchFiltersBySymbol() {
        let store = seededStore([(.accumulating, ["BBCA", "BBRI", "TLKM"])])
        let vm = WatchlistViewModel(store: store, coordinator: SweepTestKit.coordinator(store: store))
        vm.searchText = "bb"
        #expect(Set(vm.visibleRows.map(\.symbol)) == ["BBCA", "BBRI"])
    }

    @Test func refreshTriggersACoordinatorSweep() async {
        let store = ScreenerStore(fileURL: nil, loadFromDisk: false)
        let templates = WatchlistFakeTemplates()
        let coord = SweepTestKit.coordinator(store: store, templates: templates)
        let vm = WatchlistViewModel(store: store, coordinator: coord)

        await vm.refresh()

        #expect(templates.loadCalls.count == 20)
    }
}
