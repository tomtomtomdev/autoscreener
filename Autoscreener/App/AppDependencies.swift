import Foundation

extension ProcessInfo {
    /// True when the current process was launched by xctest **or** by a UI test
    /// runner. We skip Keychain reads in both cases — every fresh Debug build
    /// changes the binary's code-sign hash, which makes `SecItemCopyMatching`
    /// prompt to re-trust the saved entry.
    ///
    /// - Unit tests: Xcode sets `XCTestConfigurationFilePath` on the host process.
    /// - UI tests: the SUT is a separate process that doesn't inherit that env
    ///   var, so the runner passes `-UITesting` as a launch argument instead.
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || arguments.contains("-UITesting")
    }
}

@MainActor
final class AppDependencies {
    let tokens: any TokenStoring
    let loginService: any LoginServicing
    let deviceVerificationService: any DeviceVerificationServicing
    let apiClient: APIClient
    let paywallService: any PaywallServicing
    let screenerTemplateService: any ScreenerTemplateServicing
    let screenerService: any ScreenerServicing
    let financialStatementService: any FinancialStatementServicing
    let keystatsRatioService: any KeystatsRatioServicing
    let brokerSummaryService: any BrokerSummaryServicing
    let foreignFlowService: any ForeignFlowServicing
    let aggregateForeignFlowService: any AggregateForeignFlowServicing
    let chartService: any ChartServicing
    let commodityPriceService: any CommodityPriceServicing
    let regimeSnapshotService: any RegimeSnapshotProviding
    let biRateService: any BIRateProviding
    let fredMacroService: any FREDMacroProviding
    let sovereignService: any IndonesiaSovereignProviding
    let bondFlowService: any BondFlowProviding
    let breadthService: any BreadthServicing
    // Per-ticker legs the Tier-A selection engine consumes (StockbitDataProvider, §8).
    let fundachartService: any FundachartServicing
    let emittenService: any EmittenServicing
    let companyPriceFeedService: any CompanyPriceFeedServicing
    let brokerActivityService: any BrokerActivityServicing
    // Captured-endpoint best-effort overlays the engine carries (StockbitDataProvider, Slice 4).
    let comparisonRatiosService: any ComparisonRatiosServicing
    let seasonalityService: any SeasonalityServicing
    let orderTradeFlowService: any OrderTradeFlowServicing
    // Slice 5 skeleton services (data-blocked: empty payloads for every captured symbol). Registered
    // for the future StockDetail UI; not yet consumed by any screen or the selection engine.
    let analystRatingsService: any AnalystRatingsServicing
    let researchService: any ResearchServicing
    // Gate-2 governance veto feed (insider/dilution) the selection engine consumes via StockbitDataProvider.
    let governanceService: any GovernanceServicing
    // Single source of truth for screener + markets data, filled by the continuous
    // market-hours sweep. Every screener tab and the composite Watchlist read the
    // screener store; the Markets screen reads the market store. Nothing else fetches.
    let screenerStore: ScreenerStore
    let marketDataStore: MarketDataStore
    // Paper-trading portfolio (100M IDR sim). Records confirmed allocations only;
    // reads regime + watchlist from the two stores above, never fetches itself.
    let paperTradingStore: PaperTradingStore
    let marketClock: MarketClock
    // User control over open-hours sweep cadence (continuous vs boundary-only). Read live by the
    // coordinator's loop and bound to the toggle in the ⌘, Settings "Data" section.
    let sweepSettings: SweepSettings
    let dataSweepCoordinator: DataSweepCoordinator
    let authState = AuthState()
    // Latest ranked recommendations, cached by `TodaysPicksViewModel` on load. The paper-trading flow
    // reads it at fill time to snapshot an `EntryThesis` cheaply (Gate-5 Phase 3) — no engine re-run.
    let recommendationsStore = RecommendationsStore()
    // Latest Gate-5 exit verdicts, cached by `PositionReviewViewModel` on review. The paper-trading
    // allocator reads it when building a plan so a flagged name is forced out / not re-bought — without
    // re-running the expensive holdings review on every rebalance. Also drives the Recommendations
    // screen's sell side.
    let exitDecisionsStore = ExitDecisionsStore()
    // Disk-backed cache of the LAST displayed Recommendations inbox (ranked picks + Gate-5 verdicts).
    // On a cold launch the screen renders this last-known list instead of a spinner while the fresh load
    // runs (stale-while-revalidate). Display-only — the two allocator-facing stores above stay in-memory,
    // so paper-trading behaviour and the golden master are untouched. Assigned in init (needs `headless`).
    let recommendationsSnapshotStore: RecommendationsSnapshotStore
    // Per-symbol `SecurityData` cache the sweep fills (`warmSecurityCache`) so the Recommendations
    // engine ranks from cache instead of fetching per ticker on tab open. Not persisted; refilled each
    // full IDX sweep. Read via `CachedDataProvider` in `todaysPicks` / `reviewPositions`.
    let securityDataStore = SecurityDataStore()
    // SLOW-leg cache (per-symbol `FundamentalSlice`) the sweep also fills, so an intraday-only pass can
    // recompose a name from a fresh fast leg + these cached fundamentals instead of a full re-fetch.
    // Persisted to disk in Phase 3; read by the Phase-4 scheduling branch.
    let fundamentalStore = FundamentalStore()
    // Hands-free paper trading: after each full sweep (while the market is open) the coordinator calls
    // this autopilot, which auto-rebalances the book off the recommendations once per session boundary.
    // Its engine sources default to the `shared` closures (resolved lazily, post-init).
    let paperTradingAutopilot: PaperTradingAutopilot

