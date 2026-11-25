import Foundation

// MARK: - Wire shapes (v9 §2)

/// One item of a `queue` frame / `welcome.queues`, in due order.
public struct QueueItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var qid: String
    public var text: String
    /// ISO time, or nil for "after the current turn".
    public var at: String?
    public var createdAt: String

    public var id: String { qid }
    public var isScheduled: Bool { at != nil }

    public var scheduledDate: Date? {
        guard let at else { return nil }
        return Formatting.parseISO(at)
    }

    /// When the item is due: its scheduled time, else its creation time.
    public var dueDate: Date? {
        scheduledDate ?? Formatting.parseISO(createdAt)
    }

    public init(qid: String, text: String, at: String? = nil, createdAt: String = "") {
        self.qid = qid
        self.text = text
        self.at = at
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qid = try c.decode(String.self, forKey: .qid)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try c.decodeIfPresent(String.self, forKey: .at)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case qid, text, at, createdAt }
}

/// `{t:"queue", id, items}` after any change to a chat's queue.
public struct QueueFrame: Codable, Equatable, Sendable {
    public var id: String
    public var items: [QueueItem]

    public init(id: String, items: [QueueItem]) {
        self.id = id
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        items = try c.decodeIfPresent([QueueItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, items }
}

/// The `at` field of `queue.update`: absent, explicitly null, or an ISO time.
public enum QueueTimeUpdate: Equatable, Sendable {
    case unchanged
    case none
    case at(String)
}

// MARK: - Queue store

/// Every chat's pending prompt queue, mirrored from `welcome.queues` and the
/// `queue` broadcasts. The hub is authoritative and sorts items; the store only
/// keeps the last frame (and removes a chat's items when the chat goes away).
public final class QueueStore {
    public private(set) var queues: [String: [QueueItem]] = [:]

    public var onChange: (() -> Void)?

    public init() {}

    public func apply(welcome queues: [String: [QueueItem]]) {
        self.queues = queues.filter { !$0.value.isEmpty }
        onChange?()
    }

    public func apply(_ frame: QueueFrame) {
        if frame.items.isEmpty {
            queues.removeValue(forKey: frame.id)
        } else {
            queues[frame.id] = frame.items
        }
        onChange?()
    }

    public func items(for id: String) -> [QueueItem] {
        queues[id] ?? []
    }

    public func count(for id: String) -> Int {
        queues[id]?.count ?? 0
    }

    public func item(qid: String) -> QueueItem? {
        for items in queues.values {
            if let item = items.first(where: { $0.qid == qid }) { return item }
        }
        return nil
    }

    public func removeChat(_ id: String) {
        guard queues.removeValue(forKey: id) != nil else { return }
        onChange?()
    }

    /// Forget every chat's queue (switching workstation).
    public func clearAll() {
        queues.removeAll()
        onChange?()
    }

    public var sessionIds: [String] {
        queues.keys.sorted()
    }
}

// MARK: - Time menu (v9 §3)

/// One resolved schedule choice: the absolute time, its ISO form and the
/// "Tomorrow at 09:00" wording the time menu shows.
public struct ScheduleChoice: Equatable, Sendable {
    public var date: Date
    public var iso: String
    public var phrase: String

    public init(date: Date, iso: String, phrase: String) {
        self.date = date
        self.iso = iso
        self.phrase = phrase
    }
}

/// The fixed presets of the time menu.
public enum SchedulePreset: String, CaseIterable, Identifiable, Sendable {
    case in15Minutes
    case in30Minutes
    case in1Hour
    case in2Hours
    case in4Hours
    case tonight
    case tomorrowMorning

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .in15Minutes: return "In 15 minutes"
        case .in30Minutes: return "In 30 minutes"
        case .in1Hour: return "In 1 hour"
        case .in2Hours: return "In 2 hours"
        case .in4Hours: return "In 4 hours"
        case .tonight: return "Tonight 21:00"
        case .tomorrowMorning: return "Tomorrow 09:00"
        }
    }

    public var offset: TimeInterval? {
        switch self {
        case .in15Minutes: return 15 * 60
        case .in30Minutes: return 30 * 60
        case .in1Hour: return 60 * 60
        case .in2Hours: return 2 * 60 * 60
        case .in4Hours: return 4 * 60 * 60
        case .tonight, .tomorrowMorning: return nil
        }
    }
}

/// A custom date row of the time menu: Today, Tomorrow, then the next seven
/// days by name, weekends included (local time).
public struct CustomDateOption: Equatable, Identifiable, Sendable {
    public var date: Date
    public var label: String

