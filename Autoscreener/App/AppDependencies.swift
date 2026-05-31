import Foundation

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