    static let shared = AppDependencies()

    private init() {
        let useFixtures = ProcessInfo.processInfo.isUITestFixtures
        let store = KeychainTokenStore()
        let session = LoggingHTTPSession(HTTPSessionFactory.makeSession())
        let login = LoginService(session: session, tokens: store)
        let verifier = DeviceVerificationService(session: session)
        let client = APIClient(session: session, tokens: store)

        self.tokens = store
        self.loginService = login
        self.deviceVerificationService = verifier
        self.apiClient = client
        self.paywallService = useFixtures ? StubPaywallService() : PaywallService(apiClient: client)
        self.screenerTemplateService = useFixtures ? StubScreenerTemplateService() : ScreenerTemplateService(apiClient: client)
        self.screenerService = useFixtures ? StubScreenerService() : ScreenerService(apiClient: client)
        self.financialStatementService = useFixtures ? StubFinancialStatementService() : FinancialStatementService(apiClient: client)
        self.keystatsRatioService = useFixtures ? StubKeystatsRatioService() : KeystatsRatioService(apiClient: client)
        self.brokerSummaryService = useFixtures ? StubBrokerSummaryService() : BrokerSummaryService(apiClient: client)
        self.foreignFlowService = useFixtures ? StubForeignFlowService() : ForeignFlowService(apiClient: client)
        // Aggregate (market-wide) flow is the same endpoint family pinned to IHSG,
        // so it wraps whichever per-stock service we resolved (real or stub).
        self.aggregateForeignFlowService = AggregateForeignFlowService(flowService: self.foreignFlowService)
        self.chartService = useFixtures ? StubChartService() : ChartService(apiClient: client)
        self.commodityPriceService = useFixtures ? StubCommodityPriceService() : CommodityPriceService(apiClient: client)
        // regime.json is public, static, unauthenticated data — fetched off the same
        // logging session, NOT the authenticated Stockbit client.
        self.regimeSnapshotService = useFixtures ? StubRegimeSnapshotService() : RegimeSnapshotService(session: session)
        // BI rate (bi.go.id HTML / FRED CSV) + FRED macro (DFF/DGS10/DTWEXBGS) are now
        // fetched on-device — public, unauthenticated feeds off the same logging session,
        // replacing the daily Python `refresh_bi` patch and the scraper's `macro` block.
        self.biRateService = useFixtures ? StubBIRateService() : BIRateService(session: session)
        // FRED macro now prefers the keyed JSON API when a key is seeded in the Keychain
        // (`FREDKeyStore`, seeded once via the `security` CLI — see that type); absent, it
        // falls back to the keyless CSV endpoint, so the leg still works without a key.
        self.fredMacroService = useFixtures
            ? StubFREDMacroService()
            : FREDMacroService(session: session, apiKey: FREDKeyStore().apiKey)
        self.sovereignService = useFixtures
            ? StubIndonesiaSovereignService()
            : IndonesiaSovereignService(session: session)
        self.bondFlowService = useFixtures
            ? StubBondFlowService()
            : BondFlowService(session: session)
        // Breadth fans out per-constituent chart calls, so it wraps whichever chart
        // service we resolved (real or the deterministic stub under UI fixtures).
        self.breadthService = useFixtures ? StubBreadthService() : BreadthService(chartService: self.chartService)
        // Tier-A selection legs (§8). No screen drives the engine under UI fixtures, so the stubs
        // return benign empties — present only so nothing in this init touches the network there.
        self.fundachartService = useFixtures ? StubFundachartService() : FundachartService(apiClient: client)
        self.emittenService = useFixtures ? StubEmittenService() : EmittenService(apiClient: client)
        self.companyPriceFeedService = useFixtures ? StubCompanyPriceFeedService() : CompanyPriceFeedService(apiClient: client)
        self.brokerActivityService = useFixtures ? StubBrokerActivityService() : BrokerActivityService(apiClient: client)
        self.comparisonRatiosService = useFixtures ? StubComparisonRatiosService() : ComparisonRatiosService(apiClient: client)
        self.seasonalityService = useFixtures ? StubSeasonalityService() : SeasonalityService(apiClient: client)
        self.orderTradeFlowService = useFixtures ? StubOrderTradeFlowService() : OrderTradeFlowService(apiClient: client)
        self.analystRatingsService = useFixtures ? StubAnalystRatingsService() : AnalystRatingsService(apiClient: client)
        self.researchService = useFixtures ? StubResearchService() : ResearchService(apiClient: client)
        self.governanceService = useFixtures ? StubGovernanceService() : GovernanceService(apiClient: client)

        // Screener cache + sweep. Under fixtures/tests we start from an empty cache
        // (don't read a real user's file) and disable the continuous loop — the
        // coordinator instead seeds the store with one sweep over the stub services,
        // so the UI renders deterministically without fetching on a timer.
        let headless = useFixtures || ProcessInfo.processInfo.isRunningTests
        let cacheStore = ScreenerStore(loadFromDisk: !headless)
        let marketStore = MarketDataStore(loadFromDisk: !headless)
        let clock = Self.clockForLaunch()
        // Open-hours cadence setting, read live by the coordinator loop and bound to the
        // ⌘, Settings toggle. Captured as a local so the loop's accessor closure can read it
        // without a `self` capture during init.
        let sweepSettings = SweepSettings()
        self.sweepSettings = sweepSettings
        self.screenerStore = cacheStore
        self.marketDataStore = marketStore
        // Same headless rule as the other stores: under fixtures/tests start from a
        // fresh 100M seed rather than reading a real user's portfolio file.
        self.paperTradingStore = PaperTradingStore(loadFromDisk: !headless)
        // Display-only inbox cache: persist live so a cold launch shows the last list; empty under
        // fixtures/tests (same headless rule) so screens render from canned data deterministically.
        self.recommendationsSnapshotStore = RecommendationsSnapshotStore(loadFromDisk: !headless)
        self.marketClock = clock

        // Build the autopilot from locals (no `self` capture during init) so it can be handed to the
        // coordinator's post-sweep hook below. Its picks/review sources default to the `shared` engine
        // closures, evaluated lazily when a sweep actually fires.
        let autopilot = PaperTradingAutopilot(
            store: self.paperTradingStore, screenerStore: cacheStore, marketStore: marketStore,
            recommendationsStore: self.recommendationsStore, exitDecisionsStore: self.exitDecisionsStore,
            clock: clock)
        self.paperTradingAutopilot = autopilot
        // Live only: after each full IDX sweep, run the autopilot — the exit (defense) pass every warm
        // sweep plus the once-per-session-boundary rebalance (offense). The coordinator only invokes this
        // hook while the market is open, so the book auto-executes during market hours only. Disabled
        // under fixtures/tests so the seed sweep leaves the paper book deterministic (UI tests drive
        // manually).
        var postSweep: DataSweepCoordinator.PostSweep? = nil
        if !headless {
            postSweep = { [autopilot, clock] in
                await autopilot.run(now: clock.now())
            }
        }

        // Live only: after each full IDX sweep, warm the per-symbol selection cache so the
        // Recommendations screen ranks from cache (no live fan-out on tab open) and the autopilot
        // rebalances off it. References `shared` lazily (like the autopilot sources) to avoid a
        // `self` capture during init; under fixtures/tests the screen uses canned data, so nil.
        var securitySweep: DataSweepCoordinator.SecuritySweep? = nil
        if !headless {
            securitySweep = { progress in await AppDependencies.shared.warmSecurityCache(progress: progress) }
        }

        self.dataSweepCoordinator = DataSweepCoordinator(
            store: cacheStore, marketStore: marketStore, clock: clock,
            paywall: self.paywallService,
            templates: self.screenerTemplateService,
            screener: self.screenerService,
            commodity: self.commodityPriceService,
            chart: self.chartService,
            flow: self.aggregateForeignFlowService,
            snapshotProvider: self.regimeSnapshotService,
            biRateProvider: self.biRateService,
            macroProvider: self.fredMacroService,
            sovereignProvider: self.sovereignService,
            bondFlowProvider: self.bondFlowService,
            // Live only: dynamic LQ45 + KOMPAS100 membership for the divergence breadth
            // factor. Under fixtures/tests it's nil, so breadth stays on the static LQ45
            // seed (deterministic, no network) exactly as before.
            indexConstituents: useFixtures ? nil : IndexConstituentsService(apiClient: client),
            runsContinuousLoop: !headless,
            // Under fixtures/tests the seed sweep should land instantly — skip the
            // anti-burst throttle (it only matters against the live Stockbit API).
            sleeper: headless ? { _ in } : { try await Task.sleep(nanoseconds: $0) },
            continuousAutoFetch: { sweepSettings.continuousAutoFetch },
            postSweep: postSweep,
            securitySweep: securitySweep)

        // Render the signed-in UI immediately under UI-test fixtures — bypass the
        // Keychain probe in ContentView (which only runs while phase == .unknown).
        if useFixtures { authState.phase = .signedIn }

        Task { [client, login] in
            await client.setRefresher { refreshToken in
                try await login.refresh(refreshToken: refreshToken)
            }
        }
    }

    /// The launch clock. Under UI fixtures, `-UITestMarketOpen` / `-UITestMarketClosed` pin it to a
    /// fixed open (weekday session) or closed (weekend) instant so market-state chrome — the manual
    /// Refresh button, the "auto-fetch off" status — renders deterministically regardless of when the
    /// suite runs. Otherwise the real wall clock.
    private static func clockForLaunch() -> MarketClock {
        func jakarta(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Jakarta") ?? .current
            return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) ?? Date()
        }
        let info = ProcessInfo.processInfo
        if info.isUITestMarketOpen {   let t = jakarta(2026, 6, 11, 10, 0); return MarketClock(now: { t }) }  // Thu, session 1
        if info.isUITestMarketClosed { let t = jakarta(2026, 6, 13, 10, 0); return MarketClock(now: { t }) }  // Saturday
        return MarketClock()
    }
}
