import Foundation
import Testing
@testable import Autoscreener

@Suite struct HTTPSessionFactoryTests {
    /// Regression for the `nw_read_request_report [C5] … "Operation timed out"` floods:
    /// the app was running on bare `URLSession.shared`, whose defaults are a 60s request
    /// timeout and a 7-day resource timeout — so a stalled Stockbit socket hangs a full
    /// minute before failing. The shared session must be built with bounded timeouts.
    @Test func screenerSessionBoundsRequestAndResourceTimeouts() {
        let session = HTTPSessionFactory.makeSession()
        #expect(session.configuration.timeoutIntervalForRequest == 30)
        #expect(session.configuration.timeoutIntervalForResource == 90)
    }
}
