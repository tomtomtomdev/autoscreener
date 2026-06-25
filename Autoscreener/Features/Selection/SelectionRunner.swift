import Foundation
import os

private let selectionLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "selection")

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
    func run(config: SelectionConfig = .balanced) async throws -> SelectionOutcome {
        let universe = await universeSource()
        guard !universe.isEmpty else { return SelectionOutcome(recommendations: [], skipped: []) }
        let collector = SkipCollector()
        let recommendations = try await makeEngine(universe, config).run { collector.add($0) }
        let skipped = collector.all
        for s in skipped { selectionLog.notice("picks skipped \(s.ticker, privacy: .public): \(s.reason, privacy: .public)") }
        return SelectionOutcome(recommendations: recommendations, skipped: skipped)
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
            breadthService: breadthService, bondFlowProvider: bondFlowService)
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

    // MARK: - Cache-backed path (the Recommendations screen)

    /// The sweep's cache-warming step (live only): fetch each watchlist ∪ held name's `SecurityData`
    /// and the regime context ONCE through the shared throttle, writing them to `SecurityDataStore`.
    /// This is the single place the per-symbol fan-out runs — moved off the Recommendations tab and
    /// onto the background sweep, so the screen ranks from cache. A name that can't be valued
    /// (`AdapterError` / no price) is simply not cached; `CachedDataProvider` reports it as a skip.
    /// Returns `true` if warming aborted early because the feed looked unreachable. `progress`
    /// reports `(done, total)` so the sweep coordinator can surface real warming progress.
    @discardableResult
    func warmSecurityCache(config: SelectionConfig = .balanced,
                           progress: @escaping @MainActor (_ done: Int, _ total: Int, _ current: Ticker?, _ step: String?) -> Void = { _, _, _, _ in }) async -> Bool {
        let watchlist = await watchlistUniverse()
        let held = Array(paperTradingStore.state.positions.keys)
        let universe = Array(Set(watchlist + held)).sorted()
        guard !universe.isEmpty else { return false }

        let provider = makeProvider(universe: universe, config: config)
        let now = marketClock.now()
        // `SecurityCacheWarmer` bounds this fan-out (offline circuit breaker) so a dropped connection
        // can't leave the sweep awaiting it forever — the bug that froze the title bar on
        // "Fetching 20/20" and stranded Recommendations on "waiting for the data sweep".
        let warmer = SecurityCacheWarmer(provider: provider)
        // Cadence policy: while the market is OPEN this is an intraday sweep — reuse each name's still-
        // fresh cached slow leg and fetch only the cheap fast leg. While CLOSED it's the close-capture
        // (or a manual-after-close) sweep — `fullWarm` forces a fundamentals refresh. Either way a name
        // with no fresh cached slice (cold launch / stale) full-warms via the per-name `nil` below, so
        // a fresh install still fetches fundamentals on its first pass.
        let fullWarm = !marketClock.isOpen()
        let outcome = await warmer.warm(
            universe: universe,
            onContext: { self.securityDataStore.updateContext($0, at: now) },
            // Cache the slow slice so an intraday pass can recompose this name from a fresh fast leg
            // without re-fetching its ~10 fundamentals requests.
            onFundamentals: { t, slice in self.fundamentalStore.update(slice, for: t, at: now) },
            onData: { _, data in self.securityDataStore.update(data, at: now) },
            cachedFundamentals: { t in fullWarm ? nil : self.fundamentalStore.freshSlice(for: t, asOf: now) },
            onProgress: progress)
        // A pass that ran to completion (didn't bail offline) is the signal the cache-read policy needs to
        // start ranking a partial cache — without it, the first open-market read mid-warm strands every
        // not-yet-reached name as a "not yet swept" skip. An aborted (offline) pass stays incomplete.
        if !outcome.abortedOffline { securityDataStore.markWarmComplete() }
        return outcome.abortedOffline
    }

    /// A point-in-time read of the still-fresh cache (entries + regime context), taken once on the main
    /// actor so the `CachedDataProvider` it feeds stays a pure value the engine reads without actor hops.
    /// `maxAge` is the `CacheReadPolicy` window: the 36h staleness window while the market is open, or
    /// unbounded while it's closed (rank the last-warmed close, since no warming sweep is coming).
    private func cachedSnapshot(within maxAge: TimeInterval)
        -> (data: [Ticker: SecurityData], context: MarketContext?) {
        securityDataStore.freshSnapshot(asOf: marketClock.now(), within: maxAge)
    }

    /// The buy engine over the cached snapshot — `CachedDataProvider` replaces the live fan-out.
    private func makeCachedSelectionEngine(
        universe: [Ticker], snapshot: (data: [Ticker: SecurityData], context: MarketContext?),
        config: SelectionConfig) -> StockSelectionEngine {
        StockSelectionEngine(
            provider: CachedDataProvider(cached: snapshot.data, context: snapshot.context, tickers: universe),
            config: config)
    }

    /// The "Positions to Review" screen source: hold/trim/exit verdicts for the paper book under `config`.
    /// `holdings` selects which book to review — defaulted to the paper-trading singleton
    /// (`paperTradingStore`), so the Recommendations screen and the autopilot review the same book. Under
    /// `-UITestFixtures` returns canned decisions so the screen renders offline; an empty book
    /// short-circuits (no fetch, no review). Mirrors `todaysPicks(config:)`.
    func reviewPositions(holdings: PaperTradingStore? = nil,
                         config: SelectionConfig = .balanced) async throws -> ReviewOutcome {
        if ProcessInfo.processInfo.isUITestFixtures {
            return ReviewOutcome(decisions: UITestFixtures.exitDecisions, skipped: [])
        }
        let book = holdings ?? paperTradingStore
        let held = Array(book.state.positions.keys)
        guard !held.isEmpty else {
            return ReviewOutcome(decisions: [], skipped: [])
        }
        // Read from the sweep-filled cache, never fetch. While OPEN, a cold cache (no regime context / no
        // fresh held name) ⇒ "waiting for the sweep". While CLOSED, read the last-warmed close regardless
        // of age and label it `asOf` — no warming sweep runs until the next session, so waiting is futile.
        let policy = CacheReadPolicy(isOpen: marketClock.isOpen())
        let asOf = policy.asOf(lastWarmedAt: securityDataStore.lastWarmedAt())
        let snapshot = cachedSnapshot(within: policy.maxAge)
        guard policy.isReadyToRank(
            contextPresent: snapshot.context != nil,
            hasFreshCandidate: held.contains(where: { snapshot.data[$0] != nil }),
            warmCompletedOnce: securityDataStore.warmCompletedOnce) else {
            return ReviewOutcome(decisions: [], skipped: [], awaitingData: true, asOf: asOf)
        }
        let reviewer = PositionReviewer(
            holdings: book,
            provider: CachedDataProvider(cached: snapshot.data, context: snapshot.context, tickers: held),
            evaluator: ExitEvaluator(config: config))
        let collector = SkipCollector()
        let decisions = try await reviewer.review { collector.add($0) }
        let skipped = collector.all
        for s in skipped { selectionLog.notice("review skipped \(s.ticker, privacy: .public): \(s.reason, privacy: .public)") }
        return ReviewOutcome(decisions: decisions, skipped: skipped, asOf: asOf)
    }

    /// §10 universe: the composite Watchlist (the ranked union of the 20 screeners), read
    /// from the shared `ScreenerStore` cache that the sweep coordinator fills. Returns the
    /// de-duplicated, ranked, veto-filtered symbols.
    func watchlistUniverse() async -> [Ticker] {
        WatchlistComposer.compose(screenerStore.snapshots).rows.map(\.symbol)
    }

    /// The "Today's Picks" screen source: the ranked, audited recommendations for the composite-Watchlist
    /// universe under `config`. Reads the sweep-filled `SecurityDataStore` through `CachedDataProvider` —
    /// it NEVER fetches per-ticker on tab open (the slow path that left the screen on "Sizing…"). Under
    /// `-UITestFixtures` it returns canned picks so the screen renders deterministically offline. Live, a
    /// cold cache (no regime context / no fresh candidate) short-circuits to `awaitingData` so the screen
    /// says "waiting for the sweep" instead of "no picks". `TodaysPicksViewModel` injects this as its source.
    func todaysPicks(config: SelectionConfig = .balanced) async throws -> SelectionOutcome {
        if ProcessInfo.processInfo.isUITestFixtures {
            let skipped = ProcessInfo.processInfo.isUITestSkippedFixture ? UITestFixtures.skippedNames : []
            return SelectionOutcome(recommendations: UITestFixtures.recommendations, skipped: skipped)
        }
        let universe = await watchlistUniverse()
        // An empty/blocked Watchlist is a genuine "no picks", not a cold cache — don't show "waiting".
        guard !universe.isEmpty else { return SelectionOutcome(recommendations: [], skipped: []) }
        // Open ⇒ honour the 36h staleness window (a cold cache means a warm sweep is imminent → "waiting").
        // Closed ⇒ read the last-warmed close regardless of age and stamp `asOf`, since the only sweep
        // coming is the next session's; ranking the official close beats stranding the screen on "waiting".
        let policy = CacheReadPolicy(isOpen: marketClock.isOpen())
        let asOf = policy.asOf(lastWarmedAt: securityDataStore.lastWarmedAt())
        let snapshot = cachedSnapshot(within: policy.maxAge)
        // Cold cache: no regime context, or not one candidate cached yet ⇒ wait for the sweep (open: the
        // in-progress one; closed: the closing-capture sweep that's about to warm it). Also wait while an
        // open-market FIRST warm is still in flight — ranking that partial cache strands every not-yet-
        // reached name as a "not yet swept" skip (the mid-warm race).
        guard policy.isReadyToRank(
            contextPresent: snapshot.context != nil,
            hasFreshCandidate: universe.contains(where: { snapshot.data[$0] != nil }),
            warmCompletedOnce: securityDataStore.warmCompletedOnce) else {
            return SelectionOutcome(recommendations: [], skipped: [], awaitingData: true, asOf: asOf)
        }
        let runner = SelectionRunner(
            universeSource: { universe },
            makeEngine: { self.makeCachedSelectionEngine(universe: $0, snapshot: snapshot, config: $1) })
        var outcome = try await runner.run(config: config)
        outcome.asOf = asOf
        return outcome
    }
}

