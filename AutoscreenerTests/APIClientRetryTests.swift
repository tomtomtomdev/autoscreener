import Foundation
import Testing
@testable import Autoscreener

// MARK: - Test doubles

/// A session that plays back a scripted sequence of steps: each step either returns a
/// canned HTTP response (with optional headers, for `Retry-After`) or throws a transport
/// `URLError`. Records how many requests it saw so retry counts are assertable.
final class RetryStubSession: HTTPSession, @unchecked Sendable {
    enum Step {
        case respond(status: Int, body: Data, headers: [String: String])
        case fail(URLError.Code)

        static func ok(_ body: String = "{}") -> Step { .respond(status: 200, body: Data(body.utf8), headers: [:]) }
        static func status(_ code: Int, headers: [String: String] = [:]) -> Step {
            .respond(status: code, body: Data("{}".utf8), headers: headers)
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var _requestCount = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

    init(_ steps: [Step]) { self.steps = steps }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
        precondition(!steps.isEmpty, "RetryStubSession ran out of scripted steps")
        switch steps.removeFirst() {
        case let .respond(status, body, headers):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, http)
        case let .fail(code):
            throw URLError(code)
        }
    }
}

/// Captures the durations APIClient asks to sleep between retries, so tests assert
/// both the retry count and that `Retry-After` was honoured — without real delay.
final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _nanos: [UInt64] = []
    var nanos: [UInt64] { lock.lock(); defer { lock.unlock() }; return _nanos }
    var count: Int { nanos.count }
    func record(_ ns: UInt64) { lock.lock(); _nanos.append(ns); lock.unlock() }
}

private func makeClient(_ session: RetryStubSession,
                        maxTransientRetries: Int = 2,
                        sleeper recorder: RecordingSleeper) -> APIClient {
    let store = InMemoryTokenStore(initial: TokenPair(accessToken: "ACC", refreshToken: "REF"))
    return APIClient(session: session, tokens: store,
                     maxTransientRetries: maxTransientRetries,
                     sleeper: { ns in recorder.record(ns) })
}

private let authed = Endpoint(method: .get, path: "screener/templates")

// MARK: - Bounded transient retry

@Suite struct APIClientTransientRetryTests {

    @Test func retriesOnceOn503ThenSucceeds() async throws {
        let session = RetryStubSession([.status(503), .ok(#"{"ok":1}"#)])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, sleeper: sleeper)

        let data = try await client.sendRaw(authed)

        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":1}"#)
        #expect(session.requestCount == 2)   // original + one retry
        #expect(sleeper.count == 1)           // slept once before the retry
    }

    @Test func exhaustsAfterMaxRetriesOn503ThenThrowsHttp503() async {
        let session = RetryStubSession([.status(503), .status(503), .status(503)])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, maxTransientRetries: 2, sleeper: sleeper)

        await #expect(throws: APIError.http(status: 503, body: Data("{}".utf8))) {
            try await client.sendRaw(authed)
        }
        #expect(session.requestCount == 3)   // original + two retries, then give up
        #expect(sleeper.count == 2)
    }

    @Test func doesNotRetryOn404() async {
        let session = RetryStubSession([.status(404)])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, sleeper: sleeper)

        await #expect(throws: APIError.http(status: 404, body: Data("{}".utf8))) {
            try await client.sendRaw(authed)
        }
        #expect(session.requestCount == 1)   // thrown immediately, never retried
        #expect(sleeper.count == 0)
    }

    @Test func retriesOn429TooManyRequests() async throws {
        let session = RetryStubSession([.status(429), .ok()])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, sleeper: sleeper)

        _ = try await client.sendRaw(authed)

        #expect(session.requestCount == 2)
        #expect(sleeper.count == 1)
    }

    @Test func retriesOnTransportError() async throws {
        let session = RetryStubSession([.fail(.timedOut), .ok()])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, sleeper: sleeper)

        _ = try await client.sendRaw(authed)

        #expect(session.requestCount == 2)
        #expect(sleeper.count == 1)
    }

    @Test func honorsRetryAfterHeaderForDelay() async throws {
        // Server explicitly asks for a 2-second wait; that must win over the computed jitter.
        let session = RetryStubSession([.status(503, headers: ["Retry-After": "2"]), .ok()])
        let sleeper = RecordingSleeper()
        let client = makeClient(session, sleeper: sleeper)

        _ = try await client.sendRaw(authed)

        #expect(sleeper.nanos == [2_000_000_000])
    }
}
