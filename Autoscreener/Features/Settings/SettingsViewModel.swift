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

    /// Token/session expiry, surfaced in Settings so the user knows when their
    /// sign-in is still valid and when it has lapsed.
    struct SessionStatus: Equatable {
        var accessExpiry: Date?
        var refreshExpiry: Date?
        /// True when the refresh token is dead — no silent renewal is possible and
        /// the user must sign in again.
        var isRefreshExpired: Bool
    }

    var phase: Phase = .signIn
    var username: String = ""
    var password: String = ""
    var isSubmitting: Bool = false
    var error: String?

    /// Last-read session status (nil when signed out / no token). Drives the
    /// "valid until …" caption and the expired-session warning in `SettingsView`.
    private(set) var session: SessionStatus?

    private let loginService: any LoginServicing
    private let verificationService: any DeviceVerificationServicing
    private let tokens: any TokenStoring
    private let authState: AuthState?

    init(loginService: any LoginServicing,
         verificationService: any DeviceVerificationServicing,
         tokens: any TokenStoring,
         authState: AuthState? = nil,
         autoRehydrate: Bool = true) {
        self.loginService = loginService
        self.verificationService = verificationService
        self.tokens = tokens
        self.authState = authState
        // The production SettingsView passes `autoRehydrate: false` while running under
        // any test runner (xctest host or UI-test SUT) so the host-app boot doesn't fire
        // SecItemCopyMatching, which would re-prompt for Keychain ACL trust on every
        // fresh Debug build. Unit tests construct directly and accept the default (true).
        if autoRehydrate {
            Task { await rehydrateSession() }
        }
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
                await refreshSessionStatus()
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
        session = nil
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
            await refreshSessionStatus()
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

    /// Boot-time / on-open rehydrate: restore the signed-in UI from a stored token,
    /// but treat a dead refresh token as a lapsed session — clear it, flip the app
    /// back to signed-out, and tell the user to sign in again.
    func rehydrateSession() async {
        guard let pair = await tokens.load() else {
            session = nil
            return
        }
        let status = SessionStatus(
            accessExpiry: pair.effectiveAccessExpiry,
            refreshExpiry: pair.effectiveRefreshExpiry,
            isRefreshExpired: pair.isRefreshExpired)
        session = status

        if status.isRefreshExpired {
            // Dead session: drop the useless token and reflect signed-out state app-wide.
            // The expired notice itself is rendered from `session` in SettingsView.
            await tokens.clear()
            phase = .signIn
            authState?.setSignedOut()
        } else {
            phase = .signedIn
            authState?.setSignedIn()
        }
    }

    /// Refresh just the displayed `session` status from the stored token, without
    /// the sign-out side effects — used right after a successful sign-in.
    private func refreshSessionStatus() async {
        guard let pair = await tokens.load() else { session = nil; return }
        session = SessionStatus(
            accessExpiry: pair.effectiveAccessExpiry,
            refreshExpiry: pair.effectiveRefreshExpiry,
            isRefreshExpired: pair.isRefreshExpired)
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
