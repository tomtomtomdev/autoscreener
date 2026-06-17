import Foundation

/// Pure, value-type IDX (Indonesia Stock Exchange) trading-session clock. No app
/// state — it answers two questions for a given instant: is the regular session
/// open, and when does the next session open. Used by `DataSweepCoordinator` to
/// decide the sweep cadence and whether the IDX-session legs run (open) or stay
/// frozen on the cache (closed).
///
/// Sessions are IDX regular trading hours in Asia/Jakarta, weekdays only:
///   - Session 1: 09:00–12:00
///   - Session 2: 13:30–15:50
/// Fetching pauses during the 12:00–13:30 lunch break. Exchange holidays are NOT
/// modelled — a holiday that falls on a weekday is treated as open. (Documented
/// limitation; the worst case is a wasted sweep that returns yesterday's values.)
nonisolated struct MarketClock: Sendable {
    /// Half-open minute-of-day ranges `[start, end)`. 09:00 = 540, 12:00 = 720,
    /// 13:30 = 810, 15:50 = 950. Half-open so 15:50 sharp is already closed
    /// (15:49 open, 15:51 closed).
    static let sessions: [(start: Int, end: Int)] = [(540, 720), (810, 950)]

    /// Minute-of-day the official closing price settles (16:00 = 960). The regular session *ends*
    /// at 15:50 (`sessions.last.end`), but the closing price prints in the 15:50–16:00 closing
    /// auction — so "have we captured today's close yet?" keys off this later instant, not the
    /// session end. The last in-hours sweep (≤ 15:49) holds pre-close figures; the sweep coordinator
    /// fires one more full sweep after this minute to lock in the settled close.
    static let closingPrintMinute = 960

    var timeZone: TimeZone
    /// Injectable wall clock so tests can pin an exact instant.
    var now: @Sendable () -> Date

    init(timeZone: TimeZone = TimeZone(identifier: "Asia/Jakarta") ?? .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.timeZone = timeZone
        self.now = now
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// True when `date` falls on a weekday (Mon–Fri) AND within one of the two
    /// regular trading sessions, evaluated in `timeZone`.
    func isOpen(at date: Date) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, isWeekday(weekday),
              let hour = comps.hour, let minute = comps.minute else { return false }
        let minuteOfDay = hour * 60 + minute
        return Self.sessions.contains { minuteOfDay >= $0.start && minuteOfDay < $0.end }
    }

    /// Convenience over the injected clock.
    func isOpen() -> Bool { isOpen(at: now()) }

    /// The next instant a session opens strictly after `date`. When `date` is
    /// during session 1, returns session 2's open the same day; after the close,
    /// returns the next weekday's session-1 open; on a weekend, the following
    /// Monday's 09:00. Scans at most ~8 days ahead (always finds a weekday).
    func nextOpen(after date: Date) -> Date {
        let cal = calendar
        let startOfReferenceDay = cal.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: startOfReferenceDay) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard isWeekday(weekday) else { continue }
            for session in Self.sessions {
                guard let open = cal.date(byAdding: .minute, value: session.start, to: day) else { continue }
                if open > date { return open }
            }
        }
        // Unreachable in practice (a weekday always appears within 8 days), but
        // return a sane far-future fallback rather than trap.
        return date.addingTimeInterval(24 * 60 * 60)
    }

    /// The most recent instant the official close printed at or before `date`: the latest weekday
    /// 16:00 (`closingPrintMinute`) that is `<= date`. During a session it returns the *previous*
    /// session's close (today hasn't closed yet); just after 16:00 it returns today's; on a weekend
    /// or before a weekday open it returns the prior weekday's. Scans back ~8 days (a weekday always
    /// appears). The sweep loop compares its last full sweep against this to decide whether it still
    /// needs to capture the latest close. Holidays aren't modelled (see the type doc); the worst case
    /// is one wasted capture that re-reads the prior close.
    func mostRecentClose(asOf date: Date) -> Date? {
        let cal = calendar
        let startOfReferenceDay = cal.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: startOfReferenceDay) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard isWeekday(weekday) else { continue }
            guard let close = cal.date(byAdding: .minute, value: Self.closingPrintMinute, to: day) else { continue }
            if close <= date { return close }
        }
        // Unreachable in practice (a weekday always appears within 8 days); nil rather than trap.
        return nil
    }

    /// Gregorian weekday: 1 = Sunday … 7 = Saturday. Mon–Fri is 2…6.
    private func isWeekday(_ weekday: Int) -> Bool { (2...6).contains(weekday) }
}
