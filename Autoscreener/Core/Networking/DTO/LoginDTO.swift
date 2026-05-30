import Foundation

nonisolated struct LoginRequest: Encodable {
    let user: String
    let password: String
    let player_id: String
}

// Response shape was not captured in proxseer_collection.json — this struct
// guesses the common Stockbit envelope and tolerates both flat and `data`-wrapped variants.
// Verify and trim once a real response is observed.
nonisolated struct LoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String

    private enum Top: String, CodingKey { case data, accessToken = "access_token", refreshToken = "refresh_token" }
    private enum Inner: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token" }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Top.self)
        if let nested = try? root.nestedContainer(keyedBy: Inner.self, forKey: .data) {
            self.accessToken = try nested.decode(String.self, forKey: .accessToken)
            self.refreshToken = try nested.decode(String.self, forKey: .refreshToken)
        } else {
            self.accessToken = try root.decode(String.self, forKey: .accessToken)
            self.refreshToken = try root.decode(String.self, forKey: .refreshToken)
        }
    }
}
