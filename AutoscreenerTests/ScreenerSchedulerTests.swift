import Foundation
import Testing
@testable import Autoscreener

/// Counts refresh invocations across actor boundaries.
actor RefreshCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Deterministic stand-in for `ScreenerScheduler`'s `sleeper`, so tests synchronize on
/// the loop's real progress instead of racing a wall-clock `Task.sleep` window (the old
/// flaky pattern). Each time the scheduler begins a wait it posts a tick to `entries` —
/// at that point the loop has computed and published `nextFireDate`. With `wakeFirst`,
/// the first wait returns immediately so the loop fires exactly once; every later wait
/// parks until the scheduler's task is cancelled by `stop()`, so the loop never
/// busy-spins while a test observes it.
actor ProbeSleeper {
    /// Ticks once per scheduler wait. `nonisolated` so tests can iterate it directly.
    nonisolated let entries: AsyncStream<Void>
    private let tick: AsyncStream<Void>.Continuation
    private let wakeFirst: Bool
    private var waits = 0

    init(wakeFirst: Bool) {
        self.wakeFirst = wakeFirst
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        self.entries = stream
        self.tick = continuation
    }

    /// Mirrors `ScreenerScheduler.Sleeper`; the requested duration is irrelevant here.
    func sleep(_ requestedNanoseconds: UInt64) async throws {
        waits += 1
        tick.yield()
        if wakeFirst && waits == 1 {
            return                                    // wake the loop once → it fires
        }
        try await Task.sleep(for: .seconds(3_600))    // park; stop() cancels this
    }
}

@MainActor
@Suite struct ScreenerSchedulerTests {
    private func makePreferences(_ schedule: ScreenerSchedule, defaultsKey: String = "autoscreener.schedule") -> SchedulePreferences {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        suite.set(schedule.rawValue, forKey: defaultsKey)
        return SchedulePreferences(defaults: suite)
    }

    @Test func onDemandLeavesNextFireDateNil() async {
        let prefs = makePreferences(.onDemand)
        let scheduler = ScreenerScheduler(preferences: prefs)
        scheduler.start(refresh: { })
        #expect(scheduler.nextFireDate == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopClearsNextFireDate() async throws {
        let prefs = makePreferences(.hourly)
        // Parks on the first wait so the loop stays in its sleep with nextFireDate set.
        let probe = ProbeSleeper(wakeFirst: false)
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            sleeper: { try await probe.sleep($0) },
            now: { Date() })

        scheduler.start(refresh: { })
        // Synchronize on the loop reaching its wait — no wall-clock guess. At the first
        // tick the loop has already computed and published nextFireDate.
        var entries = probe.entries.makeAsyncIterator()
        await entries.next()
        #expect(scheduler.nextFireDate != nil)

        scheduler.stop()
        #expect(scheduler.nextFireDate == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func schedulerFiresRefreshAfterSleeping() async throws {
        let prefs = makePreferences(.hourly)
        let counter = RefreshCounter()
        // Wakes the loop exactly once, then parks — so it fires precisely one time.
        let probe = ProbeSleeper(wakeFirst: true)
        let (fires, fired) = AsyncStream.makeStream(of: Void.self)
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            sleeper: { try await probe.sleep($0) },
            now: { Date() })

        scheduler.start(refresh: { @MainActor in
            await counter.bump()
            fired.yield()
        })

        // Await the actual fire instead of a fixed window: this returns the moment
        // refresh runs, so it can't flake under load the way a Task.sleep(50ms) did.
        var fireIterator = fires.makeAsyncIterator()
        await fireIterator.next()
        scheduler.stop()

        #expect(await counter.count >= 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func switchingScheduleToOnDemandStopsTheLoop() async throws {
        let prefs = makePreferences(.hourly)
        let counter = RefreshCounter()
        // Parks before any fire, so the hourly loop is observably up but hasn't fired.
        let probe = ProbeSleeper(wakeFirst: false)
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            sleeper: { try await probe.sleep($0) },
            now: { Date() })

        scheduler.start(refresh: { @MainActor in await counter.bump() })
        // Guard: the hourly loop is up and parked in its wait (nextFireDate published).
        var entries = probe.entries.makeAsyncIterator()
        await entries.next()
        #expect(scheduler.nextFireDate != nil)

        // Flip to onDemand and restart — the loop must idle and never fire.
        prefs.schedule = .onDemand
        scheduler.start(refresh: { @MainActor in await counter.bump() })
        #expect(scheduler.nextFireDate == nil)

        scheduler.stop()
        #expect(await counter.count == 0)
    }
}
