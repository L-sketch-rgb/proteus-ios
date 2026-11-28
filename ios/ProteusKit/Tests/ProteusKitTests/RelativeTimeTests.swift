import XCTest
@testable import ProteusKit

final class RelativeTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    /// Fixed "now": 24 Nov 2026, 12:00 UTC.
    private var now: Date { date(2026, 11, 24) }

    private func short(_ date: Date) -> String {
        RelativeTime.short(date, now: now, calendar: calendar, locale: locale)
    }

    func testUnderAMinuteReadsNow() {
        XCTAssertEqual(short(now), "now")
        XCTAssertEqual(short(date(2026, 11, 24, 11, 59, 30)), "now")
        // A clock-skewed future timestamp never becomes "in 2m".
        XCTAssertEqual(short(date(2026, 11, 24, 12, 2)), "now")
    }

    func testMinutes() {
        XCTAssertEqual(short(date(2026, 11, 24, 11, 56)), "4m")
        XCTAssertEqual(short(date(2026, 11, 24, 11, 0, 30)), "59m")
    }

    func testHours() {
        XCTAssertEqual(short(date(2026, 11, 24, 9)), "3h")
        XCTAssertEqual(short(date(2026, 11, 23, 12, 30)), "23h")
    }

    func testWeekdayInsideAWeek() {
        // 21 Nov 2026 is a Saturday.
        XCTAssertEqual(short(date(2026, 11, 21)), "Sat")
        XCTAssertEqual(short(date(2026, 11, 18)), "Wed")
    }

    func testDayAndMonthThisYear() {
        XCTAssertEqual(short(date(2026, 11, 9)), "Nov 9")
        XCTAssertEqual(short(date(2026, 3, 1)), "Mar 1")
    }

    func testOlderThanThisYearCarriesTheYear() {
        XCTAssertEqual(short(date(2025, 11, 9)), "Nov 9, 2025")
    }

    func testISOStringUsesTheSameRule() {
        XCTAssertEqual(
            RelativeTime.short(iso: "2026-11-24T08:00:00Z", now: now, calendar: calendar, locale: locale),
            "4h"
        )
        XCTAssertEqual(
            RelativeTime.short(iso: "", now: now, calendar: calendar, locale: locale),
            ""
        )
        XCTAssertEqual(
            RelativeTime.short(iso: "not a date", now: now, calendar: calendar, locale: locale),
            ""
        )
    }
}
