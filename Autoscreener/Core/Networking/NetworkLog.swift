import Foundation
import Observation

@MainActor
@Observable
final class NetworkLog {
    static let shared = NetworkLog()

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let method: String
        let url: String
        let status: Int?
        let durationMS: Int
        let requestBody: String?
        let responseBody: String?
        let error: String?
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 50

    private init() {}

    func append(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    func clear() { entries.removeAll() }
}

nonisolated final class LoggingHTTPSession: HTTPSession, @unchecked Sendable {
    private let upstream: HTTPSession
    init(_ upstream: HTTPSession) { self.upstream = upstream }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let start = Date()
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "?"
        let reqBody = request.httpBody.flatMap { Self.preview($0) }
        do {
            let (data, response) = try await upstream.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode
            let entry = NetworkLog.Entry(
                timestamp: start,
                method: method, url: url, status: status, durationMS: ms,
                requestBody: reqBody, responseBody: Self.preview(data), error: nil
            )
            await NetworkLog.shared.append(entry)
            return (data, response)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let entry = NetworkLog.Entry(
                timestamp: start,
                method: method, url: url, status: nil, durationMS: ms,
                requestBody: reqBody, responseBody: nil, error: error.localizedDescription
            )
            await NetworkLog.shared.append(entry)
            throw error
        }
    }

    private static func preview(_ data: Data, limit: Int = 4000) -> String? {
        guard !data.isEmpty else { return nil }
        if let s = String(data: data.prefix(limit), encoding: .utf8) {
            let truncated = data.count > limit ? s + "… (\(data.count) bytes total)" : s
            return redact(truncated)
        }
        return "<\(data.count) bytes binary>"
    }

    /// Replace the values of sensitive JSON keys with "***" so the log panel
    /// doesn't leak passwords, OTPs, or tokens into screenshots / shared captures.
    private static let sensitiveKeys = [
        "password", "otp",
        "login_token", "verification_token",
        "access_token", "refresh_token",
        "authorization",
    ]

    private static let redactionRegexes: [NSRegularExpression] = {
        sensitiveKeys.compactMap { key in
            // matches: "key":"value"  (with any whitespace)
            let pattern = "(\"\(key)\"\\s*:\\s*\")[^\"]*(\")"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }()

    static func redact(_ s: String) -> String {
        var out = s
        for re in redactionRegexes {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "$1***$2")
        }
        return out
    }
}
