import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    enum Phase: Equatable {
        case signIn
        case verifying(VerificationState)
        case signedIn
    }

    struct VerificationState: Equatable {
        var loginToken: String
        var verificationToken: String
        var availableChannels: [OTPChallengeChannel] = OTPChannel.allCases.map { OTPChallengeChannel(channel: $0, target: nil) }
        var sentChannel: OTPChannel?
        var sentTarget: String?
        var otp: String = ""
        var isSubmitting: Bool = false
        var error: String?
        /// Increments each time the server demands an additional OTP challenge.
        /// 1 = first OTP (e.g. email), 2 = second OTP (e.g. phone), etc.
        var step: Int = 1
    }

    var phase: Phase = .signIn
    var username: String = ""
    var password: String = ""
    var isSubmitting: Bool = false
    var error: String?

    private let loginService: any LoginServicing
    private let verificationService: any DeviceVerificationServicing
    private let tokens: any TokenStoring
    private let authState: AuthState?

    init(loginService: any LoginServicing,
         verificationService: any DeviceVerificationServicing,
         tokens: any TokenStoring,
         authState: AuthState? = nil) {
        self.loginService = loginService
        self.verificationService = verificationService
        self.tokens = tokens
        self.authState = authState
        Task { await refreshSignedInState() }
    }

    var isSignedIn: Bool { phase == .signedIn }

    // MARK: - Sign in / out

    func submit() async {
        if isSignedIn { await signOut(); return }
        guard !username.isEmpty, !password.isEmpty else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            let outcome = try await loginService.login(user: username, password: password)
            switch outcome {
            case .authenticated:
                password = ""
                phase = .signedIn
                authState?.setSignedIn()
            case .needsDeviceVerification(let loginToken, let verificationToken):
                password = ""
                let state = VerificationState(loginToken: loginToken, verificationToken: verificationToken)
                phase = .verifying(state)
                await startChallenge()
            }
        } catch LoginError.invalidCredentials {
            error = "Invalid username or password."
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
        error = nil
        phase = .signIn
        authState?.setSignedOut()
    }

    func updateOTP(_ value: String) {
        guard case .verifying(var state) = phase else { return }
        state.otp = value
        phase = .verifying(state)
    }

    func cancelVerification() async {
        username = ""
        password = ""
        phase = .signIn
    }

    // MARK: - Device verification

    private func startChallenge() async {
        guard case .verifying(var state) = phase else { return }
        state.isSubmitting = true
        phase = .verifying(state)
        do {
            let offer = try await verificationService.startChallenge(verificationToken: state.verificationToken)
            if case .verifying(var s) = phase {
                if !offer.channels.isEmpty { s.availableChannels = offer.channels }
                s.isSubmitting = false
                phase = .verifying(s)
            }
            // Stockbit gates this sequentially (email mandatory first, then phone) — auto-send
            // via the server-suggested default channel so the user doesn't pick.
            if let channel = offer.defaultChannel ?? offer.channels.first?.channel {
                await requestOTP(via: channel)
            }
        } catch {
            if case .verifying(var s) = phase {
                s.isSubmitting = false
                s.error = friendly(verificationError: error)
                phase = .verifying(s)
            }
        }
    }

    func requestOTP(via channel: OTPChannel) async {
        guard case .verifying(var state) = phase else { return }
        state.isSubmitting = true
        state.error = nil
        phase = .verifying(state)
        do {
            try await verificationService.sendOTP(verificationToken: state.verificationToken, channel: channel)
            if case .verifying(var s) = phase {
                s.sentChannel = channel
                s.sentTarget = s.availableChannels.first(where: { $0.channel == channel })?.target
                s.otp = ""
                s.isSubmitting = false
                phase = .verifying(s)
            }
        } catch {
            if case .verifying(var s) = phase {
                s.isSubmitting = false
                s.error = friendly(verificationError: error)
                phase = .verifying(s)
            }
        }
    }

    func verifyOTP() async {
        guard case .verifying(var state) = phase else { return }
        let trimmed = state.otp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.isSubmitting = true
        state.error = nil
        phase = .verifying(state)
        do {
            let outcome = try await verificationService.verifyOTP(verificationToken: state.verificationToken, otp: trimmed)
            if outcome.needsAnotherChallenge {
                // Server wants a second OTP — usually a different channel set (e.g. phone after email).
                if case .verifying(var s) = phase {
                    s.step += 1
                    s.availableChannels = outcome.nextChannels.isEmpty
                        ? OTPChannel.allCases.map { OTPChallengeChannel(channel: $0, target: nil) }
                        : outcome.nextChannels
                    s.sentChannel = nil
                    s.sentTarget = nil
                    s.otp = ""
                    s.isSubmitting = false
                    phase = .verifying(s)
                }
                // Auto-send the next step via the server-default channel.
                if let next = outcome.defaultChannel ?? outcome.nextChannels.first?.channel {
                    await requestOTP(via: next)
                }
                return
            }
            let pair = try await verificationService.completeNewDevice(loginToken: state.loginToken)
            await loginService.storeTokens(pair)
            phase = .signedIn
            authState?.setSignedIn()
        } catch DeviceVerificationError.challengeExpired {
            phase = .signIn
            error = "Verification challenge expired. Please sign in again."
        } catch {
            if case .verifying(var s) = phase {
                s.isSubmitting = false
                s.error = friendly(verificationError: error)
                phase = .verifying(s)
            }
        }
    }

    // MARK: - Helpers

    private func refreshSignedInState() async {
        if await tokens.load() != nil {
            phase = .signedIn
            authState?.setSignedIn()
        }
    }

    private func friendly(verificationError err: Error) -> String {
        switch err {
        case DeviceVerificationError.invalidOTP:
            return "Invalid or expired code. Please try again."
        case DeviceVerificationError.otpDeliveryFailed:
            return "Couldn't deliver the code right now. Try the other channel."
        case DeviceVerificationError.malformedResponse:
            return "Unexpected server response."
        case DeviceVerificationError.network(let detail):
            return "Network error: \(detail)"
        default:
            return err.localizedDescription
        }
    }
}
