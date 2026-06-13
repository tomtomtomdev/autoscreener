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

    /// The shared live `StockbitDataProvider` assembly — the single composition of the already-wired
    /// services that both the buy engine (`makeSelectionEngine`) and the Gate-5 reviewer
    /// (`makePositionReviewer`) build on. Orchestration/throttle/cache live in the provider.
    private func makeProvider(universe: [Ticker], config: SelectionConfig) -> StockbitDataProvider {
        StockbitDataProvider(
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
    }

    /// Assembles the live Tier-A provider + engine over an explicit candidate universe (§8). Pure
    /// composition of the already-wired services — the scoring lives in `StockSelectionEngine`.
    func makeSelectionEngine(universe: [Ticker],
                             config: SelectionConfig = .balanced) -> StockSelectionEngine {
        StockSelectionEngine(provider: makeProvider(universe: universe, config: config), config: config)
    }

    /// Assembles the live Gate-5 reviewer (the sell-side mirror of `makeSelectionEngine`). The paper
    /// portfolio is the `HoldingsProvider`; the shared provider re-fetches each held name's CURRENT
    /// data + the regime; `ExitEvaluator` applies the hold/trim/exit discipline. The held tickers form
    /// the provider universe (`data(for:)` fetches any ticker, so membership is moot — it keeps
    /// `universe()` honest).
    func makePositionReviewer(config: SelectionConfig = .balanced) -> PositionReviewer {
        let held = Array(paperTradingStore.state.positions.keys)
        return PositionReviewer(holdings: paperTradingStore,
                                provider: makeProvider(universe: held, config: config),
                                evaluator: ExitEvaluator(config: config))
    }

    /// The "Positions to Review" screen source: hold/trim/exit verdicts for the current paper book under
    /// `config`. Under `-UITestFixtures` returns canned decisions so the screen renders offline; an empty
    /// book short-circuits (no fetch, no review). Mirrors `todaysPicks(config:)`.
    func reviewPositions(config: SelectionConfig = .balanced) async throws -> [ExitDecision] {
        if ProcessInfo.processInfo.isUITestFixtures { return UITestFixtures.exitDecisions }
        guard !paperTradingStore.state.positions.isEmpty else { return [] }
        return try await makePositionReviewer(config: config).review()
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
