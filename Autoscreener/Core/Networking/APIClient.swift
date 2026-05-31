import Foundation

nonisolated protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

actor APIClient {
    private let session: HTTPSession
    private let tokens: TokenStoring
    private var refreshTask: Task<TokenPair, Error>?

    private var refresher: (@Sendable (String) async throws -> TokenPair)?

    func setRefresher(_ refresher: @escaping @Sendable (String) async throws -> TokenPair) {
        self.refresher = refresher
    }

    init(session: HTTPSession = URLSession.shared, tokens: TokenStoring) {
        self.session = session
        self.tokens = tokens
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
        try await perform(endpoint, retriedAfterRefresh: false)
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
        default:
            throw APIError.http(status: http.statusCode, body: data)
        }
    }

    private func refreshTokens() async throws {
        if let inFlight = refreshTask {
            _ = try await inFlight.value
            return
        }
        guard let refresher, let current = await tokens.load() else {
            await tokens.clear()
            throw APIError.unauthorized
        }
        let task = Task<TokenPair, Error> { [refresher, tokens] in
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
