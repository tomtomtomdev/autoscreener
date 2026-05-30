import Foundation

@MainActor
final class AppDependencies {
    let tokens: any TokenStoring
    let loginService: any LoginServicing
    let apiClient: APIClient

    static let shared = AppDependencies()

    var isSignedInSync: Bool {
        // Synchronous Keychain probe for initial view state.
        (tokens as? KeychainTokenStore).map { _ in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.tom.tom.tom.Autoscreener",
                kSecAttrAccount as String: "stockbit-tokens",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        } ?? false
    }

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
