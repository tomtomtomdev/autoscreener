import Foundation
import Testing
@testable import Autoscreener

// MARK: - Fakes

actor InMemoryTokenStore: TokenStoring {
    private var pair: TokenPair?
    init(initial: TokenPair? = nil) { self.pair = initial }
    func load() -> TokenPair? { pair }
    func save(_ pair: TokenPair) { self.pair = pair }
    func clear() { pair = nil }
}

final class StubSession: HTTPSession, @unchecked Sendable {
    struct Stub { let status: Int; let body: Data }

    private let lock = NSLock()
    private var responses: [Stub]
    private(set) var received: [URLRequest] = []

    init(_ responses: [Stub]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
        precondition(!responses.isEmpty, "no stubbed response left")
        let next = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil
        )!
        return (next.body, http)
    }
}

// MARK: - JWT

@Suite struct JWTTests {
    @Test func decodesExpFromValidToken() {
        // header.payload.sig where payload = {"exp": 9999999999}
        let payload = "{\"exp\":9999999999}"
        let payloadB64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = JWT("xxx.\(payloadB64).yyy")
        #expect(jwt?.expiresAt != nil)
        #expect(jwt?.isExpiring(within: 60) == false)
    }

    @Test func reportsExpiredToken() {
        let payload = "{\"exp\":1}"
        let payloadB64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = JWT("xxx.\(payloadB64).yyy")
        #expect(jwt?.isExpiring() == true)
    }
}

// MARK: - LoginService

@Suite struct LoginServiceTests {
    @Test func sendsExpectedRequestAndStoresTokens() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"access_token":"A1","refresh_token":"R1"}"#.utf8)
        )])
        let store = InMemoryTokenStore()
        let svc = LoginService(session: session, tokens: store)

        let outcome = try await svc.login(user: "tommy", password: "secret")
        let pair = TokenPair(accessToken: "A1", refreshToken: "R1")

        #expect(outcome == .authenticated(pair))
        #expect(await store.load() == pair)

        let req = session.received[0]
        #expect(req.url?.absoluteString == "https://exodus.stockbit.com/login/v6/username")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "x-platform") == "iOS")
        #expect(req.value(forHTTPHeaderField: "authorization") == nil)

        let bodyJSON = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(bodyJSON["user"] == "tommy")
        #expect(bodyJSON["password"] == "secret")
        #expect(bodyJSON["player_id"]?.isEmpty == false)
    }

    @Test func decodesDataWrappedResponse() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"data":{"access_token":"A","refresh_token":"R"}}"#.utf8)
        )])
        let svc = LoginService(session: session, tokens: InMemoryTokenStore())
        let outcome = try await svc.login(user: "u", password: "p")
        #expect(outcome == .authenticated(TokenPair(accessToken: "A", refreshToken: "R")))
    }

    @Test func decodesNestedAccessRefreshEnvelope() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"""
            {"message":"You have been successfully logged in",
             "data":{
               "user":{"id":248236,"username":"tommyyohanesreal"},
               "access":{"token":"ACC.JWT"},
               "refresh":{"token":"REF.JWT"}
             }}
            """#.utf8)
        )])
        let svc = LoginService(session: session, tokens: InMemoryTokenStore())
        let outcome = try await svc.login(user: "u", password: "p")
        #expect(outcome == .authenticated(TokenPair(accessToken: "ACC.JWT", refreshToken: "REF.JWT")))
    }

    @Test func returnsNeedsDeviceVerificationOnMultiFactorEnvelope() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"""
            {"message":"You have been successfully logged in","data":{"new_device":{"multi_factor":{"login_token":"L","verification_token":"V"}}}}
            """#.utf8)
        )])
        let store = InMemoryTokenStore()
        let svc = LoginService(session: session, tokens: store)
        let outcome = try await svc.login(user: "u", password: "p")
        #expect(outcome == .needsDeviceVerification(loginToken: "L", verificationToken: "V"))
        #expect(await store.load() == nil) // tokens are NOT stored at this point
    }

    @Test func mapsHttp401ToInvalidCredentials() async {
        let session = StubSession([.init(status: 401, body: Data())])
        let svc = LoginService(session: session, tokens: InMemoryTokenStore())
        await #expect(throws: LoginError.invalidCredentials) {
            try await svc.login(user: "u", password: "p")
        }
    }

    @Test func refreshSendsBearer() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"{"access_token":"A2","refresh_token":"R2"}"#.utf8)
        )])
        let svc = LoginService(session: session, tokens: InMemoryTokenStore())
        _ = try await svc.refresh(refreshToken: "OLDREFRESH")

        let req = session.received[0]
        #expect(req.url?.absoluteString == "https://exodus.stockbit.com/login/refresh")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer OLDREFRESH")
        #expect(req.httpBody == nil)
    }
}

// MARK: - APIClient refresh-on-401

@Suite struct APIClientAuthInterceptorTests {
    @Test func attachesBearerOnAuthedRequests() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "ACC", refreshToken: "REF"))
        let session = StubSession([.init(status: 200, body: Data(#"{"ok":1}"#.utf8))])
        let client = APIClient(session: session, tokens: store)

        _ = try await client.sendRaw(Endpoint(method: .get, path: "screener/favorites"))

        #expect(session.received[0].value(forHTTPHeaderField: "authorization") == "Bearer ACC")
    }

    @Test func refreshesOnceOn401ThenRetries() async throws {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "OLD", refreshToken: "REF"))
        let session = StubSession([
            .init(status: 401, body: Data()),
            .init(status: 200, body: Data(#"{"ok":1}"#.utf8)),
        ])
        let client = APIClient(session: session, tokens: store)
        await client.setRefresher { _ in TokenPair(accessToken: "NEW", refreshToken: "REF2") }

        let data = try await client.sendRaw(Endpoint(method: .get, path: "screener/favorites"))

        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":1}"#)
        #expect(session.received.count == 2)
        #expect(session.received[0].value(forHTTPHeaderField: "authorization") == "Bearer OLD")
        #expect(session.received[1].value(forHTTPHeaderField: "authorization") == "Bearer NEW")
        #expect(await store.load() == TokenPair(accessToken: "NEW", refreshToken: "REF2"))
    }

    @Test func failingRefreshClearsTokens() async {
        let store = InMemoryTokenStore(initial: TokenPair(accessToken: "OLD", refreshToken: "REF"))
        let session = StubSession([.init(status: 401, body: Data())])
        let client = APIClient(session: session, tokens: store)
        await client.setRefresher { _ in throw LoginError.invalidCredentials }

        await #expect(throws: (any Error).self) {
            try await client.sendRaw(Endpoint(method: .get, path: "screener/favorites"))
        }
        #expect(await store.load() == nil)
    }

    @Test func unauthedEndpointDoesNotRequireToken() async throws {
        let store = InMemoryTokenStore()
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let client = APIClient(session: session, tokens: store)

        _ = try await client.sendRaw(Endpoint(method: .get, path: "public/thing", requiresAuth: false))
        #expect(session.received[0].value(forHTTPHeaderField: "authorization") == nil)
    }
}
