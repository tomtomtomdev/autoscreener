import Foundation

nonisolated struct JWT {
    let expiresAt: Date?

    init?(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Self.decodeBase64URL(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        if let exp = json["exp"] as? TimeInterval {
            self.expiresAt = Date(timeIntervalSince1970: exp)
        } else {
            self.expiresAt = nil
        }
    }

    func isExpiring(within seconds: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow < seconds
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let mod = padded.count % 4
        if mod > 0 { padded.append(String(repeating: "=", count: 4 - mod)) }
        return Data(base64Encoded: padded)
    }
}
