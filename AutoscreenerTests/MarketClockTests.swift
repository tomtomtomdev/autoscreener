import Foundation
import Testing
@testable import Autoscreener

/// IDX session detection in Asia/Jakarta. All instants are built in the Jakarta
/// zone so the test reads in exchange-local time regardless of the host's zone.
@Suite struct MarketClockTests {
    private let jakarta = TimeZone(identifier: "Asia/Jakarta")!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jakarta
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var clock: MarketClock { MarketClock(timeZone: jakarta) }

    // 2026-06-11 is a Thursday; 2026-06-13 a Saturday; 2026-06-15 a Monday.

    @Test func weekdayDuringSession1IsOpen() {
        #expect(clock.isOpen(at: date(2026, 6, 11, 10, 0)))   // Thu 10:00
    }

    @Test func weekdayDuringSession2IsOpen() {
        #expect(clock.isOpen(at: date(2026, 6, 11, 14, 30)))  // Thu 14:30
    }

    @Test func lunchBreakIsClosed() {
        #expect(!clock.isOpen(at: date(2026, 6, 11, 12, 30))) // Thu 12:30 — between sessions
    }

    @Test func beforeOpenAndAfterCloseAreClosed() {
        #expect(!clock.isOpen(at: date(2026, 6, 11, 8, 59)))  // pre-open
        #expect(!clock.isOpen(at: date(2026, 6, 11, 16, 0)))  // post-close
    }

    @Test func closeBoundaryIsExclusive() {
        #expect(clock.isOpen(at: date(2026, 6, 11, 15, 49)))   // 15:49 still open
        #expect(!clock.isOpen(at: date(2026, 6, 11, 15, 50)))  // 15:50 sharp closed
        #expect(!clock.isOpen(at: date(2026, 6, 11, 15, 51)))  // 15:51 closed
    }

    @Test func openBoundaryIsInclusive() {
        #expect(clock.isOpen(at: date(2026, 6, 11, 9, 0)))     // 09:00 sharp open
    }

    @Test func weekendIsClosed() {
        #expect(!clock.isOpen(at: date(2026, 6, 13, 10, 0)))   // Saturday 10:00
    }

    @Test func nextOpenDuringSession1IsSession2SameDay() {
        let next = clock.nextOpen(after: date(2026, 6, 11, 10, 0))  // Thu morning
        #expect(next == date(2026, 6, 11, 13, 30))                  // → Thu 13:30
    }

    @Test func nextOpenAfterCloseIsNextWeekdayMorning() {
        let next = clock.nextOpen(after: date(2026, 6, 11, 16, 0))  // Thu after close
        #expect(next == date(2026, 6, 12, 9, 0))                    // → Fri 09:00
    }

    @Test func nextOpenOnWeekendIsMondayMorning() {
        let next = clock.nextOpen(after: date(2026, 6, 13, 10, 0))  // Saturday
        #expect(next == date(2026, 6, 15, 9, 0))                    // → Mon 09:00
    }

    @Test func nextOpenDuringLunchIsSession2() {
        let next = clock.nextOpen(after: date(2026, 6, 11, 12, 30)) // Thu lunch
        #expect(next == date(2026, 6, 11, 13, 30))                  // → Thu 13:30
    }
}
