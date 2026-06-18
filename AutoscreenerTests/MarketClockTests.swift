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

    // MARK: - Closing print (16:00) — the official close the sweep captures after the session.

    @Test func closingPrintIsFourPM() {
        #expect(MarketClock.closingPrintMinute == 16 * 60)          // 960, not the 15:50 session end
    }

    @Test func mostRecentCloseDuringASessionIsThePriorDayClose() {
        // Thu 10:00 — today's 16:00 hasn't printed yet, so the latest close is Wed's.
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 11, 10, 0)) == date(2026, 6, 10, 16, 0))
    }

    @Test func mostRecentCloseBetweenSessionEndAndPrintIsStillThePriorDay() {
        // 15:55 — the regular session ended at 15:50, but the close prints at 16:00, so it isn't
        // "today's close" yet. This is the gap the in-hours sweep (≤15:49) never captures.
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 11, 15, 55)) == date(2026, 6, 10, 16, 0))
    }

    @Test func mostRecentCloseAtOrAfterFourPMIsTodaysClose() {
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 11, 16, 0)) == date(2026, 6, 11, 16, 0))  // 16:00 sharp
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 11, 16, 30)) == date(2026, 6, 11, 16, 0))
    }

    @Test func mostRecentCloseOnAWeekendIsFridayClose() {
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 13, 10, 0)) == date(2026, 6, 12, 16, 0))  // Sat → Fri 16:00
    }

    @Test func mostRecentCloseBeforeMondayOpenIsFridayClose() {
        #expect(clock.mostRecentClose(asOf: date(2026, 6, 15, 8, 0)) == date(2026, 6, 12, 16, 0))   // Mon pre-open → Fri
    }

    // MARK: - Sweep boundaries (open · break · resume · close) — drive OFF-mode boundary captures.

    @Test func boundaryMinutesAreOpenBreakResumeClose() {
        #expect(MarketClock.sweepBoundaryMinutes == [540, 720, 810, 960])  // 09:00, 12:00, 13:30, 16:00
    }

    @Test func mostRecentBoundaryReturnsTheLatestEdgeAtOrBeforeNow() {
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 11, 10, 0)) == date(2026, 6, 11, 9, 0))   // mid-S1 → 09:00
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 11, 12, 30)) == date(2026, 6, 11, 12, 0)) // lunch → 12:00
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 11, 14, 0)) == date(2026, 6, 11, 13, 30)) // mid-S2 → 13:30
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 11, 16, 30)) == date(2026, 6, 11, 16, 0)) // after print → 16:00
    }

    @Test func mostRecentBoundaryBeforeOpenIsThePriorWeekdayClose() {
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 11, 8, 0)) == date(2026, 6, 10, 16, 0))   // pre-open → Wed 16:00
        #expect(clock.mostRecentBoundary(asOf: date(2026, 6, 13, 10, 0)) == date(2026, 6, 12, 16, 0))  // Sat → Fri 16:00
    }

    @Test func nextBoundaryReturnsTheEarliestEdgeStrictlyAfterNow() {
        #expect(clock.nextBoundary(after: date(2026, 6, 11, 8, 0)) == date(2026, 6, 11, 9, 0))    // pre-open → 09:00
        #expect(clock.nextBoundary(after: date(2026, 6, 11, 10, 0)) == date(2026, 6, 11, 12, 0))  // mid-S1 → 12:00
        #expect(clock.nextBoundary(after: date(2026, 6, 11, 12, 30)) == date(2026, 6, 11, 13, 30))// lunch → 13:30
        #expect(clock.nextBoundary(after: date(2026, 6, 11, 14, 0)) == date(2026, 6, 11, 16, 0))  // mid-S2 → 16:00
        #expect(clock.nextBoundary(after: date(2026, 6, 11, 16, 30)) == date(2026, 6, 12, 9, 0))  // after close → next day 09:00
        #expect(clock.nextBoundary(after: date(2026, 6, 13, 10, 0)) == date(2026, 6, 15, 9, 0))   // Sat → Mon 09:00
    }

    @Test func withinTradingDayIsTheNineToFourWeekdayWindowIncludingLunch() {
        #expect(clock.isWithinTradingDay(at: date(2026, 6, 11, 9, 0)))       // 09:00 inclusive
        #expect(clock.isWithinTradingDay(at: date(2026, 6, 11, 12, 30)))     // lunch still counts
        #expect(clock.isWithinTradingDay(at: date(2026, 6, 11, 15, 55)))     // post-session, pre-print
        #expect(!clock.isWithinTradingDay(at: date(2026, 6, 11, 8, 59)))     // pre-open
        #expect(!clock.isWithinTradingDay(at: date(2026, 6, 11, 16, 0)))     // 16:00 exclusive — close hands off
        #expect(!clock.isWithinTradingDay(at: date(2026, 6, 13, 10, 0)))     // weekend
    }
}