    public var id: Double { date.timeIntervalSince1970 }

    public init(date: Date, label: String) {
        self.date = date
        self.label = label
    }
}

/// Pure date arithmetic for the time menu. Every method takes the clock's
/// `now` and a `Calendar` (with the local time zone) so tests are deterministic.
public enum SchedulePresets {

    public static let minuteStep = 5

    public static var hourOptions: [Int] { Array(0...23) }
    public static var minuteOptions: [Int] { Array(stride(from: 0, to: 60, by: minuteStep)) }

    /// Resolve a preset against `now`.
    public static func choice(
        _ preset: SchedulePreset,
        now: Date,
        calendar: Calendar
    ) -> ScheduleChoice {
        let date: Date
        if let offset = preset.offset {
            date = now.addingTimeInterval(offset)
        } else if preset == .tonight {
            let tonight = time(hour: 21, minute: 0, on: startOfDay(now, calendar: calendar), calendar: calendar)
            // "Tonight 21:00 (or tomorrow 21:00 if that has passed)".
            date = now > tonight
                ? time(hour: 21, minute: 0, on: add(days: 1, to: startOfDay(now, calendar: calendar), calendar: calendar), calendar: calendar)
                : tonight
        } else {
            let tomorrow = add(days: 1, to: startOfDay(now, calendar: calendar), calendar: calendar)
            date = time(hour: 9, minute: 0, on: tomorrow, calendar: calendar)
        }
        return choice(date: date, now: now, calendar: calendar, knownPreset: preset)
    }

    /// "Tomorrow at 09:00" / "Today at 14:00" / "Wednesday at 14:00".
    public static func phrase(for date: Date, now: Date, calendar: Calendar) -> String {
        let hm = String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        let days = dayOffset(from: now, to: date, calendar: calendar)
        switch days {
        case 0: return "Today at \(hm)"
        case 1: return "Tomorrow at \(hm)"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE"
            return "\(formatter.string(from: date)) at \(hm)"
        }
    }

    /// The custom date rows: Today, Tomorrow, then every following day.
    /// Weekends are included on purpose (v17-D): a Claude Code limit can reset
    /// on a Sunday, and a weekday-only list could not express that.
    public static func customDates(now: Date, calendar: Calendar) -> [CustomDateOption] {
        let today = startOfDay(now, calendar: calendar)
        var options = [
            CustomDateOption(date: today, label: "Today"),
            CustomDateOption(date: add(days: 1, to: today, calendar: calendar), label: "Tomorrow"),
        ]
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"

        for day in 2...8 {
            let date = add(days: day, to: today, calendar: calendar)
            options.append(CustomDateOption(date: date, label: formatter.string(from: date)))
        }
        return options
    }

    /// Resolve the custom date plus hour/minute (5-minute steps, local time).
    public static func customChoice(
        day: Date,
        hour: Int,
        minute: Int,
        now: Date,
        calendar: Calendar
    ) -> ScheduleChoice {
        let date = time(
            hour: max(0, min(23, hour)),
            minute: max(0, min(59, minute)),
            on: startOfDay(day, calendar: calendar),
            calendar: calendar
        )
        return choice(date: date, now: now, calendar: calendar, knownPreset: nil)
    }

    /// ISO 8601 with time, in UTC (`Z`), which the hub parses.
    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A choice with a phrase. Presets get their fixed wording ("Tonight at
    /// 21:00"); anything else uses the relative day wording.
    public static func choice(
        date: Date,
        now: Date,
        calendar: Calendar,
        knownPreset: SchedulePreset?
    ) -> ScheduleChoice {
        let phrase: String
        if let preset = knownPreset {
            switch preset {
            case .in15Minutes: phrase = "In 15 minutes"
            case .in30Minutes: phrase = "In 30 minutes"
            case .in1Hour: phrase = "In 1 hour"
            case .in2Hours: phrase = "In 2 hours"
            case .in4Hours: phrase = "In 4 hours"
            case .tonight: phrase = "Tonight at 21:00"
            case .tomorrowMorning: phrase = "Tomorrow at 09:00"
            }
        } else {
            phrase = SchedulePresets.phrase(for: date, now: now, calendar: calendar)
        }
        return ScheduleChoice(date: date, iso: isoString(date), phrase: phrase)
    }

    // MARK: Calendar helpers

    public static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func add(days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    public static func time(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    public static func dayOffset(from: Date, to: Date, calendar: Calendar) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
    }
}
