import Foundation
import Security

nonisolated struct TokenPair: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessExpiresAt: Date?
    var refreshExpiresAt: Date?

    /// Effective access expiry — prefers the server-supplied `expired_at`,
    /// falls back to decoding the JWT `exp` claim.
    var effectiveAccessExpiry: Date? {
        accessExpiresAt ?? JWT(accessToken)?.expiresAt
    }
    var effectiveRefreshExpiry: Date? {
        refreshExpiresAt ?? JWT(refreshToken)?.expiresAt
    }

    func isAccessExpiring(within seconds: TimeInterval) -> Bool {
        guard let exp = effectiveAccessExpiry else { return false }
        return exp.timeIntervalSinceNow < seconds
    }

    var isRefreshExpired: Bool {
        guard let exp = effectiveRefreshExpiry else { return false }
        return exp.timeIntervalSinceNow <= 0
    }
}

nonisolated protocol TokenStoring: Sendable {
    func load() async -> TokenPair?
    func save(_ pair: TokenPair) async
    func clear() async
}

actor KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    init(service: String = "com.tom.tom.tom.Autoscreener", account: String = "stockbit-tokens") {
        self.service = service
        self.account = account
    }

    func load() -> TokenPair? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let pair = try? JSONDecoder().decode(TokenPair.self, from: data)
        else { return nil }
        return pair
    }

    func save(_ pair: TokenPair) {
        guard let data = try? JSONEncoder().encode(pair) else { return }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery.merge(attrs) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
