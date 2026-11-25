import Foundation

/// One section of a chat list.
public struct ChatGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case needsYou
        case active
        case older
        case today
        case thisWeek
    }

    public var kind: Kind
    public var sessions: [SessionInfo]

    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .needsYou: return "Needs you"
        case .active: return "Active"
        case .older: return "Older"
        case .today: return "Today"
        case .thisWeek: return "This week"
        }
    }

    /// Only the tail section folds; the important rows never hide.
    public var collapsible: Bool { kind == .older }
    public var collapsedByDefault: Bool { kind == .older }

    public init(kind: Kind, sessions: [SessionInfo]) {
        self.kind = kind
        self.sessions = sessions
    }
}

/// The v15 §3.3 / §3.4 grouping rules, shared by every chat list on the phone.
///
/// The hub sends sessions newest-first and has no notion of "older"; the split
/// is computed here so the view only renders what it is given, and so the rules
/// can be tested without SwiftUI.
public enum ChatGroups {
    /// A chat stays "active" for this long after its last update.
    public static let activeWindow: TimeInterval = 7 * 24 * 60 * 60

    public enum Scope: Sendable {
        /// A project slot: Needs you / Active / Older.
        case project
        /// The one-off "Chats" slot: Today / This week / Older.
        case oneOff
    }

    /// v15 §3.5a. `nil` last-seen means the chat has never been seen on this
    /// device, which counts as seen (no bold on a fresh install).
    public static func isUnread(_ session: SessionInfo, lastSeen: Date?) -> Bool {
        switch session.statusKind {
        case .running, .waiting, .error:
            return false
        case .idle, .stopped:
            break
        }
        guard let lastSeen else { return false }
        guard let updated = Formatting.parseISO(session.updatedAt) else { return false }
        return updated > lastSeen
    }

    /// Waiting, errored or unread: the rows that must never hide in "Older".
    public static func needsYou(_ session: SessionInfo, lastSeen: Date?) -> Bool {
        switch session.statusKind {
        case .waiting, .error:
            return true
        case .running, .idle, .stopped:
            return isUnread(session, lastSeen: lastSeen)
        }
    }

    public static func groups(
        for sessions: [SessionInfo],
        scope: Scope,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        lastSeen: (String) -> Date? = { _ in nil }
    ) -> [ChatGroup] {
        let sorted = Formatting.sortedNewestFirst(sessions)
        switch scope {
        case .project:
            return projectGroups(sorted, now: now, lastSeen: lastSeen)
        case .oneOff:
            return oneOffGroups(sorted, now: now, calendar: calendar, lastSeen: lastSeen)
        }
    }

    // MARK: - Project slot

    private static func projectGroups(
        _ sessions: [SessionInfo],
        now: Date,
        lastSeen: (String) -> Date?
    ) -> [ChatGroup] {
        let cutoff = now.addingTimeInterval(-activeWindow)
        var needsYou: [SessionInfo] = []
        var active: [SessionInfo] = []
        var older: [SessionInfo] = []

        for session in sessions {
            if ChatGroups.needsYou(session, lastSeen: lastSeen(session.id)) {
                needsYou.append(session)
                continue
            }
            let updated = Formatting.parseISO(session.updatedAt)
            let recent = updated.map { $0 >= cutoff } ?? false
            if recent || session.statusKind == .running {
                active.append(session)
            } else {
                older.append(session)
            }
        }

        return [
            ChatGroup(kind: .needsYou, sessions: needsYou),
            ChatGroup(kind: .active, sessions: active),
            ChatGroup(kind: .older, sessions: older),
        ].filter { !$0.sessions.isEmpty }
    }

    // MARK: - Chats slot

    private static func oneOffGroups(
        _ sessions: [SessionInfo],
        now: Date,
        calendar: Calendar,
        lastSeen: (String) -> Date?
    ) -> [ChatGroup] {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-activeWindow)
        var today: [SessionInfo] = []
        var thisWeek: [SessionInfo] = []
        var older: [SessionInfo] = []

        for session in sessions {
            // A chat that needs you is always in Today, whatever its age.
            if ChatGroups.needsYou(session, lastSeen: lastSeen(session.id)) {
                today.append(session)
                continue
            }
            guard let updated = Formatting.parseISO(session.updatedAt) else {
                older.append(session)
                continue
            }
            if updated >= dayStart || session.statusKind == .running {
                today.append(session)
            } else if updated >= weekStart {
                thisWeek.append(session)
            } else {
                older.append(session)
            }
        }

        return [
            ChatGroup(kind: .today, sessions: today),
            ChatGroup(kind: .thisWeek, sessions: thisWeek),
            ChatGroup(kind: .older, sessions: older),
        ].filter { !$0.sessions.isEmpty }
    }
}
