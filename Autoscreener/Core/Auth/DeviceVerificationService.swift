import Foundation

nonisolated enum OTPChannel: String, CaseIterable, Identifiable, Sendable {
    case email = "CHANNEL_EMAIL"
    case whatsapp = "CHANNEL_WHATSAPP"
    case sms = "CHANNEL_SMS"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .email: return "Email"
        case .whatsapp: return "WhatsApp"
        case .sms: return "SMS"
        }
    }
    var iconName: String {
        switch self {
        case .email: return "envelope"
        case .whatsapp: return "message"
        case .sms: return "message.badge"
        }
    }
}

nonisolated struct OTPChallengeChannel: Equatable, Sendable {
    let channel: OTPChannel
    let target: String?  // server-masked destination, e.g. "628******506"
}

nonisolated struct OTPChallengeOffer: Equatable, Sendable {
    let channels: [OTPChallengeChannel]
    let defaultChannel: OTPChannel?
}

nonisolated struct OTPVerifyOutcome: Equatable, Sendable {
    /// True if the server still wants another OTP step before we may call `completeNewDevice`.
    let needsAnotherChallenge: Bool
    let nextChannels: [OTPChallengeChannel]
    let defaultChannel: OTPChannel?
}

nonisolated enum DeviceVerificationError: Error, Equatable {
    case invalidOTP
    case otpDeliveryFailed
    case challengeExpired
    case network(String)
    case malformedResponse
}

nonisolated protocol DeviceVerificationServicing: Sendable {
    func startChallenge(verificationToken: String) async throws -> OTPChallengeOffer
    func sendOTP(verificationToken: String, channel: OTPChannel) async throws
    func verifyOTP(verificationToken: String, otp: String) async throws -> OTPVerifyOutcome
    func completeNewDevice(loginToken: String) async throws -> TokenPair
}

nonisolated final class DeviceVerificationService: DeviceVerificationServicing {
    private let session: HTTPSession
    init(session: HTTPSession = URLSession.shared) { self.session = session }

    func startChallenge(verificationToken: String) async throws -> OTPChallengeOffer {
        let body = try JSONSerialization.data(withJSONObject: ["verification_token": verificationToken])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/start", body: body, requiresAuth: false)
        let data = try await call(endpoint)
        return Self.parseChallengeOffer(data)
    }

    func sendOTP(verificationToken: String, channel: OTPChannel) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "verification_token": verificationToken,
            "channel": channel.rawValue,
        ])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/otp/send", body: body, requiresAuth: false)
        _ = try await call(endpoint)
    }

    func verifyOTP(verificationToken: String, otp: String) async throws -> OTPVerifyOutcome {
        let body = try JSONSerialization.data(withJSONObject: [
            "verification_token": verificationToken,
            "otp": otp,
        ])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/otp/verify", body: body, requiresAuth: false)
        let data = try await call(endpoint)
        return Self.parseVerifyOutcome(data)
    }

    func completeNewDevice(loginToken: String) async throws -> TokenPair {
        let body = try JSONSerialization.data(withJSONObject: [
            "multi_factor": ["login_token": loginToken]
        ])
        let endpoint = Endpoint(method: .post, path: "login/v6/new-device/verify", body: body, requiresAuth: false)
        let data = try await call(endpoint)
        do {
            let dto = try JSONDecoder().decode(LoginResponse.self, from: data)
            return TokenPair(accessToken: dto.accessToken, refreshToken: dto.refreshToken)
        } catch {
            throw DeviceVerificationError.malformedResponse
        }
    }

    private func call(_ endpoint: Endpoint) async throws -> Data {
        let request = endpoint.makeRequest(token: nil)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeviceVerificationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeviceVerificationError.network("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 400, 401, 422:
            // 400 INVALID_PARAMETER seen for bad OTP; 422 plausibly for expired/used tokens.
            if Self.isExpiredOrInvalidToken(data) { throw DeviceVerificationError.challengeExpired }
            throw DeviceVerificationError.invalidOTP
        case 502, 503, 504:
            throw DeviceVerificationError.otpDeliveryFailed
        default:
            throw DeviceVerificationError.network("HTTP \(http.statusCode)")
        }
    }

    private static func isExpiredOrInvalidToken(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let message = (json["message"] as? String ?? "").lowercased()
        let errorType = (json["error_type"] as? String ?? "").lowercased()
        return message.contains("expired") || errorType.contains("expired") || errorType.contains("invalid_token")
    }

    private static func parseChallengeOffer(_ data: Data) -> OTPChallengeOffer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.fallbackOffer(defaultChannel: .email)
        }
        let payload = (json["data"] as? [String: Any]) ?? json
        let inner = (payload["supporting_data"] as? [String: Any])?["otp"] as? [String: Any] ?? payload

        let channels: [OTPChallengeChannel]
        if let arr = inner["channels"] as? [[String: Any]] {
            channels = arr.compactMap { dict in
                guard let raw = dict["channel"] as? String, let ch = OTPChannel(rawValue: raw) else { return nil }
                return OTPChallengeChannel(channel: ch, target: dict["target"] as? String)
            }
        } else if let arr = inner["channels"] as? [String] {
            channels = arr.compactMap(OTPChannel.init(rawValue:))
                .map { OTPChallengeChannel(channel: $0, target: nil) }
        } else {
            channels = []
        }

        let defaultChannel = (inner["default_channel"] as? String).flatMap(OTPChannel.init(rawValue:))
        if channels.isEmpty {
            return Self.fallbackOffer(defaultChannel: defaultChannel ?? .email)
        }
        return OTPChallengeOffer(channels: channels, defaultChannel: defaultChannel ?? channels.first?.channel)
    }

    private static func fallbackOffer(defaultChannel: OTPChannel) -> OTPChallengeOffer {
        OTPChallengeOffer(
            channels: [OTPChallengeChannel(channel: defaultChannel, target: nil)],
            defaultChannel: defaultChannel
        )
    }

    private static func parseVerifyOutcome(_ data: Data) -> OTPVerifyOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else {
            return OTPVerifyOutcome(needsAnotherChallenge: false, nextChannels: [], defaultChannel: nil)
        }
        let nextChallenge = payload["next_challenge"] as? String
        let supporting = (payload["supporting_data"] as? [String: Any])?["otp"] as? [String: Any] ?? [:]

        let channelsRaw = supporting["channels"] as? [[String: Any]] ?? []
        let channels = channelsRaw.compactMap { dict -> OTPChallengeChannel? in
            guard let raw = dict["channel"] as? String, let ch = OTPChannel(rawValue: raw) else { return nil }
            return OTPChallengeChannel(channel: ch, target: dict["target"] as? String)
        }
        let defaultChannel = (supporting["default_channel"] as? String).flatMap(OTPChannel.init(rawValue:))

        // The server signals "another OTP needed" via next_challenge == "CHALLENGE_OTP";
        // anything missing/null/"NONE"/etc. means we're done with the MFA scope.
        let needsAnother = (nextChallenge?.uppercased() == "CHALLENGE_OTP")
        return OTPVerifyOutcome(
            needsAnotherChallenge: needsAnother,
            nextChannels: channels,
            defaultChannel: defaultChannel
        )
    }
}
