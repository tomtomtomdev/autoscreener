import Foundation

nonisolated enum LoginError: Error, Equatable {
    case invalidCredentials
    case network(String)
    case malformedResponse
}

nonisolated protocol LoginServicing: Sendable {
    func login(user: String, password: String) async throws -> TokenPair
    func refresh(refreshToken: String) async throws -> TokenPair
    func signOut() async
}

nonisolated final class LoginService: LoginServicing {
    private let session: HTTPSession
    private let tokens: TokenStoring

    init(session: HTTPSession = URLSession.shared, tokens: TokenStoring) {
        self.session = session
        self.tokens = tokens
    }

    func login(user: String, password: String) async throws -> TokenPair {
        let body = try JSONEncoder().encode(
            LoginRequest(user: user, password: password, player_id: DeviceInfo.playerID)
        )
        let endpoint = Endpoint(method: .post, path: "login/v6/username", body: body, requiresAuth: false)
        let pair = try await call(endpoint)
        await tokens.save(pair)
        return pair
    }

    func refresh(refreshToken: String) async throws -> TokenPair {
        let endpoint = Endpoint(
            method: .post,
            path: "login/refresh",
            requiresAuth: false,
            extraHeaders: ["authorization": "Bearer \(refreshToken)"]
        )
        return try await call(endpoint)
    }

    func signOut() async {
        await tokens.clear()
    }

    private func call(_ endpoint: Endpoint) async throws -> TokenPair {
        let request = endpoint.makeRequest(token: nil)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LoginError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LoginError.network("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                let dto = try JSONDecoder().decode(LoginResponse.self, from: data)
                return TokenPair(accessToken: dto.accessToken, refreshToken: dto.refreshToken)
            } catch {
                throw LoginError.malformedResponse
            }
        case 400, 401:
            throw LoginError.invalidCredentials
        default:
            throw LoginError.network("HTTP \(http.statusCode)")
        }
    }
}
