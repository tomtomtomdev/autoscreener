import Foundation

@MainActor
final class AppDependencies {
    let tokens: any TokenStoring
    let loginService: any LoginServicing
    let apiClient: APIClient

    static let shared = AppDependencies()

    private init() {
        let store = KeychainTokenStore()
        let login = LoginService(tokens: store)
        let client = APIClient(tokens: store)

        self.tokens = store
        self.loginService = login
        self.apiClient = client

        Task { [client, login] in
            await client.setRefresher { refreshToken in
                try await login.refresh(refreshToken: refreshToken)
            }
        }
    }
}
