import Foundation

nonisolated protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

actor APIClient {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let session: HTTPSession
    private let tokens: TokenStoring
    private var refreshTask: Task<TokenPair, Error>?

    /// Bounded retry for *transient* failures (a server that didn't process the request:
    /// 503/502/504/429/408, or a transport blip). Stockbit's `screener/templates` endpoint
    /// occasionally 503s mid-sweep; without a retry the whole screener is skipped until the
    /// next full sweep (5–30 min of stale data). One or two short retries clears the blip.
    /// 4xx (auth/paywall/not-found) is NOT transient and is never retried.
    private let maxTransientRetries: Int
    /// Jittered delay used between retries when the server gives no `Retry-After` hint.
    private let retryDelayRange: ClosedRange<UInt64>
    /// Upper bound on an honoured `Retry-After`, so a server asking for a long wait can't
    /// stall a sweep — we wait at most this long, then retry (and give up after the cap).
    private let maxHonoredRetryAfter: TimeInterval
    private let sleeper: Sleeper

    private var refresher: (@Sendable (String) async throws -> TokenPair)?

    func setRefresher(_ refresher: @escaping @Sendable (String) async throws -> TokenPair) {
        self.refresher = refresher
    }

    init(session: HTTPSession = URLSession.shared,
         tokens: TokenStoring,
         maxTransientRetries: Int = 2,
         retryDelayRange: ClosedRange<UInt64> = 400_000_000...800_000_000,
         maxHonoredRetryAfter: TimeInterval = 5,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.session = session
        self.tokens = tokens
        self.maxTransientRetries = maxTransientRetries
        self.retryDelayRange = retryDelayRange
        self.maxHonoredRetryAfter = maxHonoredRetryAfter
        self.sleeper = sleeper
    }

    func send<T: Decodable>(_ endpoint: Endpoint, as: T.Type = T.self) async throws -> T {
        let data = try await sendRaw(endpoint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func sendRaw(_ endpoint: Endpoint) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await perform(endpoint, retriedAfterRefresh: false)
            } catch let transient as TransientHTTP {
                guard attempt < maxTransientRetries else {
                    // Out of retries — surface the public error services already handle.
                    throw APIError.http(status: transient.status, body: transient.body)
                }
                attempt += 1
                try await sleeper(retryDelay(retryAfter: transient.retryAfter))
            } catch let urlError as URLError where Self.isRetryableTransport(urlError) {
                guard attempt < maxTransientRetries else { throw urlError }
                attempt += 1
                try await sleeper(retryDelay(retryAfter: nil))
            }
        }
    }

    /// Refresh proactively when the access token has this many seconds (or fewer) of life left.
    /// Prevents a guaranteed 401 round-trip on the next request.
    private let preflightRefreshWindow: TimeInterval = 60

    private func perform(_ endpoint: Endpoint, retriedAfterRefresh: Bool) async throws -> Data {
        let token: String?
        if endpoint.requiresAuth {
            if !retriedAfterRefresh, let pair = await tokens.load() {
                if pair.isRefreshExpired {
                    // Refresh token itself is dead — force a re-login.
                    await tokens.clear()
                    throw APIError.unauthorized
                }
                if pair.isAccessExpiring(within: preflightRefreshWindow) {
                    try await refreshTokens()
                }
            }
            token = await tokens.load()?.accessToken
            if token == nil { throw APIError.notSignedIn }
        } else {
            token = nil
        }

        let request = endpoint.makeRequest(token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("non-HTTP response") }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401 where endpoint.requiresAuth && !retriedAfterRefresh:
            try await refreshTokens()
            return try await perform(endpoint, retriedAfterRefresh: true)
        case 401:
            throw APIError.unauthorized
        case let status where Self.transientStatuses.contains(status):
            // Retryable server hiccup — let the retry loop in `sendRaw` decide.
            throw TransientHTTP(status: status, body: data,
                                retryAfter: Self.retryAfterSeconds(from: http))
        default:
            throw APIError.http(status: http.statusCode, body: data)
        }
    }

    // MARK: - Transient-failure retry

    /// A server response that signals "I didn't process your request — try again."
    /// Private so it never escapes the actor; `sendRaw` maps it to `APIError.http` on giving up.
    private struct TransientHTTP: Error {
        let status: Int
        let body: Data
        let retryAfter: TimeInterval?
    }

    private static let transientStatuses: Set<Int> = [408, 429, 502, 503, 504]

    /// Transport-level failures worth a retry. Excludes `.cancelled` (a deliberate
    /// mid-sweep cancellation must propagate, not retry).
    private static let retryableTransportCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
        .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
        .resourceUnavailable, .badServerResponse,
    ]

    private static func isRetryableTransport(_ error: URLError) -> Bool {
        retryableTransportCodes.contains(error.code)
    }

    /// Parses an integer-seconds `Retry-After`. HTTP-date form is uncommon for 503/429
    /// rate-limit responses and falls back to the computed jitter.
    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return seconds
    }

    private func retryDelay(retryAfter: TimeInterval?) -> UInt64 {
        if let retryAfter {
            let capped = min(max(retryAfter, 0), maxHonoredRetryAfter)
            return UInt64(capped * 1_000_000_000)
        }
        return UInt64.random(in: retryDelayRange)
    }

    private func refreshTokens() async throws {
        // 1) Join an already-in-flight refresh, if any.
        if let inFlight = refreshTask {
            _ = try await inFlight.value
            return
        }
        // 2) Claim the slot synchronously. No `await` between the nil-check above
        //    and `refreshTask = task` below — otherwise concurrent callers could
        //    each see `refreshTask == nil`, each spawn their own Task, and we'd
        //    fire N refreshes with the same refresh token (most servers rotate on
        //    use → N-1 fail → each failing Task's catch calls `tokens.clear()`).
        guard let refresher else {
            await tokens.clear()
            throw APIError.unauthorized
        }
        let task = Task<TokenPair, Error> { [refresher, tokens] in
            guard let current = await tokens.load() else {
                await tokens.clear()
                throw APIError.unauthorized
            }
            do {
                let new = try await refresher(current.refreshToken)
                await tokens.save(new)
                return new
            } catch {
                await tokens.clear()
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        _ = try await task.value
    }
}
