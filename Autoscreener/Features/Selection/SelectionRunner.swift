import Foundation

// Thin, headless Tier-A entry point (§8 "app wiring", post-Phase-3). It composes a candidate-universe
// source with an engine factory and runs `StockSelectionEngine` over the sourced universe, returning
// the ranked, audited `Recommendation`s.
//
// §10 universe decision: the candidate set is **the composite Watchlist** (the ranked union of the
// 20 screeners). `AppDependencies.selectionRunner` wires that source; the engine factory assembles
// the live `StockbitDataProvider` from the app's services (`AppDependencies.makeSelectionEngine`).
//
// `SelectionRunner` is closure-injected rather than hard-wired to the singleton so the
// source→engine pipeline is unit-testable in isolation. The provider, the engine, and the Watchlist
// composite are each already covered by their own suites, so this type only pins the orchestration:
// source the universe, then run the engine over exactly that universe; an empty universe
// short-circuits (no market fetch, no engine).

@MainActor
struct SelectionRunner {
    /// Produces the candidate universe to rank (the composite Watchlist symbols in the live wiring).
    let universeSource: () async -> [Ticker]
    /// Builds the engine for a given universe + config (assembles `StockbitDataProvider` under it).
    let makeEngine: ([Ticker], SelectionConfig) -> StockSelectionEngine

    /// Source the universe, then run the engine over it. An empty universe returns `[]` directly so a
    /// blocked/empty Watchlist doesn't pay a market-context fetch (or risk a `noRegimeInputs` throw).
    func run(config: SelectionConfig = .balanced) async throws -> [Recommendation] {
        let universe = await universeSource()
        guard !universe.isEmpty else { return [] }
        return try await makeEngine(universe, config).run()
    }
}

extension AppDependencies {

    /// Assembles the live Tier-A provider + engine over an explicit candidate universe (§8). Pure
    /// composition of the already-wired services — the orchestration/throttle/cache concerns live in
    /// `StockbitDataProvider`, the scoring in `StockSelectionEngine`.
    func makeSelectionEngine(universe: [Ticker],
                             config: SelectionConfig = .balanced) -> StockSelectionEngine {
        let provider = StockbitDataProvider(
            universe: universe, config: config,
            keystats: keystatsRatioService, fundachart: fundachartService,
            statements: financialStatementService, emitten: emittenService,
            priceFeed: companyPriceFeedService, broker: brokerActivityService,
            comparisonService: comparisonRatiosService, seasonalityService: seasonalityService,
            orderFlowService: orderTradeFlowService, analyst: analystRatingsService,
            governance: governanceService,
            snapshotProvider: regimeSnapshotService, flowService: aggregateForeignFlowService,
            chartService: chartService, commodityService: commodityPriceService,
            breadthService: breadthService)
        return StockSelectionEngine(provider: provider, config: config)
    }

    /// §10 universe: the composite Watchlist (the ranked union of the 20 screeners), read
    /// from the shared `ScreenerStore` cache that the sweep coordinator fills. Returns the
    /// de-duplicated, ranked, veto-filtered symbols.
    func watchlistUniverse() async -> [Ticker] {
        WatchlistComposer.compose(screenerStore.snapshots).rows.map(\.symbol)
    }

    /// The thin headless Tier-A entry point: rank the composite-Watchlist universe under `config`.
    var selectionRunner: SelectionRunner {
        SelectionRunner(
            universeSource: { await self.watchlistUniverse() },
            makeEngine: { self.makeSelectionEngine(universe: $0, config: $1) })
    }

    /// The "Today's Picks" screen source: the ranked, audited recommendations for the
    /// composite-Watchlist universe under `config`. Under `-UITestFixtures` it returns canned picks
    /// so the screen renders deterministically offline (the per-ticker leaf services are empty stubs
    /// under fixtures, so the live engine fan-out isn't exercised there); live, it runs the headless
    /// `selectionRunner`. `TodaysPicksViewModel` injects this as its default source.
    func todaysPicks(config: SelectionConfig = .balanced) async throws -> [Recommendation] {
        if ProcessInfo.processInfo.isUITestFixtures { return UITestFixtures.recommendations }
        return try await selectionRunner.run(config: config)
    }
}
