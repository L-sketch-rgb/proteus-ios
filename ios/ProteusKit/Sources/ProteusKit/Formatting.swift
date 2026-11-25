import Foundation

public enum Formatting {
    /// Tokens: `999`, `12.3k`, `1.2M`.
    public static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        let n = max(0, value)
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// Duration: `m:ss` under an hour, `h:mm:ss` above.
    public static func duration(milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return duration(seconds: max(0, milliseconds) / 1000)
    }

    public static func duration(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Live elapsed seconds for a running task, from its ISO start time.
    public static func elapsedSeconds(sinceISO iso: String, now: Date = Date()) -> Int? {
        guard let start = parseISO(iso) else { return nil }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    /// `5h` / `7d` usage: whole percent, or "—" when the window is absent.
    public static func percent(_ window: UsageWindow?) -> String {
        guard let window else { return "—" }
        let pct = max(0, min(1, window.utilization)) * 100
        return "\(Int(pct.rounded()))%"
    }

    public static func parseISO(_ iso: String) -> Date? {
        if iso.isEmpty { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    private static func clockFormatter(timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        // v11 §1: the locale's short time (12/24 h as the system uses).
        formatter.locale = locale
        formatter.timeStyle = .short
        return formatter
    }

    /// Locale's short day and month names, without the time.
    private static func dayFormatter(timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }

    /// v10 §3 + v11 §1: the locale's short time, or its day and short time
    /// for another day. Empty when the item has no (or an invalid) timestamp;
    /// never invented.
    public static func timestamp(
        _ iso: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard let date = parseISO(iso) else { return "" }
        return timestamp(date, now: now, timeZone: timeZone, locale: locale)
    }

    /// Same display rule for a value the app already holds as a `Date`
    /// (e.g. a queued prompt's scheduled time).
    public static func timestamp(
        _ date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = clockFormatter(timeZone: timeZone, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return clock.string(from: date)
        }
        let day = dayFormatter(timeZone: timeZone, locale: locale)
        return "\(day.string(from: date)), \(clock.string(from: date))"
    }

    /// v10 §3: `09:12–09:14` for a tool group's span. The day is shown when
    /// the start is not today; a missing end falls back to the start.
    public static func timeRange(
        _ startIso: String,
        _ endIso: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let start = parseISO(startIso)
        let end = parseISO(endIso)
        guard let start else {
            return end == nil ? "" : timestamp(endIso, now: now, timeZone: timeZone, locale: locale)
        }
        guard let end else {
            return timestamp(startIso, now: now, timeZone: timeZone, locale: locale)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = clockFormatter(timeZone: timeZone, locale: locale)
        if calendar.isDate(start, inSameDayAs: end) {
            let startText = clock.string(from: start)
            let endText = clock.string(from: end)
            let prefix = calendar.isDate(start, inSameDayAs: now)
                ? "" : dayFormatter(timeZone: timeZone, locale: locale).string(from: start) + ", "
            let body = startText == endText ? startText : "\(startText)–\(endText)"
            return prefix + body
        }
        let day = dayFormatter(timeZone: timeZone, locale: locale)
        return "\(day.string(from: start)), \(clock.string(from: start))–\(day.string(from: end)), \(clock.string(from: end))"
    }

    /// Newest first by `updatedAt`; the id is a stable tie-breaker.
    public static func sortedNewestFirst(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.sorted { lhs, rhs in
            let l = parseISO(lhs.updatedAt) ?? .distantPast
            let r = parseISO(rhs.updatedAt) ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
    }

    /// One-line tool summary, ported from linux/src/chatmodel.cpp `toolSummary`.
    public static func toolSummary(name: String, input: JSONValue?) -> String {
        let object = input?.objectValue ?? [:]
        func string(_ key: String) -> String {
            object[key]?.displayString ?? ""
        }

        var summary = ""
        switch name {
        case "Bash":
            summary = string("command")
            if let newline = summary.firstIndex(of: "\n") {
                summary = String(summary[..<newline])
            }
        case "Read", "Write", "Edit", "NotebookEdit":
            summary = string("file_path")
            summary = shortenHome(summary)
        case "Grep", "Glob":
            summary = string("pattern")
        case "WebFetch":
            summary = string("url")
        case "WebSearch":
            summary = string("query")
        case "Agent", "Task":
            summary = string("description")
        case "TodoWrite":
            summary = "update todos"
        default:
            break
        }
        if summary.isEmpty {
            summary = input?.compactJSONString() ?? ""
        }
        return truncate(summary, 160)
    }

    public static func shortenHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func truncate(_ text: String, _ limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

public extension SessionInfo {
    /// The model label the app shows. Unknown ids are marked, never swapped.
    func modelLabel(in catalog: ModelCatalog?) -> String {
        if let known = catalog?.model(id: model) { return known.label }
        return model.isEmpty ? "—" : "\(model) (unavailable)"
    }
}
