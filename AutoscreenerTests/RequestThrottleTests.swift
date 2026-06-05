import Foundation
import Testing
@testable import Autoscreener

@Suite struct RequestThrottleTests {
    /// Records every delay the throttle requests, without actually sleeping.
    actor Recorder {
        private(set) var delays: [UInt64] = []
        func record(_ ns: UInt64) { delays.append(ns) }
    }

    @Test func firstWaitIsFreeSubsequentAreThrottled() async throws {
        let recorder = Recorder()
        let throttle = RequestThrottle(sleeper: { await recorder.record($0) })

        try await throttle.wait()   // first — no delay
        try await throttle.wait()
        try await throttle.wait()

        let delays = await recorder.delays
        #expect(delays.count == 2)  // only the 2nd and 3rd waits slept
    }

    @Test func delaysFallInTheDefault1000to1500msRange() async throws {
        let recorder = Recorder()
        let throttle = RequestThrottle(sleeper: { await recorder.record($0) })

        for _ in 0..<20 { try await throttle.wait() }

        let delays = await recorder.delays
        #expect(delays.count == 19)
        #expect(delays.allSatisfy { $0 >= 1_000_000_000 && $0 <= 1_500_000_000 })
    }

    @Test func customRangeIsHonoured() async throws {
        let recorder = Recorder()
        let throttle = RequestThrottle(range: 5...10, sleeper: { await recorder.record($0) })

        try await throttle.wait()
        try await throttle.wait()
        try await throttle.wait()

        let delays = await recorder.delays
        #expect(delays.allSatisfy { (5...10).contains($0) })
    }
}
