import Foundation
import Testing
@testable import Autoscreener

/// Records every symbol a quote was requested for, so the market-quote tests can
/// assert which catalog groups a sweep priced. Tolerates per-symbol failure.
final class RecordingCommodityService: CommodityPriceServicing, @unchecked Sendable {
    var failingSymbols: Set<String> = []
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func quote(symbol: String) async throws -> CommodityQuote {
        lock.lock(); _calls.append(symbol); lock.unlock()
        if failingSymbols.contains(symbol) { throw CommodityPriceError.network("boom") }
        return CommodityQuote(
            symbol: symbol, name: symbol, price: 100, previousClose: 99,
            change: 1, changePercent: 1.0, volume: 10, formattedPrice: "100", asOf: "now")
    }
}

/// Shared makers for the sweep/store tests. Reuses the lock-protected fan-out fakes
/// (`WatchlistFakePaywall`/`Templates`/`Screener`) and `WatchlistTestHelpers` defined
/// in `WatchlistTests.swift`. Market + regime legs default to off (`catalog: []`) so
/// the screener-focused tests below exercise exactly the screener path.
@MainActor
enum SweepTestKit {
    nonisolated static func jakarta(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    /// Thu 2026-06-11 10:00 WIB → inside session 1.
    nonisolated static func openClock() -> MarketClock { MarketClock(now: { jakarta(2026, 6, 11, 10, 0) }) }
    /// Sat 2026-06-13 10:00 WIB → weekend, closed.
    nonisolated static func closedClock() -> MarketClock { MarketClock(now: { jakarta(2026, 6, 13, 10, 0) }) }

    static func store() -> ScreenerStore { ScreenerStore(fileURL: nil, loadFromDisk: false) }
    static func marketStore() -> MarketDataStore { MarketDataStore(fileURL: nil, loadFromDisk: false) }

    static func coordinator(store: ScreenerStore,
                            marketStore: MarketDataStore? = nil,
                            paywall: WatchlistFakePaywall = WatchlistFakePaywall(),
                            templates: WatchlistFakeTemplates = WatchlistFakeTemplates(),
                            screener: WatchlistFakeScreener = WatchlistFakeScreener(),
                            commodity: any CommodityPriceServicing = StubCommodityPriceService(),
                            chart: any ChartServicing = StubChartService(),
                            flow: any AggregateForeignFlowServicing = AggregateForeignFlowService(flowService: StubForeignFlowService()),
                            snapshotProvider: any RegimeSnapshotProviding = StubRegimeSnapshotService(),
                            biRateProvider: any BIRateProviding = StubBIRateService(),
                            macroProvider: any FREDMacroProviding = StubFREDMacroService(),
                            catalog: [MarketSymbol] = [],
                            constituents: [String] = LQ45Constituents.symbols,
                            clock: MarketClock = SweepTestKit.openClock(),
                            runsContinuousLoop: Bool = false,
                            safetyCap: Int = 20,
                            openGapRange: ClosedRange<UInt64> = 300_000_000_000...600_000_000_000,
                            closedGapRange: ClosedRange<UInt64> = 1_200_000_000_000...1_800_000_000_000,
                            macroTTL: TimeInterval = 12 * 60 * 60,
                            sleeper: @escaping DataSweepCoordinator.Sleeper = { _ in }) -> DataSweepCoordinator {
        DataSweepCoordinator(
            store: store, marketStore: marketStore ?? MarketDataStore(fileURL: nil, loadFromDisk: false),
            clock: clock,
            paywall: paywall, templates: templates, screener: screener,
            commodity: commodity, chart: chart, flow: flow, snapshotProvider: snapshotProvider,
            biRateProvider: biRateProvider, macroProvider: macroProvider,
            catalog: catalog, constituents: constituents,
            runsContinuousLoop: runsContinuousLoop, safetyCap: safetyCap,
            openGapRange: openGapRange, closedGapRange: closedGapRange, macroTTL: macroTTL, sleeper: sleeper)
    }

    static let orderedTemplateIDs = [
        "6676213", "6676217", "6676221", "6676223", "6676225", "6676228", "6676231",
        "6676235", "6676238", "6676260", "6676263", "6676264", "6676268", "6676273",
        "6676280", "6676288", "6676291", "6676292", "6676314", "6676320",
    ]

    /// A small Markets catalog spanning both cadence buckets — IDX-session groups
    /// (composite/sector) and around-the-clock groups (global/commodity/currency).
    static let mixedCatalog: [MarketSymbol] = [
        MarketSymbol(symbol: "SP500", name: "S&P 500", group: .global),
        MarketSymbol(symbol: "XAU", name: "Gold", group: .commodity),
        MarketSymbol(symbol: "USDIDR", name: "USD/IDR", group: .currency),
        MarketSymbol(symbol: "IHSG", name: "Composite", group: .composite),
        MarketSymbol(symbol: "IDXENERGY", name: "Energy", group: .sector),
    ]
}

@MainActor
@Suite struct DataSweepCoordinatorScreenerTests {

