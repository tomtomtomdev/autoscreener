import Foundation
import Testing
@testable import Autoscreener

@Suite struct NetworkLogTests {
    @Test func successfulResponseProducesNoConsoleLine() {
        let line = LoggingHTTPSession.consoleLine(
            method: "GET", url: "https://x/charts/CUAN/daily", status: 200, detail: "{}")
        #expect(line == nil)
    }

    @Test func badRequestSurfacesStatusMethodAndURL() {
        let url = "https://x/charts/CUAN/daily?timeframe=1d"
        let line = LoggingHTTPSession.consoleLine(
            method: "GET", url: url, status: 400, detail: "{\"message\":\"bad timeframe\"}")
        #expect(line != nil)
        #expect(line!.contains("HTTP 400"))
        #expect(line!.contains("GET"))
        #expect(line!.contains(url))
        #expect(line!.contains("bad timeframe"))
    }

    @Test func transportErrorIsLabelledNotDroppedAsSuccess() {
        let line = LoggingHTTPSession.consoleLine(
            method: "GET", url: "https://x/charts/CUAN/daily", status: nil, detail: "timed out")
        #expect(line != nil)
        #expect(line!.contains("transport-error"))
        #expect(line!.contains("timed out"))
    }

    @Test func longDetailIsTruncated() {
        let huge = String(repeating: "z", count: 2000)
        let line = LoggingHTTPSession.consoleLine(
            method: "GET", url: "https://x", status: 400, detail: huge)
        #expect(line != nil)
        #expect(line!.count < 700)  // 500-char detail cap + short prefix
    }

    @Test func cancellationIsRecognised() {
        #expect(LoggingHTTPSession.isCancellation(CancellationError()))
        #expect(LoggingHTTPSession.isCancellation(URLError(.cancelled)))
    }

    @Test func genuineTransportErrorIsNotCancellation() {
        #expect(!LoggingHTTPSession.isCancellation(URLError(.timedOut)))
        #expect(!LoggingHTTPSession.isCancellation(URLError(.notConnectedToInternet)))
    }
}