/// Pure cache-read policy for the two cache-backed screens (`todaysPicks` / `reviewPositions`).
///
/// The bug it fixes: while the market is CLOSED, no warming sweep runs until the next session, so
/// honouring the 36h staleness window stranded the Recommendations screen on "waiting for the data
/// sweep…" all weekend (and through holidays) even though a perfectly good last-close snapshot was
/// cached. So the read window and the "as of" label both depend on session state:
///   • **Open** — honour the 36h window. A genuinely cold cache ⇒ a warm sweep is imminent ⇒ "waiting".
///   • **Closed** — read the last-warmed snapshot regardless of age and label it `asOf`. The sweep
///     coordinator captures the official close shortly after 16:00, so this is the settled close; no
///     further sweep is coming, so ranking it beats waiting. (A never-warmed cache still has nil
///     `lastWarmedAt` ⇒ nil `asOf` ⇒ the screen waits for the closing-capture sweep to fill it.)
nonisolated struct CacheReadPolicy {
    let isOpen: Bool

    /// Window passed to `SecurityDataStore.freshSnapshot(within:)`: the 36h staleness window while open,
    /// unbounded while closed (so the last-warmed close ranks).
    var maxAge: TimeInterval { isOpen ? SecurityDataStore.defaultMaxAge : .greatestFiniteMagnitude }

    /// The "as of" stamp for the screen's label: nil while open (figures are live), the cache's
    /// last-warmed time while closed (so the screen reads "as of <date> · market closed").
    func asOf(lastWarmedAt: Date?) -> Date? { isOpen ? nil : lastWarmedAt }

    /// Whether the cache is ready to rank, or the screen should wait. Beyond "context present + at least
    /// one fresh candidate", this closes the **mid-warm race**: while the market is OPEN and the first
    /// warm pass hasn't completed yet (`warmCompletedOnce == false`), the cache holds only the handful of
    /// names warmed so far — ranking it strands the rest as a wall of "not yet swept" skips. So an
    /// in-progress first warm reads as not-ready ("waiting"); once a pass completes (entries persist
    /// across the next re-warm) the still-absent names are genuine valuation skips, so we rank. While
    /// CLOSED no warm runs, so a completed pass isn't required — rank the last-warmed close.
    func isReadyToRank(contextPresent: Bool, hasFreshCandidate: Bool, warmCompletedOnce: Bool) -> Bool {
        guard contextPresent, hasFreshCandidate else { return false }
        return warmCompletedOnce || !isOpen
    }
}
