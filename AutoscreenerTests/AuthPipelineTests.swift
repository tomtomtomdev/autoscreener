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

    @Test func parsesExpiredAtFromTrustedEnvelope() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"""
            {"data":{"login":{"token_data":{
              "access":{"token":"A","expired_at":"2026-06-01T09:28:29Z"},
              "refresh":{"token":"R","expired_at":"2026-06-07T09:28:29Z"}}}}}
            """#.utf8)
        )])
        let store = InMemoryTokenStore()
        let svc = LoginService(session: session, tokens: store)
        _ = try await svc.login(user: "u", password: "p")

        let saved = await store.load()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        #expect(saved?.accessExpiresAt == f.date(from: "2026-06-01T09:28:29Z"))
        #expect(saved?.refreshExpiresAt == f.date(from: "2026-06-07T09:28:29Z"))
    }

    @Test func decodesTrustedDeviceLoginEnvelope() async throws {
        let session = StubSession([.init(
            status: 200,
            body: Data(#"""
            {"message":"You have been successfully logged in",
             "data":{"login":{
               "user":{"id":248236,"username":"tommyyohanesreal"},
               "token_data":{
                 "access":{"token":"ACC.JWT","expired_at":"2026-06-01T09:28:29Z"},
                 "refresh":{"token":"REF.JWT","expired_at":"2026-06-07T09:28:29Z"}},
               "support":{"id":"abc"}}}}
            """#.utf8)
        )])
        let svc = LoginService(session: session, tokens: InMemoryTokenStore())
        let outcome = try await svc.login(user: "u", password: "p")
        guard case .authenticated(let pair) = outcome else { Issue.record("expected .authenticated"); return }
        #expect(pair.accessToken == "ACC.JWT")
        #expect(pair.refreshToken == "REF.JWT")
        #expect(pair.accessExpiresAt != nil)
        #expect(pair.refreshExpiresAt != nil)
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

    @Test func preflightRefreshesWhenAccessExpiresWithin60Seconds() async throws {
        let nearExpiry = Date().addingTimeInterval(10) // 10s left
        let store = InMemoryTokenStore(initial: TokenPair(
            accessToken: "OLD", refreshToken: "REF",
            accessExpiresAt: nearExpiry, refreshExpiresAt: Date().addingTimeInterval(86400)
        ))
        let session = StubSession([
            // Pre-emptive refresh hits no network here — the refresher closure returns directly
            .init(status: 200, body: Data(#"{"ok":1}"#.utf8)),
        ])
        let client = APIClient(session: session, tokens: store)
        await client.setRefresher { _ in
            TokenPair(accessToken: "NEW", refreshToken: "REF2",
                      accessExpiresAt: Date().addingTimeInterval(86400),
                      refreshExpiresAt: Date().addingTimeInterval(86400 * 7))
        }

        _ = try await client.sendRaw(Endpoint(method: .get, path: "x"))

        // The actual request goes out with the NEW token, no 401 dance.
        #expect(session.received.count == 1)
        #expect(session.received[0].value(forHTTPHeaderField: "authorization") == "Bearer NEW")
    }

    @Test func clearsTokensWhenRefreshHasExpired() async {
        let store = InMemoryTokenStore(initial: TokenPair(
            accessToken: "A", refreshToken: "R",
            accessExpiresAt: Date().addingTimeInterval(-10),
            refreshExpiresAt: Date().addingTimeInterval(-10) // also expired
        ))
        let session = StubSession([])
        let client = APIClient(session: session, tokens: store)

        await #expect(throws: APIError.unauthorized) {
            try await client.sendRaw(Endpoint(method: .get, path: "x"))
        }
        #expect(await store.load() == nil)
        #expect(session.received.isEmpty)  // never reached the network
    }

    @Test func unauthedEndpointDoesNotRequireToken() async throws {
        let store = InMemoryTokenStore()
        let session = StubSession([.init(status: 200, body: Data("{}".utf8))])
        let client = APIClient(session: session, tokens: store)

        _ = try await client.sendRaw(Endpoint(method: .get, path: "public/thing", requiresAuth: false))
        #expect(session.received[0].value(forHTTPHeaderField: "authorization") == nil)
    }

    /// Regression: three sendRaw calls in parallel with a near-expiry access token
    /// must share ONE refresh — not spawn three. Pre-fix, `refreshTokens()` suspended
    /// on `await tokens.load()` before assigning `refreshTask`, so concurrent callers
    /// each saw `refreshTask == nil` and started their own refresh `Task`. The server
    /// then sees 3 refreshes with the same refresh token; rotation makes 2 of 3 fail;
    /// each failing Task's catch calls `tokens.clear()` and torches the store, leaving
    /// the other two pending requests to throw `notSignedIn` *before reaching the
    /// network* (matching the Watchlist symptom where the failing GET never logged).
    ///
    /// Uses `SlowTokenStore` (real `await` inside `load`) because `InMemoryTokenStore`
    /// returns synchronously enough that the Swift runtime never yields the APIClient
    /// actor — masking the race. Production uses `KeychainTokenStore`, which does I/O,
    /// so the race window is wide in the field.
    @Test func parallelRequestsThatTriggerPreflightRefreshShareOneRefreshCall() async throws {
        let store = SlowTokenStore(initial: TokenPair(
            accessToken: "OLD", refreshToken: "REF",
            accessExpiresAt: Date().addingTimeInterval(10),      // expiring → preflight
            refreshExpiresAt: Date().addingTimeInterval(86400)
        ), loadDelayMS: 30)
        let session = StubSession([
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
            .init(status: 200, body: Data("{}".utf8)),
        ])
        let client = APIClient(session: session, tokens: store)

        let counter = RefreshCallCounter()
        await client.setRefresher { _ in
            counter.increment()
            // Widen the race window so the bug manifests deterministically.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return TokenPair(accessToken: "NEW", refreshToken: "REF2",
                             accessExpiresAt: Date().addingTimeInterval(86400),
                             refreshExpiresAt: Date().addingTimeInterval(86400 * 7))
        }

        async let r1 = client.sendRaw(Endpoint(method: .get, path: "a"))
        async let r2 = client.sendRaw(Endpoint(method: .get, path: "b"))
        async let r3 = client.sendRaw(Endpoint(method: .get, path: "c"))
        _ = try await (r1, r2, r3)

        #expect(counter.value == 1)
        #expect(session.received.count == 3)
        let auths = Set(session.received.compactMap { $0.value(forHTTPHeaderField: "authorization") })
        #expect(auths == ["Bearer NEW"])
        #expect(await store.load()?.accessToken == "NEW")
    }
}

/// Thread-safe counter for the refresher closure — the closure is `@Sendable` and
/// is invoked from inside the `APIClient` actor's refresh `Task`, so concurrent
/// invocations would race a plain Int.
final class RefreshCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

/// Token store whose `load` genuinely suspends, modelling Keychain I/O latency.
/// `InMemoryTokenStore`'s body is synchronous, so the Swift runtime often resumes
/// the caller without ever yielding the APIClient actor — which masks real-world
/// actor reentrancy races. Using a deliberately-slow load forces the suspension.
actor SlowTokenStore: TokenStoring {
    private var pair: TokenPair?
    private let loadDelay: UInt64
    init(initial: TokenPair? = nil, loadDelayMS: Int) {
        self.pair = initial
        self.loadDelay = UInt64(loadDelayMS) * 1_000_000
    }
    func load() async -> TokenPair? {
        try? await Task.sleep(nanoseconds: loadDelay)
        return pair
    }
    func save(_ pair: TokenPair) { self.pair = pair }
    func clear() { pair = nil }
}
