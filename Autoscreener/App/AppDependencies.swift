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
    let authState = AuthState()

    static let shared = AppDependencies()

    private init() {
        let store = KeychainTokenStore()
        let session = LoggingHTTPSession(URLSession.shared)
        let login = LoginService(session: session, tokens: store)
        let verifier = DeviceVerificationService(session: session)
        let client = APIClient(session: session, tokens: store)

        self.tokens = store
        self.loginService = login
        self.deviceVerificationService = verifier
        self.apiClient = client
        self.paywallService = PaywallService(apiClient: client)
        self.screenerTemplateService = ScreenerTemplateService(apiClient: client)
        self.screenerService = ScreenerService(apiClient: client)

        Task { [client, login] in
            await client.setRefresher { refreshToken in
                try await login.refresh(refreshToken: refreshToken)
            }
        }
    }
}