    @Test func sweepFiresPaywallOnceAndLoadsAllTwentyInDeclaredOrder() async {
        let paywall = WatchlistFakePaywall()
        let templates = WatchlistFakeTemplates()
        let coord = SweepTestKit.coordinator(store: SweepTestKit.store(), paywall: paywall, templates: templates)

        await coord.runSweep()

        #expect(paywall.checkCalls == [.screener])
        #expect(paywall.incrementCalls == [.screener])
        #expect(templates.loadCalls == SweepTestKit.orderedTemplateIDs)
        #expect(coord.loadedScreenerCount == 20)
    }

    @Test func sweepWritesEachKindSnapshotIntoStore() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating,
                rows: [WatchlistTestHelpers.row("BBCA"), WatchlistTestHelpers.row("BBRI")])),
            "6676320": .success(WatchlistTestHelpers.initial(for: .intradayLiquidity,
                rows: [WatchlistTestHelpers.row("BBCA")])),
        ]
        let coord = SweepTestKit.coordinator(store: store, templates: templates)

        await coord.runSweep()

        #expect(store.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA", "BBRI"])
        #expect(store.snapshot(for: .intradayLiquidity)?.rows.map(\.symbol) == ["BBCA"])
        #expect(store.lastSweepAt != nil)
    }

    @Test func storeVersionBumpsOncePerSuccessfulKind() async {
        let store = SweepTestKit.store()
        let v0 = store.version
        let coord = SweepTestKit.coordinator(store: store)  // all 20 succeed (empty rows)

        await coord.runSweep()

        // 20 successful applies + one markSweepComplete (no version bump) → +20.
        #expect(store.version == v0 + 20)
    }

    @Test func paginatesEachScreenerUntilPartialPage() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
        ]
        let screener = WatchlistFakeScreener()
        screener.pages["6676213"] = [
            2: (0..<25).map { WatchlistTestHelpers.row("ACC2_\($0)") },
            3: (0..<12).map { WatchlistTestHelpers.row("ACC3_\($0)") },  // partial → done
        ]
        let coord = SweepTestKit.coordinator(store: store, templates: templates, screener: screener)

        await coord.runSweep()

        #expect(store.snapshot(for: .accumulating)?.rows.count == 62)  // 25 + 25 + 12
        #expect(screener.callCount(for: "6676213") == 2)               // pages 2 and 3
    }

    @Test func safetyCapBoundsPagesPerScreener() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("P1_\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
        ]
        let screener = WatchlistFakeScreener()
        screener.alwaysFullPage = ("6676213", 25)  // never partial → cap must stop it
        let coord = SweepTestKit.coordinator(store: store, templates: templates, screener: screener, safetyCap: 5)

        await coord.runSweep()

        #expect(screener.callCount(for: "6676213") == 4)               // pages 2..5
        #expect(store.snapshot(for: .accumulating)?.rows.count == 25 + 4 * 25)
    }

    @Test func throttlesEveryRequestExceptTheFirstWithRandomizedDelay() async {
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
        ]
        let screener = WatchlistFakeScreener()
        screener.pages["6676213"] = [2: (0..<5).map { WatchlistTestHelpers.row("ACC2_\($0)") }]  // partial
        let recorder = SleepRecorder()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), templates: templates, screener: screener,
            sleeper: { ns in await recorder.record(ns) })

        await coord.runSweep()

        // accumulating: 2 requests (page1 GET + page2 POST). 19 other kinds: 1 GET each.
        // Total 21 requests → 20 throttled sleeps (the very first request is free).
        // Market + regime legs are off (catalog == []).
        let delays = await recorder.delays
        #expect(delays.count == 20)
        #expect(delays.allSatisfy { (1_000_000_000...1_500_000_000).contains($0) })
    }

    /// Snapshots the coordinator's `isThrottling` flag at each throttle point — i.e. from
    /// inside the sleeper, which `throttle()` only enters after setting the flag. MainActor-
    /// isolated because it reads the MainActor coordinator; safe to call from the @Sendable
    /// sleeper via `await`. Same shape as `IncrementalRowProbe`.
    @MainActor
    final class ThrottleFlagProbe {
        private(set) var flags: [Bool] = []
        weak var coord: DataSweepCoordinator?
        func snapshot() { flags.append(coord?.isThrottling ?? false) }
    }

    @Test func throttleGapRaisesTheThrottlingFlagThenResetsIt() async {
        let probe = ThrottleFlagProbe()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(),
            sleeper: { _ in await probe.snapshot() })
        probe.coord = coord

        #expect(coord.isThrottling == false)   // idle before the sweep starts

        await coord.runSweep()

        // The 20-kind fan-out (single page each) throttles before every request but the
        // first → 19 gaps, and the flag was up inside every one of them.
        #expect(probe.flags.count == 19)
        #expect(probe.flags.allSatisfy { $0 })
        #expect(coord.isThrottling == false)   // reset once the sweep settles
    }

    /// Snapshots `currentPage` from inside the sleeper, same shape as `ThrottleFlagProbe`.
    @MainActor
    final class CurrentPageProbe {
        private(set) var pages: [Int] = []
        weak var coord: DataSweepCoordinator?
        func snapshot() { pages.append(coord?.currentPage ?? -1) }
    }

    @Test func currentPageTracksPaginationThenResetsAfterTheFanOut() async {
        let templates = WatchlistFakeTemplates()
        let page1 = (0..<25).map { WatchlistTestHelpers.row("ACC\($0)") }
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: page1)),
        ]
        let screener = WatchlistFakeScreener()
        screener.pages["6676213"] = [
            2: (0..<25).map { WatchlistTestHelpers.row("ACC2_\($0)") },
            3: (0..<12).map { WatchlistTestHelpers.row("ACC3_\($0)") },  // partial → done
        ]
        let probe = CurrentPageProbe()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), templates: templates, screener: screener,
            sleeper: { _ in await probe.snapshot() })
        probe.coord = coord

        await coord.runSweep()

        // accumulating's page-1 GET is the free first request (no throttle snapshot); its
        // pages 2 and 3 throttle at currentPage 2 then 3. The remaining 19 screeners each
        // fetch a single page-1 GET, throttled at currentPage 1.
        #expect(probe.pages == [2, 3] + Array(repeating: 1, count: 19))
        #expect(coord.currentPage == 0)   // cleared once the screener fan-out ends
    }

    @Test func cancellationMidSweepKeepsPartialSnapshotsAndSurfacesNoError() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .success(WatchlistTestHelpers.initial(for: .aboveMA20, rows: [WatchlistTestHelpers.row("BBCA")])),
        ]
        // First request is free (#1 skipped); throttle #2 succeeds; throttle #3 (before
        // shiftToday's GET) throws — so accumulating + aboveMA20 land, then we stop.
        let canceller = CancellingSleeper(failAfter: 2)
        let coord = SweepTestKit.coordinator(
            store: store, templates: templates, sleeper: { _ in try canceller.tick() })

        await coord.runSweep()

        #expect(store.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA"])
        #expect(store.snapshot(for: .aboveMA20)?.rows.map(\.symbol) == ["BBCA"])
        #expect(store.snapshot(for: .shiftToday) == nil)  // never reached
        #expect(coord.lastError == nil)                   // cancellation is internal noise
    }

    @Test func partialScreenerFailureSurfacesErrorButKeepsOthers() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        templates.resultsByTemplateID = [
            "6676213": .success(WatchlistTestHelpers.initial(for: .accumulating, rows: [WatchlistTestHelpers.row("BBCA")])),
            "6676217": .failure(ScreenerError.malformedResponse),
        ]
        let coord = SweepTestKit.coordinator(store: store, templates: templates)

        await coord.runSweep()

        #expect(store.snapshot(for: .accumulating)?.rows.map(\.symbol) == ["BBCA"])
        #expect(store.snapshot(for: .aboveMA20) == nil)
        #expect(coord.lastError?.contains("Bandar Above MA20") == true)
    }

    @Test func refreshNowRunsExactlyOneSweep() async {
        let paywall = WatchlistFakePaywall()
        let templates = WatchlistFakeTemplates()
        let coord = SweepTestKit.coordinator(store: SweepTestKit.store(), paywall: paywall, templates: templates)

        await coord.refreshNow()

        #expect(templates.loadCalls.count == 20)
        #expect(paywall.incrementCalls.count == 1)
    }

    /// Exercises the exact `-UITestFixtures` seeding path headlessly: the real stub
    /// services feed a single sweep, and the composite excludes GOTO (absent from the
    /// intraday-liquidity veto gate). Mirrors what `WatchlistUITests` asserts in the GUI.
    @Test func fixtureStubsSeedStoreAndVetoExcludesGOTO() async {
        let store = SweepTestKit.store()
        let coord = DataSweepCoordinator(
            store: store, marketStore: SweepTestKit.marketStore(), clock: SweepTestKit.openClock(),
            paywall: StubPaywallService(),
            templates: StubScreenerTemplateService(),
            screener: StubScreenerService(),
            commodity: StubCommodityPriceService(),
            chart: StubChartService(),
            flow: AggregateForeignFlowService(flowService: StubForeignFlowService()),
            snapshotProvider: StubRegimeSnapshotService(),
            biRateProvider: StubBIRateService(), macroProvider: StubFREDMacroService(),
            catalog: [],   // screener-only path under test
            runsContinuousLoop: false, sleeper: { _ in })

        await coord.runSweep()

        let symbols = Set(WatchlistComposer.compose(store.snapshots).rows.map(\.symbol))
        #expect(symbols.contains("BBCA"))
        #expect(symbols.contains("TLKM"))
        #expect(!symbols.contains("GOTO"))  // fails the intraday-liquidity veto → excluded
    }

    // MARK: - Market-hours loop

    /// A sleeper that throws on the long inter-sweep gap sleeps (≥100s) but lets the
    /// short throttle sleeps through — so the loop runs exactly one full sweep before
    /// terminating on the gap.
    private func gapCancellingSleeper() -> DataSweepCoordinator.Sleeper {
        { ns in if ns >= 100_000_000_000 { throw CancellationError() } }
    }

    @Test func openMarketRunsASweepThenTheLoopEndsOnTheGapSleep() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        let coord = SweepTestKit.coordinator(
            store: store, templates: templates, clock: SweepTestKit.openClock(),
            runsContinuousLoop: true, sleeper: gapCancellingSleeper())

        await coord.runLoop()

        #expect(templates.loadCalls.count == 20)  // one full sweep happened
        #expect(store.lastSweepAt != nil)
    }

    @Test func closedMarketDoesNotFetchScreeners() async {
        let store = SweepTestKit.store()
        let templates = WatchlistFakeTemplates()
        let coord = SweepTestKit.coordinator(
            store: store, templates: templates, clock: SweepTestKit.closedClock(),
            runsContinuousLoop: true, sleeper: gapCancellingSleeper())

        await coord.runLoop()  // closed → screeners skipped, then the slow gap sleep throws

        #expect(templates.loadCalls.isEmpty)
        #expect(store.lastSweepAt == nil)
    }

    @Test func closedLoopWaitsTheSlowerGap() async {
        let recorder = SleepRecorder()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), clock: SweepTestKit.closedClock(),
            runsContinuousLoop: true,
            closedGapRange: 1_234_000_000_000...1_234_000_000_000,
            sleeper: { ns in await recorder.record(ns); if ns >= 100_000_000_000 { throw CancellationError() } })

        await coord.runLoop()

        let delays = await recorder.delays
        #expect(delays == [1_234_000_000_000])  // one closed-cadence gap, then the loop ends
    }
}

