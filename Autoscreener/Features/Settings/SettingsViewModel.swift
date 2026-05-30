import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var username: String = ""
    var password: String = ""
    var isSubmitting: Bool = false
    var isSignedIn: Bool = false
    var error: String?

    private let loginService: any LoginServicing
    private let tokens: any TokenStoring

    init(loginService: any LoginServicing, tokens: any TokenStoring) {
        self.loginService = loginService
        self.tokens = tokens
        Task { await refreshSignedInState() }
    }

    func submit() async {
        if isSignedIn {
            await signOut()
            return
        }
        guard !username.isEmpty, !password.isEmpty else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            _ = try await loginService.login(user: username, password: password)
            password = ""
            isSignedIn = true
        } catch LoginError.invalidCredentials {
            error = "Invalid username or password."
        } catch LoginError.deviceVerificationRequired {
            error = "New device detected. Open the Stockbit mobile app, verify this device, then try again."
        } catch LoginError.malformedResponse {
            error = "Unexpected server response. Please try again."
        } catch LoginError.network(let detail) {
            error = "Couldn't reach Stockbit. \(detail)"
        } catch let err {
            error = err.localizedDescription
        }
    }

    func signOut() async {
        await loginService.signOut()
        username = ""
        password = ""
        isSignedIn = false
        error = nil
    }

    private func refreshSignedInState() async {
        isSignedIn = await tokens.load() != nil
    }
}
