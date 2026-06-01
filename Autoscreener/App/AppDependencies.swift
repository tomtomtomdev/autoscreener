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
    let schedulePreferences: SchedulePreferences
    let snapshotStore: any ScreenerSnapshotStoring
    let scheduler: ScreenerScheduler
    let authState = AuthState()

    static let shared = AppDependencies()

    private init() {
        let store = KeychainTokenStore()
        let session = LoggingHTTPSession(URLSession.shared)
        let login = LoginService(session: session, tokens: store)
        let verifier = DeviceVerificationService(session: session)
        let client = APIClient(session: session, tokens: store)
        let prefs = SchedulePreferences()
        // Capture the schedule by-value at construction time of each save. We can't
        // hop to MainActor inside the snapshot store's nonisolated actor, so the
        // closure consults UserDefaults directly — same source the prefs read.
        let defaults = UserDefaults.standard
        let snapshots = ScreenerSnapshotStore(isEnabled: { @Sendable in
            let raw = defaults.string(forKey: "autoscreener.schedule") ?? ScreenerSchedule.onDemand.rawValue
            return ScreenerSchedule(rawValue: raw) != .onDemand
        })

        self.tokens = store
        self.loginService = login
        self.deviceVerificationService = verifier
        self.apiClient = client
        self.paywallService = PaywallService(apiClient: client)
        self.screenerTemplateService = ScreenerTemplateService(apiClient: client)
        self.screenerService = ScreenerService(apiClient: client)
        self.schedulePreferences = prefs
        self.snapshotStore = snapshots
        self.scheduler = ScreenerScheduler(preferences: prefs)

        Task { [client, login] in
            await client.setRefresher { refreshToken in
                try await login.refresh(refreshToken: refreshToken)
            }
        }
    }
}
