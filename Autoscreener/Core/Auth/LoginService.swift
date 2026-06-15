import Foundation

nonisolated enum LoginError: Error, Equatable {
    case invalidCredentials
    case network(String)
    case malformedResponse
}

nonisolated enum LoginOutcome: Equatable, Sendable {
    case authenticated(TokenPair)
    case needsDeviceVerification(loginToken: String, verificationToken: String)
}

nonisolated protocol LoginServicing: Sendable {
    func login(user: String, password: String) async throws -> LoginOutcome
    func refresh(refreshToken: String) async throws -> TokenPair
    func storeTokens(_ pair: TokenPair) async
    func signOut() async
}

nonisolated final class LoginService: LoginServicing {
    private let session: HTTPSession
    private let tokens: TokenStoring

    init(session: HTTPSession = URLSession.shared, tokens: TokenStoring) {
        self.session = session
        self.tokens = tokens
    }

    func login(user: String, password: String) async throws -> LoginOutcome {
        let body = try JSONEncoder().encode(
            LoginRequest(user: user, password: password, player_id: DeviceInfo.playerID)
        )
        let endpoint = Endpoint(method: .post, path: "login/v6/username", body: body, requiresAuth: false)
        let data = try await call(endpoint)

        // Stockbit returns 200 either with tokens (trusted device) or with an
        // MFA challenge envelope (untrusted device). Inspect the body to decide.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["data"] as? [String: Any],
           let newDevice = payload["new_device"] as? [String: Any],
           let mfa = newDevice["multi_factor"] as? [String: Any],
           let loginToken = mfa["login_token"] as? String,
           let verificationToken = mfa["verification_token"] as? String {
            return .needsDeviceVerification(loginToken: loginToken, verificationToken: verificationToken)
        }

        do {
            let dto = try JSONDecoder().decode(LoginResponse.self, from: data)
            let pair = TokenPair(
                accessToken: dto.accessToken,
                refreshToken: dto.refreshToken,
                accessExpiresAt: dto.accessExpiresAt,
                refreshExpiresAt: dto.refreshExpiresAt
            )
            await tokens.save(pair)
            return .authenticated(pair)
        } catch {
            throw LoginError.malformedResponse
        }
    }

    func refresh(refreshToken: String) async throws -> TokenPair {
        let endpoint = Endpoint(
            method: .post,
            path: "login/refresh",
            requiresAuth: false,
            extraHeaders: ["authorization": "Bearer \(refreshToken)"]
        )
        let data = try await call(endpoint)
        do {
            let dto = try JSONDecoder().decode(LoginResponse.self, from: data)
            return TokenPair(
                accessToken: dto.accessToken,
                refreshToken: dto.refreshToken,
                accessExpiresAt: dto.accessExpiresAt,
                refreshExpiresAt: dto.refreshExpiresAt
            )
        } catch {
            throw LoginError.malformedResponse
        }
    }

    func storeTokens(_ pair: TokenPair) async {
        await tokens.save(pair)
    }

    func signOut() async {
        await tokens.clear()
    }

    private func call(_ endpoint: Endpoint) async throws -> Data {
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
            return data
        case 400, 401:
            throw LoginError.invalidCredentials
        default:
            throw LoginError.network("HTTP \(http.statusCode)")
        }
    }
}
