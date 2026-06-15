import Foundation

nonisolated struct LoginRequest: Encodable {
    let user: String
    let password: String
    let player_id: String
}

/// Stockbit login returns tokens in two confirmed shapes (2026-05-31):
///   Trusted device (`POST /login/v6/username` when device is already trusted):
///     {data:{login:{user:{…}, token_data:{access:{token}, refresh:{token}}, support:{…}}}}
///   New-device verify (`POST /login/v6/new-device/verify`):
///     {data:{user:{…}, access:{token}, refresh:{token}}}
/// Decoder tries both and falls back to flat shapes in case other endpoints
/// (e.g. /login/refresh) reuse `{access_token, refresh_token}`.
nonisolated struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date?
    let refreshExpiresAt: Date?

    private enum Top: String, CodingKey { case data, accessToken = "access_token", refreshToken = "refresh_token" }
    private enum Mid: String, CodingKey {
        case access, refresh, login
        case tokenData = "token_data"
        case accessToken = "access_token", refreshToken = "refresh_token"
    }
    private enum Leaf: String, CodingKey { case token, expiredAt = "expired_at" }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Top.self)

        // Shape A: trusted-device — {data:{login:{token_data:{access:{token, expired_at}, refresh:{token, expired_at}}}}}
        if let data = try? root.nestedContainer(keyedBy: Mid.self, forKey: .data),
           let login = try? data.nestedContainer(keyedBy: Mid.self, forKey: .login),
           let tokenData = try? login.nestedContainer(keyedBy: Mid.self, forKey: .tokenData),
           let access = try? tokenData.nestedContainer(keyedBy: Leaf.self, forKey: .access),
           let refresh = try? tokenData.nestedContainer(keyedBy: Leaf.self, forKey: .refresh),
           let a = try? access.decode(String.self, forKey: .token),
           let r = try? refresh.decode(String.self, forKey: .token) {
            self.accessToken = a
            self.refreshToken = r
            self.accessExpiresAt = Self.parseExpiry(try? access.decode(String.self, forKey: .expiredAt))
            self.refreshExpiresAt = Self.parseExpiry(try? refresh.decode(String.self, forKey: .expiredAt))
            return
        }

        // Shape B: new-device verify — {data:{access:{token, expired_at?}, refresh:{token, expired_at?}}}
        if let mid = try? root.nestedContainer(keyedBy: Mid.self, forKey: .data),
           let access = try? mid.nestedContainer(keyedBy: Leaf.self, forKey: .access),
           let refresh = try? mid.nestedContainer(keyedBy: Leaf.self, forKey: .refresh),
           let a = try? access.decode(String.self, forKey: .token),
           let r = try? refresh.decode(String.self, forKey: .token) {
            self.accessToken = a
            self.refreshToken = r
            self.accessExpiresAt = Self.parseExpiry(try? access.decode(String.self, forKey: .expiredAt))
            self.refreshExpiresAt = Self.parseExpiry(try? refresh.decode(String.self, forKey: .expiredAt))
            return
        }

        // Shape C: {data:{access_token, refresh_token}}
        if let inner = try? root.nestedContainer(keyedBy: Mid.self, forKey: .data),
           let a = try? inner.decode(String.self, forKey: .accessToken),
           let r = try? inner.decode(String.self, forKey: .refreshToken) {
            self.accessToken = a
            self.refreshToken = r
            self.accessExpiresAt = nil
            self.refreshExpiresAt = nil
            return
        }

        // Shape D: {access_token, refresh_token} at the top level
        self.accessToken = try root.decode(String.self, forKey: .accessToken)
        self.refreshToken = try root.decode(String.self, forKey: .refreshToken)
        self.accessExpiresAt = nil
        self.refreshExpiresAt = nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseExpiry(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso8601.date(from: s)
    }
}
