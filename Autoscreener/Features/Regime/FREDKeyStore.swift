import Foundation
import Security

/// Reads the FRED API key from the login Keychain. The keyed FRED API path
/// (`FREDMacroService`) is enabled only when this returns a value; absent → the service
/// falls back to the keyless CSV endpoint, so the macro leg degrades rather than breaking.
///
/// The key is a free, read-only credential for *public* economic data, so it lives as a
/// generic-password item alongside the Stockbit tokens (`KeychainTokenStore`) — never in
/// committed source, an xcconfig, or an env var. Seed it once from Terminal:
///
///     security add-generic-password -s com.tom.tom.tom.Autoscreener \
///         -a fred-api-key -w <YOUR_KEY> -U
///
/// `service`/`account` match that command. This is a read-only reader (no save/clear):
/// seeding is a deliberate one-off, not something the app rotates.
nonisolated struct FREDKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.tom.tom.tom.Autoscreener", account: String = "fred-api-key") {
        self.service = service
        self.account = account
    }

    /// The seeded key, or `nil` when none is stored (or under tests). Trimmed; an
    /// empty/whitespace value reads as absent so a blank seed can't half-enable the API.
    var apiKey: String? {
        // Skip the Keychain under xctest / UI-test runs: every Debug rebuild changes the
        // binary's code-sign hash, which makes `SecItemCopyMatching` prompt to re-trust
        // the item — exactly why `AppDependencies` skips the token probe under tests.
        guard !ProcessInfo.processInfo.isRunningTests else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
