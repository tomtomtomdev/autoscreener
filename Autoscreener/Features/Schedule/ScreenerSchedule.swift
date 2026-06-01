import Foundation

/// User-selectable cadence for refreshing every screener tab + the composite Watchlist.
///
/// `.onDemand` is the legacy/default behavior — runs once on first tab reveal, then
/// only when the user taps Refresh. Every other mode is "auto-refresh" and triggers
/// the `ScreenerScheduler` to fan out a fresh fetch across all seven screeners +
/// the watchlist composite, with the same 1000–1500 ms throttle the watchlist
/// already uses, then persist the resulting rows.
nonisolated enum ScreenerSchedule: String, Codable, CaseIterable, Sendable {
    case onDemand
    case quarterHourly
    case hourly
    case dailyOpen     // 08:45 Asia/Jakarta (IDX pre-open auction)
    case dailyClose    // 16:15 Asia/Jakarta (IDX post-close)

    var displayName: String {
        switch self {
        case .onDemand:       return "On demand"
        case .quarterHourly:  return "Every 15 minutes"
        case .hourly:         return "Every hour"
        case .dailyOpen:      return "Daily 08:45 (IDX open)"
        case .dailyClose:     return "Daily 16:15 (IDX close)"
        }
    }

    /// A snapshot older than this duration is considered stale and the scheduler will
    /// catch-up fetch on app launch. `nil` for `.onDemand` (manual control only).
    var staleAfter: TimeInterval? {
        switch self {
        case .onDemand:       return nil
        case .quarterHourly:  return 15 * 60
        case .hourly:         return 60 * 60
        case .dailyOpen,
             .dailyClose:     return 24 * 60 * 60
        }
    }

    /// The next wall-clock time the scheduler should fire after `now`, or `nil` for
    /// `.onDemand`. Daily modes use Asia/Jakarta wall-clock; interval modes align to
    /// the next :00/:15/:30/:45 (quarter) or :00 (hourly) boundary so refreshes from
    /// users who keep the app open all day fire at predictable times.
    func nextFireDate(after now: Date,
                      calendar: Calendar = .jakarta) -> Date? {
        switch self {
        case .onDemand:
            return nil
        case .quarterHourly:
            return Self.nextQuarterHour(after: now, calendar: calendar)
        case .hourly:
            return Self.nextTopOfHour(after: now, calendar: calendar)
        case .dailyOpen:
            return Self.nextDaily(hour: 8, minute: 45, after: now, calendar: calendar)
        case .dailyClose:
            return Self.nextDaily(hour: 16, minute: 15, after: now, calendar: calendar)
        }
    }

    private static func nextQuarterHour(after now: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minute = comps.minute ?? 0
        let nextSlot = ((minute / 15) + 1) * 15
        if nextSlot >= 60 {
            comps.minute = 0
            comps.hour = (comps.hour ?? 0) + 1
        } else {
            comps.minute = nextSlot
        }
        comps.second = 0
        return calendar.date(from: comps) ?? now.addingTimeInterval(60)
    }

    private static func nextTopOfHour(after now: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        comps.hour = (comps.hour ?? 0) + 1
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? now.addingTimeInterval(3600)
    }

    private static func nextDaily(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let candidate = calendar.date(from: comps) ?? now
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? now.addingTimeInterval(86_400)
    }
}

extension Calendar {
    /// Asia/Jakarta wall-clock — IDX trading sessions are quoted in WIB (UTC+7).
    nonisolated static var jakarta: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta") ?? .current
        return cal
    }
}
