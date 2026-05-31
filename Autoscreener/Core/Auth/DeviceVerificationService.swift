import Foundation

nonisolated enum OTPChannel: String, CaseIterable, Identifiable, Sendable {
    case email = "CHANNEL_EMAIL"
    case whatsapp = "CHANNEL_WHATSAPP"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .email: return "Email"
        case .whatsapp: return "WhatsApp"
        }
    }
}

nonisolated enum DeviceVerificationError: Error, Equatable {
    case invalidOTP
    case otpDeliveryFailed
    case challengeExpired
    case network(String)
    case malformedResponse
}

nonisolated protocol DeviceVerificationServicing: Sendable {
    func startChallenge(verificationToken: String) async throws -> [OTPChannel]
    func sendOTP(verificationToken: String, channel: OTPChannel) async throws
    func verifyOTP(verificationToken: String, otp: String) async throws
    func completeNewDevice(loginToken: String) async throws -> TokenPair
}

nonisolated final class DeviceVerificationService: DeviceVerificationServicing {
    private let session: HTTPSession
    init(session: HTTPSession = URLSession.shared) { self.session = session }

    func startChallenge(verificationToken: String) async throws -> [OTPChannel] {
        let body = try JSONSerialization.data(withJSONObject: ["verification_token": verificationToken])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/start", body: body, requiresAuth: false)
        let data = try await call(endpoint)
        return Self.parseChannels(data)
    }

    func sendOTP(verificationToken: String, channel: OTPChannel) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "verification_token": verificationToken,
            "channel": channel.rawValue,
        ])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/otp/send", body: body, requiresAuth: false)
        _ = try await call(endpoint)
    }

    func verifyOTP(verificationToken: String, otp: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "verification_token": verificationToken,
            "otp": otp,
        ])
        let endpoint = Endpoint(method: .post, path: "mfa/verification/v1/challenge/otp/verify", body: body, requiresAuth: false)
        _ = try await call(endpoint)
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

    private static func parseChannels(_ data: Data) -> [OTPChannel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OTPChannel.allCases
        }
        let payload = (json["data"] as? [String: Any]) ?? json
        if let raw = payload["channels"] as? [String] {
            let parsed = raw.compactMap(OTPChannel.init(rawValue:))
            if !parsed.isEmpty { return parsed }
        }
        return OTPChannel.allCases
    }
}