@MainActor
@Suite struct DataSweepCoordinatorMarketTests {

    @Test func openSweepPricesEveryCatalogSymbol() async {
        let commodity = RecordingCommodityService()
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            commodity: commodity, catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)

        #expect(Set(commodity.calls) == ["SP500", "XAU", "USDIDR", "IHSG", "IDXENERGY"])
        #expect(marketStore.quotes.count == 5)
        #expect(marketStore.lastSweepAt != nil)
    }

    @Test func closedSweepPricesAroundTheClockGroupsOnly() async {
        let commodity = RecordingCommodityService()
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            commodity: commodity, catalog: SweepTestKit.mixedCatalog,
            clock: SweepTestKit.closedClock())

        await coord.runSweep(includeIDX: false)

        // IDX-session groups (composite/sector) are frozen; global/commodity/FX refresh.
        #expect(Set(commodity.calls) == ["SP500", "XAU", "USDIDR"])
        #expect(marketStore.quotes["IHSG"] == nil)
        #expect(marketStore.quotes["IDXENERGY"] == nil)
    }

    @Test func failedSymbolKeepsItsPriorQuote() async {
        let commodity = RecordingCommodityService()
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            commodity: commodity, catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)              // seed all five
        commodity.failingSymbols = ["XAU"]
        await coord.runSweep(includeIDX: true)              // XAU fails this round

        #expect(marketStore.quotes["XAU"] != nil)           // prior value retained
        #expect(marketStore.quotes.count == 5)
    }

    @Test func marketQuotesAreThrottledSeriallyAfterTheFirst() async {
        let recorder = SleepRecorder()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), commodity: RecordingCommodityService(),
            catalog: SweepTestKit.mixedCatalog, clock: SweepTestKit.closedClock(),
            sleeper: { ns in await recorder.record(ns) })

        // Closed + includeIDX false → 3 around-the-clock quotes, no screeners/regime.
        await coord.runSweep(includeIDX: false)

        let delays = await recorder.delays
        #expect(delays.count == 2)  // 3 quotes → first free, 2 throttled
        #expect(delays.allSatisfy { (1_000_000_000...1_500_000_000).contains($0) })
    }
}

