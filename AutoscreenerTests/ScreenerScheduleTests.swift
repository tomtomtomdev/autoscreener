import Foundation
import Testing
@testable import Autoscreener

@Suite struct ScreenerScheduleTests {
    private func jakartaDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta") ?? .current
        return cal.date(from: DateComponents(
            timeZone: cal.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func onDemandHasNoNextFireAndNoStaleWindow() {
        #expect(ScreenerSchedule.onDemand.staleAfter == nil)
        #expect(ScreenerSchedule.onDemand.nextFireDate(after: Date()) == nil)
    }

    @Test func quarterHourlyJumpsToNext15MinuteBoundary() {
        // 09:02 → 09:15. 09:14 → 09:15. 09:15 → 09:30. 09:59 → 10:00.
        let cases: [(Int, Int, Int, Int)] = [
            (9, 2, 9, 15),
            (9, 14, 9, 15),
            (9, 15, 9, 30),
            (9, 59, 10, 0),
        ]
        for (h1, m1, h2, m2) in cases {
            let now = jakartaDate(2026, 6, 1, h1, m1)
            let next = ScreenerSchedule.quarterHourly.nextFireDate(after: now)
            #expect(next == jakartaDate(2026, 6, 1, h2, m2))
        }
    }

    @Test func hourlyJumpsToNextTopOfHour() {
        let now = jakartaDate(2026, 6, 1, 9, 32)
        #expect(ScreenerSchedule.hourly.nextFireDate(after: now)
                == jakartaDate(2026, 6, 1, 10, 0))
    }

    @Test func dailyOpenLandsAt0845NextDayWhenAfterTime() {
        // 09:00 same day → next 08:45 is tomorrow.
        let now = jakartaDate(2026, 6, 1, 9, 0)
        #expect(ScreenerSchedule.dailyOpen.nextFireDate(after: now)
                == jakartaDate(2026, 6, 2, 8, 45))
    }

    @Test func dailyOpenLandsToday0845WhenStillBeforeTime() {
        let now = jakartaDate(2026, 6, 1, 7, 0)
        #expect(ScreenerSchedule.dailyOpen.nextFireDate(after: now)
                == jakartaDate(2026, 6, 1, 8, 45))
    }

    @Test func dailyCloseLandsAt1615() {
        let now = jakartaDate(2026, 6, 1, 9, 0)
        #expect(ScreenerSchedule.dailyClose.nextFireDate(after: now)
                == jakartaDate(2026, 6, 1, 16, 15))
    }

    @Test func staleWindowsMatchModeIntent() {
        #expect(ScreenerSchedule.quarterHourly.staleAfter == TimeInterval(15 * 60))
        #expect(ScreenerSchedule.hourly.staleAfter == TimeInterval(60 * 60))
        #expect(ScreenerSchedule.dailyOpen.staleAfter == TimeInterval(24 * 60 * 60))
        #expect(ScreenerSchedule.dailyClose.staleAfter == TimeInterval(24 * 60 * 60))
    }

    @Test func allCasesHaveADisplayName() {
        for mode in ScreenerSchedule.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }
}
