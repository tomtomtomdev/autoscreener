import Foundation

nonisolated struct Endpoint {
    enum Method: String { case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE" }

    var method: Method
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var requiresAuth: Bool = true
    var extraHeaders: [String: String] = [:]

    static let baseURL = URL(string: "https://exodus.stockbit.com")!

    func makeRequest(token: String?) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var req = URLRequest(url: components.url!)
        req.httpMethod = method.rawValue
        req.httpBody = body

        for (k, v) in DeviceInfo.commonHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "content-type") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if requiresAuth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return req
    }
}

nonisolated enum APIError: Error, Equatable {
    case unauthorized
    case http(status: Int, body: Data)
    case transport(String)
    case decoding(String)
    case notSignedIn
}