@MainActor
@Suite struct DataSweepCoordinatorRegimeTests {

    /// Configures the `.above200MA` screener (template 6676268) to return LQ45 names so
    /// the derived breadth factor has something to count.
    private func templatesWithAbove200MA(_ symbols: [String]) -> WatchlistFakeTemplates {
        let t = WatchlistFakeTemplates()
        t.resultsByTemplateID = [
            "6676268": .success(WatchlistTestHelpers.initial(
                for: .above200MA, rows: symbols.map { WatchlistTestHelpers.row($0) })),
        ]
        return t
    }

    @Test func openSweepComposesAndWritesTheRegimeRead() async {
        let marketStore = SweepTestKit.marketStore()
        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            templates: templatesWithAbove200MA(["BBCA", "TLKM", "BMRI"]),
            catalog: SweepTestKit.mixedCatalog)

        await coord.runSweep(includeIDX: true)

        let read = marketStore.regimeRead
        #expect(read != nil)
        // Breadth is derived from the .above200MA snapshot the same sweep collected.
        #expect(read?.factors.contains { $0.kind == .breadth } == true)
        // Valuation + BI rate come from the stub regime snapshot.
        #expect(read?.factors.contains { $0.kind == .valuation } == true)
    }

    @Test func closedSweepLeavesTheRegimeReadFrozen() async {
        let marketStore = SweepTestKit.marketStore()
        let frozen = RegimeRead(stance: .riskOn, score: 0.5, factors: [], asOf: "2026-06-10", valuationCapped: false)
        marketStore.apply(regimeRead: frozen)

        let coord = SweepTestKit.coordinator(
            store: SweepTestKit.store(), marketStore: marketStore,
            catalog: SweepTestKit.mixedCatalog, clock: SweepTestKit.closedClock())

        await coord.runSweep(includeIDX: false)

        #expect(marketStore.regimeRead == frozen)  // regime is an IDX-session read; not recomputed when closed
    }
}
