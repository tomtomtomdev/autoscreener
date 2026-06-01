import Foundation
import Observation

/// UserDefaults-backed wrapper for the user's selected `ScreenerSchedule`.
/// Single source of truth — read by `ScreenerScheduler`, ViewModels, and Settings UI;
/// written by Settings UI (and tests).
@MainActor
@Observable
final class SchedulePreferences {
    private let defaults: UserDefaults
    private let key = "autoscreener.schedule"

    var schedule: ScreenerSchedule {
        didSet {
            if oldValue != schedule {
                defaults.set(schedule.rawValue, forKey: key)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: key),
           let value = ScreenerSchedule(rawValue: raw) {
            self.schedule = value
        } else {
            self.schedule = .onDemand
        }
    }
}
