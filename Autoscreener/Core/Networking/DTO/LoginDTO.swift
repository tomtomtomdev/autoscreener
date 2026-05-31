import Foundation

nonisolated struct LoginRequest: Encodable {
    let user: String
    let password: String
    let player_id: String
}

/// Stockbit login + new-device verification both return tokens in this shape (confirmed 2026-05-31):
///   {data:{user:{...}, access:{token:"…"}, refresh:{token:"…"}}}
/// The decoder also tolerates the legacy flat shapes in case other endpoints
/// (e.g. /login/refresh) reuse `{access_token, refresh_token}`.
nonisolated struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String

    private enum Top: String, CodingKey { case data, accessToken = "access_token", refreshToken = "refresh_token" }
    private enum Mid: String, CodingKey {
        case access, refresh
        case accessToken = "access_token", refreshToken = "refresh_token"
    }
    private enum Leaf: String, CodingKey { case token }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Top.self)

        // Shape A: {data:{access:{token}, refresh:{token}}} — real Stockbit envelope
        if let mid = try? root.nestedContainer(keyedBy: Mid.self, forKey: .data),
           let access = try? mid.nestedContainer(keyedBy: Leaf.self, forKey: .access),
           let refresh = try? mid.nestedContainer(keyedBy: Leaf.self, forKey: .refresh),
           let a = try? access.decode(String.self, forKey: .token),
           let r = try? refresh.decode(String.self, forKey: .token) {
            self.accessToken = a
            self.refreshToken = r
            return
        }

        // Shape B: {data:{access_token, refresh_token}}
        if let inner = try? root.nestedContainer(keyedBy: Mid.self, forKey: .data),
           let a = try? inner.decode(String.self, forKey: .accessToken),
           let r = try? inner.decode(String.self, forKey: .refreshToken) {
            self.accessToken = a
            self.refreshToken = r
            return
        }

        // Shape C: {access_token, refresh_token} at the top level
        self.accessToken = try root.decode(String.self, forKey: .accessToken)
        self.refreshToken = try root.decode(String.self, forKey: .refreshToken)
    }
}
