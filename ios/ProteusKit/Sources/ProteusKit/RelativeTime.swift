import Foundation

/// Short, scannable timestamps for list rows (v15 §3.6, carried to iOS).
///
/// | Age                  | Shows        |
/// | -------------------- | ------------ |
/// | under a minute       | `now`        |
/// | under an hour        | `4m`         |
/// | under a day          | `3h`         |
/// | under a week         | `Tue`        |
/// | this year            | `Nov 9`      |
/// | older                | `Nov 9, 2025`|
///
/// Kept in ProteusKit (no SwiftUI) so the rule is unit-tested on CI and the
/// app only formats strings.
public enum RelativeTime {
    public static func short(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = .current
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        // Future or just-now timestamps read as "now"; we never invent "in 2m".
        if seconds < 60 { return "now" }

        if seconds < 3_600 {
            return "\(Int(seconds) / 60)m"
        }
        if seconds < 86_400 {
            return "\(Int(seconds) / 3_600)h"
        }
        if seconds < 604_800 {
            return weekday(date, calendar: calendar, locale: locale)
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return day(date, sameYear: sameYear, calendar: calendar, locale: locale)
    }

    /// Same rule for an ISO-8601 string from the hub; empty when unparseable.
    public static func short(
        iso: String,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = .current
    ) -> String {
        guard let date = Formatting.parseISO(iso) else { return "" }
        return short(date, now: now, calendar: calendar, locale: locale)
    }

    private static func weekday(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    private static func day(_ date: Date, sameYear: Bool, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }
}
