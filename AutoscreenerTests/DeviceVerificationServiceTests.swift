import Foundation
import Testing
@testable import Autoscreener

@Suite struct DeviceVerificationServiceTests {
    @Test func startChallengeSendsVerificationTokenAndReturnsChannels() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"data":{"channels":["CHANNEL_EMAIL","CHANNEL_WHATSAPP"]}}"#.utf8)
        )])
        let svc = DeviceVerificationService(session: session)

        let channels = try await svc.startChallenge(verificationToken: "V")

        #expect(channels == [.email, .whatsapp])
        let req = session.received[0]
        #expect(req.url?.path == "/mfa/verification/v1/challenge/start")
        #expect(req.value(forHTTPHeaderField: "authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body["verification_token"] == "V")
    }

    @Test func startChallengeFallsBackToAllChannelsWhenResponseLacksList() async throws {
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let svc = DeviceVerificationService(session: session)
        let channels = try await svc.startChallenge(verificationToken: "V")
        #expect(channels == OTPChannel.allCases)
    }

    @Test func sendOTPSerializesChannel() async throws {
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let svc = DeviceVerificationService(session: session)

        try await svc.sendOTP(verificationToken: "V", channel: .whatsapp)

        let req = session.received[0]
        #expect(req.url?.path == "/mfa/verification/v1/challenge/otp/send")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body["verification_token"] == "V")
        #expect(body["channel"] == "CHANNEL_WHATSAPP")
    }

    @Test func verifyOTPSerializesCode() async throws {
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let svc = DeviceVerificationService(session: session)

        try await svc.verifyOTP(verificationToken: "V", otp: "123456")

        let req = session.received[0]
        #expect(req.url?.path == "/mfa/verification/v1/challenge/otp/verify")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body["verification_token"] == "V")
        #expect(body["otp"] == "123456")
    }

    @Test func verifyOTPMapsHTTP400ToInvalidOTP() async {
        let session = StubSession([.init(status: 400, body: Data(#"{"message":"bad otp"}"#.utf8))])
        let svc = DeviceVerificationService(session: session)
        await #expect(throws: DeviceVerificationError.invalidOTP) {
            try await svc.verifyOTP(verificationToken: "V", otp: "x")
        }
    }

    @Test func verifyOTPMapsExpiredTokenEnvelopeToChallengeExpired() async {
        let session = StubSession([.init(
            status: 400,
            body: Data(#"{"message":"verification token expired","error_type":"INVALID_TOKEN"}"#.utf8)
        )])
        let svc = DeviceVerificationService(session: session)
        await #expect(throws: DeviceVerificationError.challengeExpired) {
            try await svc.verifyOTP(verificationToken: "V", otp: "x")
        }
    }

    @Test func completeNewDeviceSendsLoginTokenAndReturnsTokenPair() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"access_token":"ACC","refresh_token":"REF"}"#.utf8)
        )])
        let svc = DeviceVerificationService(session: session)

        let pair = try await svc.completeNewDevice(loginToken: "L")

        #expect(pair == TokenPair(accessToken: "ACC", refreshToken: "REF"))
        let req = session.received[0]
        #expect(req.url?.path == "/login/v6/new-device/verify")
        let outer = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: [String: String]]
        #expect(outer["multi_factor"]?["login_token"] == "L")
    }
}

@Suite struct NetworkLogRedactionTests {
    @Test func redactsKnownSensitiveKeys() {
        let input = #"{"password":"hunter2","otp":"123456","login_token":"L","verification_token":"V","access_token":"A","refresh_token":"R","authorization":"Bearer abc","keep":"me","nested":{"password":"x"}}"#
        let out = LoggingHTTPSession.redact(input)
        #expect(out.contains(#""password":"***""#))
        #expect(out.contains(#""otp":"***""#))
        #expect(out.contains(#""login_token":"***""#))
        #expect(out.contains(#""verification_token":"***""#))
        #expect(out.contains(#""access_token":"***""#))
        #expect(out.contains(#""refresh_token":"***""#))
        #expect(out.contains(#""authorization":"***""#))
        #expect(out.contains(#""keep":"me""#))
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("123456"))
        #expect(!out.contains("Bearer"))
    }

    @Test func redactionIsCaseInsensitive() {
        let input = #"{"Password":"x","Authorization":"Bearer y"}"#
        let out = LoggingHTTPSession.redact(input)
        #expect(!out.contains("Bearer"))
        #expect(out.contains("***"))
    }
}
