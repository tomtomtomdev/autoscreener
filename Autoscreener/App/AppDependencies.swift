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
    let brokerSummaryService: any BrokerSummaryServicing
    let foreignFlowService: any ForeignFlowServicing
    let aggregateForeignFlowService: any AggregateForeignFlowServicing
    let chartService: any ChartServicing
    let commodityPriceService: any CommodityPriceServicing
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
        self.brokerSummaryService = useFixtures ? StubBrokerSummaryService() : BrokerSummaryService(apiClient: client)
        self.foreignFlowService = useFixtures ? StubForeignFlowService() : ForeignFlowService(apiClient: client)
        // Aggregate (market-wide) flow is the same endpoint family pinned to IHSG,
        // so it wraps whichever per-stock service we resolved (real or stub).
        self.aggregateForeignFlowService = AggregateForeignFlowService(flowService: self.foreignFlowService)
        self.chartService = useFixtures ? StubChartService() : ChartService(apiClient: client)
        self.commodityPriceService = useFixtures ? StubCommodityPriceService() : CommodityPriceService(apiClient: client)

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
