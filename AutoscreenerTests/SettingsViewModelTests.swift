import Foundation
import Testing
@testable import Autoscreener

final class FakeLoginService: LoginServicing, @unchecked Sendable {
    enum Outcome { case success(TokenPair), failure(LoginError) }
    var outcome: Outcome = .success(TokenPair(accessToken: "A", refreshToken: "R"))
    private(set) var loginCalls: [(user: String, password: String)] = []
    private(set) var signOutCount = 0

    func login(user: String, password: String) async throws -> TokenPair {
        loginCalls.append((user, password))
        switch outcome {
        case .success(let p): return p
        case .failure(let e): throw e
        }
    }
    func refresh(refreshToken: String) async throws -> TokenPair {
        TokenPair(accessToken: "A", refreshToken: "R")
    }
    func signOut() async { signOutCount += 1 }
}

@MainActor
@Suite struct SettingsViewModelTests {
    @Test func signsInOnSubmit() async {
        let svc = FakeLoginService()
        let store = InMemoryTokenStore()
        let vm = SettingsViewModel(loginService: svc, tokens: store)
        vm.username = "tommy"
        vm.password = "secret"

        await vm.submit()

        #expect(svc.loginCalls.count == 1)
        #expect(svc.loginCalls[0].user == "tommy")
        #expect(vm.isSignedIn)
        #expect(vm.password == "")
        #expect(vm.error == nil)
    }

    @Test func surfacesInvalidCredentialsError() async {
        let svc = FakeLoginService()
        svc.outcome = .failure(.invalidCredentials)
        let vm = SettingsViewModel(loginService: svc, tokens: InMemoryTokenStore())
        vm.username = "u"; vm.password = "p"

        await vm.submit()

        #expect(vm.isSignedIn == false)
        #expect(vm.error == "Invalid username or password.")
    }

    @Test func submitTogglesToSignOutWhenSignedIn() async {
        let svc = FakeLoginService()
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let vm = SettingsViewModel(loginService: svc, tokens: store)
        // wait for init's refreshSignedInState
        try? await Task.sleep(nanoseconds: 10_000_000)

        await vm.submit()

        #expect(svc.signOutCount == 1)
        #expect(vm.isSignedIn == false)
    }

    @Test func ignoresSubmitWhenFieldsEmpty() async {
        let svc = FakeLoginService()
        let vm = SettingsViewModel(loginService: svc, tokens: InMemoryTokenStore())
        await vm.submit()
        #expect(svc.loginCalls.isEmpty)
    }
}
