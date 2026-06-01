import Foundation
import Observation
import OSLog
import SwiftUI

private let schedulerLog = Logger(subsystem: "com.tom.tom.tom.Autoscreener", category: "scheduler")

/// Loops while running: sleeps to the next fire date for the current schedule, then
/// calls `refresh()` on the closure handed in at start. The closure typically runs
/// `WatchlistViewModel.refresh()`, which already paces requests at 1000–1500 ms — so
/// the scheduler doesn't need its own throttle.
///
/// On `schedule` changes, the running task is cancelled and the loop re-enters with
/// the new cadence. Stopping cancels the in-flight task; nothing fires until `start`
/// is called again.
@MainActor
@Observable
final class ScreenerScheduler {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void
    typealias Refresh = @MainActor () async -> Void
    typealias Now = @Sendable () -> Date

    /// Most recent scheduled fire that completed (success or failure). Drives the
    /// "Last refresh" label in Settings.
    var lastFireDate: Date?
    /// The next time the scheduler will fire, computed from the current schedule.
    /// `nil` for `.onDemand` or when stopped.
    var nextFireDate: Date?

    private var task: Task<Void, Never>?
    private let preferences: SchedulePreferences
    private let sleeper: Sleeper
    private let now: Now

    init(preferences: SchedulePreferences,
         sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
         now: @escaping Now = { Date() }) {
        self.preferences = preferences
        self.sleeper = sleeper
        self.now = now
    }

    /// Starts the loop. Safe to call repeatedly — replaces any in-flight task.
    func start(refresh: @escaping Refresh) {
        stop()
        let schedule = preferences.schedule
        guard schedule != .onDemand else {
            nextFireDate = nil
            schedulerLog.info("scheduler idle (onDemand)")
            return
        }
        let sleeper = self.sleeper
        let now = self.now
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let current = self?.preferences.schedule ?? .onDemand
                guard let fire = current.nextFireDate(after: now()) else { return }
                self?.nextFireDate = fire
                let ns = UInt64(max(1, fire.timeIntervalSince(now()) * 1_000_000_000))
                schedulerLog.info("scheduler sleeping \(ns / 1_000_000_000)s until \(fire.formatted(), privacy: .public)")
                do {
                    try await sleeper(ns)
                } catch {
                    return  // cancelled
                }
                guard !Task.isCancelled else { return }
                schedulerLog.info("scheduler firing refresh")
                await refresh()
                self?.lastFireDate = now()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        nextFireDate = nil
    }
}
