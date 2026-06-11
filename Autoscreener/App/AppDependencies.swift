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
    let breadthService: any BreadthServicing
    // Per-ticker legs the Tier-A selection engine consumes (StockbitDataProvider, §8).
    let fundachartService: any FundachartServicing
    let emittenService: any EmittenServicing
    let companyPriceFeedService: any CompanyPriceFeedServicing
    let brokerActivityService: any BrokerActivityServicing
    // Single source of truth for screener data + the continuous market-hours sweep
    // that fills it. Every screener tab and the composite Watchlist read the store.
    let screenerStore: ScreenerStore
    let marketClock: MarketClock
    let screenerSweepCoordinator: ScreenerSweepCoordinator
    let authState = AuthState()

    static let shared = AppDependencies()

    private init() {
        let useFixtures = ProcessInfo.processInfo.isUITestFixtures
        let store = KeychainTokenStore()
        let session = LoggingHTTPSession(URLSession.shared)
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
        // Breadth fans out per-constituent chart calls, so it wraps whichever chart
        // service we resolved (real or the deterministic stub under UI fixtures).
        self.breadthService = useFixtures ? StubBreadthService() : BreadthService(chartService: self.chartService)
        // Tier-A selection legs (§8). No screen drives the engine under UI fixtures, so the stubs
        // return benign empties — present only so nothing in this init touches the network there.
        self.fundachartService = useFixtures ? StubFundachartService() : FundachartService(apiClient: client)
        self.emittenService = useFixtures ? StubEmittenService() : EmittenService(apiClient: client)
        self.companyPriceFeedService = useFixtures ? StubCompanyPriceFeedService() : CompanyPriceFeedService(apiClient: client)
        self.brokerActivityService = useFixtures ? StubBrokerActivityService() : BrokerActivityService(apiClient: client)

        // Screener cache + sweep. Under fixtures/tests we start from an empty cache
        // (don't read a real user's file) and disable the continuous loop — the
        // coordinator instead seeds the store with one sweep over the stub services,
        // so the UI renders deterministically without fetching on a timer.
        let headless = useFixtures || ProcessInfo.processInfo.isRunningTests
        let cacheStore = ScreenerStore(loadFromDisk: !headless)
        let clock = MarketClock()
        self.screenerStore = cacheStore
        self.marketClock = clock
        self.screenerSweepCoordinator = ScreenerSweepCoordinator(
            store: cacheStore, clock: clock,
            paywall: self.paywallService,
            templates: self.screenerTemplateService,
            screener: self.screenerService,
            runsContinuousLoop: !headless,
            // Under fixtures/tests the seed sweep should land instantly — skip the
            // anti-burst throttle (it only matters against the live Stockbit API).
            sleeper: headless ? { _ in } : { try await Task.sleep(nanoseconds: $0) })

        // Render the signed-in UI immediately under UI-test fixtures — bypass the
        // Keychain probe in ContentView (which only runs while phase == .unknown).
        if useFixtures { authState.phase = .signedIn }

        Task { [client, login] in
            await client.setRefresher { refreshToken in
                try await login.refresh(refreshToken: refreshToken)
            }
        }
    }
}
