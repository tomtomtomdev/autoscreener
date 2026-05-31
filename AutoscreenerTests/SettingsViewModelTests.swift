import Foundation
import Testing
@testable import Autoscreener

final class FakeLoginService: LoginServicing, @unchecked Sendable {
    enum Outcome { case success(LoginOutcome), failure(LoginError) }
    var outcome: Outcome = .success(.authenticated(TokenPair(accessToken: "A", refreshToken: "R")))
    private(set) var loginCalls: [(user: String, password: String)] = []
    private(set) var storeCalls: [TokenPair] = []
    private(set) var signOutCount = 0

    func login(user: String, password: String) async throws -> LoginOutcome {
        loginCalls.append((user, password))
        switch outcome {
        case .success(let o):
            if case .authenticated(let pair) = o { storeCalls.append(pair) }
            return o
        case .failure(let e): throw e
        }
    }
    func refresh(refreshToken: String) async throws -> TokenPair {
        TokenPair(accessToken: "A", refreshToken: "R")
    }
    func storeTokens(_ pair: TokenPair) async { storeCalls.append(pair) }
    func signOut() async { signOutCount += 1 }
}

final class FakeDeviceVerificationService: DeviceVerificationServicing, @unchecked Sendable {
    var channels: [OTPChannel] = OTPChannel.allCases
    var startError: Error?
    var sendError: Error?
    var verifyError: Error?
    var completeError: Error?
    var completeReturn = TokenPair(accessToken: "ACC", refreshToken: "REF")

    private(set) var startCalls: [String] = []
    private(set) var sendCalls: [(token: String, channel: OTPChannel)] = []
    private(set) var verifyCalls: [(token: String, otp: String)] = []
    private(set) var completeCalls: [String] = []

    func startChallenge(verificationToken: String) async throws -> [OTPChannel] {
        startCalls.append(verificationToken)
        if let startError { throw startError }
        return channels
    }
    func sendOTP(verificationToken: String, channel: OTPChannel) async throws {
        sendCalls.append((verificationToken, channel))
        if let sendError { throw sendError }
    }
    func verifyOTP(verificationToken: String, otp: String) async throws {
        verifyCalls.append((verificationToken, otp))
        if let verifyError { throw verifyError }
    }
    func completeNewDevice(loginToken: String) async throws -> TokenPair {
        completeCalls.append(loginToken)
        if let completeError { throw completeError }
        return completeReturn
    }
}

@MainActor
private func makeVM(login: FakeLoginService = .init(),
                    verifier: FakeDeviceVerificationService = .init(),
                    store: InMemoryTokenStore = .init()) -> SettingsViewModel {
    SettingsViewModel(loginService: login, verificationService: verifier, tokens: store)
}

@MainActor
@Suite struct SettingsViewModelTests {
    @Test func signsInOnSubmit() async {
        let svc = FakeLoginService()
        let vm = makeVM(login: svc)
        vm.username = "tommy"; vm.password = "secret"

        await vm.submit()

        #expect(svc.loginCalls.count == 1)
        #expect(vm.isSignedIn)
        #expect(vm.password == "")
        #expect(vm.error == nil)
    }

    @Test func surfacesInvalidCredentialsError() async {
        let svc = FakeLoginService()
        svc.outcome = .failure(.invalidCredentials)
        let vm = makeVM(login: svc)
        vm.username = "u"; vm.password = "p"

        await vm.submit()

        #expect(vm.isSignedIn == false)
        #expect(vm.error == "Invalid username or password.")
    }

    @Test func submitTogglesToSignOutWhenSignedIn() async {
        let svc = FakeLoginService()
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "A", refreshToken: "R"))
        let vm = makeVM(login: svc, store: store)
        try? await Task.sleep(nanoseconds: 10_000_000)

        await vm.submit()

        #expect(svc.signOutCount == 1)
        #expect(vm.isSignedIn == false)
    }

    @Test func ignoresSubmitWhenFieldsEmpty() async {
        let svc = FakeLoginService()
        let vm = makeVM(login: svc)
        await vm.submit()
        #expect(svc.loginCalls.isEmpty)
    }

    // MARK: - Device verification flow

    @Test func mfaFlowEntersVerificationPhaseAndStartsChallenge() async {
        let svc = FakeLoginService()
        svc.outcome = .success(.needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        let verifier = FakeDeviceVerificationService()
        let vm = makeVM(login: svc, verifier: verifier)
        vm.username = "u"; vm.password = "p"

        await vm.submit()

        guard case .verifying(let state) = vm.phase else {
            Issue.record("expected .verifying phase"); return
        }
        #expect(state.loginToken == "L")
        #expect(state.verificationToken == "V")
        #expect(verifier.startCalls == ["V"])
        #expect(vm.password == "")
    }

    @Test func requestOTPMarksSentChannel() async {
        let svc = FakeLoginService()
        svc.outcome = .success(.needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        let verifier = FakeDeviceVerificationService()
        let vm = makeVM(login: svc, verifier: verifier)
        vm.username = "u"; vm.password = "p"
        await vm.submit()

        await vm.requestOTP(via: .email)

        guard case .verifying(let s) = vm.phase else { Issue.record("expected .verifying"); return }
        #expect(s.sentChannel == .email)
        #expect(verifier.sendCalls.count == 1)
        #expect(verifier.sendCalls[0].channel == .email)
        #expect(verifier.sendCalls[0].token == "V")
    }

    @Test func verifyOTPCompletesNewDeviceAndStoresTokens() async {
        let svc = FakeLoginService()
        svc.outcome = .success(.needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        let verifier = FakeDeviceVerificationService()
        verifier.completeReturn = TokenPair(accessToken: "ACC", refreshToken: "REF")
        let vm = makeVM(login: svc, verifier: verifier)
        vm.username = "u"; vm.password = "p"
        await vm.submit()
        await vm.requestOTP(via: .email)
        vm.updateOTP("123456")

        await vm.verifyOTP()

        #expect(vm.phase == .signedIn)
        #expect(verifier.verifyCalls.count == 1)
        #expect(verifier.verifyCalls[0].otp == "123456")
        #expect(verifier.completeCalls == ["L"])
        #expect(svc.storeCalls.contains(TokenPair(accessToken: "ACC", refreshToken: "REF")))
    }

    @Test func invalidOTPKeepsUserInVerificationPhase() async {
        let svc = FakeLoginService()
        svc.outcome = .success(.needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        let verifier = FakeDeviceVerificationService()
        verifier.verifyError = DeviceVerificationError.invalidOTP
        let vm = makeVM(login: svc, verifier: verifier)
        vm.username = "u"; vm.password = "p"
        await vm.submit()
        await vm.requestOTP(via: .email)
        vm.updateOTP("000000")

        await vm.verifyOTP()

        guard case .verifying(let s) = vm.phase else {
            Issue.record("expected .verifying"); return
        }
        #expect(s.error == "Invalid or expired code. Please try again.")
        #expect(verifier.completeCalls.isEmpty)
    }

    @Test func expiredChallengeBouncesBackToSignIn() async {
        let svc = FakeLoginService()
        svc.outcome = .success(.needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        let verifier = FakeDeviceVerificationService()
        verifier.verifyError = DeviceVerificationError.challengeExpired
        let vm = makeVM(login: svc, verifier: verifier)
        vm.username = "u"; vm.password = "p"
        await vm.submit()
        await vm.requestOTP(via: .email)
        vm.updateOTP("123456")

        await vm.verifyOTP()

        #expect(vm.phase == .signIn)
        #expect(vm.error == "Verification challenge expired. Please sign in again.")
    }
}
