import Foundation
import Testing
@testable import Autoscreener

/// Counts refresh invocations across actor boundaries.
actor RefreshCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Replaceable clock that callers can advance manually. Used by the scheduler tests
/// so we never sleep for real wall-clock time.
@MainActor
final class VirtualClock {
    var now: Date
    init(_ now: Date) { self.now = now }
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

    @Test func stopClearsNextFireDate() async {
        let prefs = makePreferences(.hourly)
        // Sleeper that hangs forever so the scheduler stays in its sleep call.
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
            now: { Date() })
        scheduler.start(refresh: { })
        // Give the loop a moment to compute the next fire date.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(scheduler.nextFireDate != nil)
        scheduler.stop()
        #expect(scheduler.nextFireDate == nil)
    }

    @Test func schedulerFiresRefreshAfterSleeping() async throws {
        let prefs = makePreferences(.hourly)
        let counter = RefreshCounter()
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            // Instant "sleep" — the scheduler immediately wakes and fires.
            sleeper: { _ in },
            now: { Date() })
        scheduler.start(refresh: { @MainActor in
            await counter.bump()
        })
        // Loop iterations are async — let a few hops happen, then stop.
        try await Task.sleep(nanoseconds: 50_000_000)
        scheduler.stop()
        let count = await counter.count
        #expect(count >= 1)
    }

    @Test func switchingScheduleToOnDemandStopsTheLoop() async throws {
        let prefs = makePreferences(.hourly)
        let counter = RefreshCounter()
        let scheduler = ScreenerScheduler(
            preferences: prefs,
            sleeper: { _ in },
            now: { Date() })
        scheduler.start(refresh: { @MainActor in
            await counter.bump()
        })
        try await Task.sleep(nanoseconds: 30_000_000)
        // Flip to onDemand and restart — should leave nextFireDate nil and not fire.
        prefs.schedule = .onDemand
        scheduler.start(refresh: { @MainActor in
            await counter.bump()
        })
        #expect(scheduler.nextFireDate == nil)
        scheduler.stop()
    }
}
