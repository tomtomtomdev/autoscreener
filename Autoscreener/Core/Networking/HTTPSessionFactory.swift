import Foundation

/// Builds the one shared `URLSession` the app talks to Stockbit through.
///
/// `URLSession.shared` defaults to a 60-second request timeout and a *seven-day*
/// resource timeout, so a stalled `exodus.stockbit.com` socket hangs for a full minute
/// before failing — the source of the `nw_read_request_report [C5] … "Operation timed
/// out"` floods in the console. We build the session with bounded timeouts instead so a
/// dead socket fails fast and the caller can move on.
enum HTTPSessionFactory {
    /// Max seconds to wait for *new data* on a request before giving up.
    static let requestTimeout: TimeInterval = 30
    /// Max seconds for a whole resource (incl. retries) to complete.
    static let resourceTimeout: TimeInterval = 90

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }
}
