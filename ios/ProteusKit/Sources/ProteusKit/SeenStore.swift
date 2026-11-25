import Foundation

/// Which chats this device has already shown (v15 §3.5a, adapted for iOS).
///
/// The hub has no unread state and none is added. The app keeps `lastSeenAt`
/// per session id locally:
///
/// - it is written whenever a chat is open and visible, and when it is left;
/// - a chat is **unread** when its status is not running/waiting/error and its
///   `updatedAt` is newer than `lastSeenAt`;
/// - a chat never seen on this device counts as seen, so a fresh install is not
///   one wall of bold titles.
///
/// Stored in `UserDefaults` as a `[id: secondsSince1970]` dictionary: small,
/// synchronous, and testable without a file system.
public final class SeenStore {
    public static let defaultKey = "proteus.seen"

    private let defaults: UserDefaults
    private let key: String
    private var cache: [String: Double]?

    public init(defaults: UserDefaults = .standard, key: String = SeenStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func lastSeen(_ id: String) -> Date? {
        guard let seconds = load()[id] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func markSeen(_ id: String, at date: Date = Date()) {
        var map = load()
        map[id] = date.timeIntervalSince1970
        save(map)
    }

    public func markSeen(_ ids: [String], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var map = load()
        let seconds = date.timeIntervalSince1970
        for id in ids { map[id] = seconds }
        save(map)
    }

    /// Forget chats the hub no longer has, so the store cannot grow forever.
    public func prune(keeping ids: Set<String>) {
        let map = load()
        let kept = map.filter { ids.contains($0.key) }
        if kept.count != map.count { save(kept) }
    }

    /// v15 §3.5a. Never unread while the hub says it is busy, and never unread
    /// for a chat this device has not seen at all.
    public func isUnread(_ session: SessionInfo) -> Bool {
        switch session.statusKind {
        case .running, .waiting, .error:
            return false
        case .idle, .stopped:
            break
        }
        guard let seenAt = lastSeen(session.id) else { return false }
        guard let updated = Formatting.parseISO(session.updatedAt) else { return false }
        return updated > seenAt
    }

    // MARK: - Storage

    private func load() -> [String: Double] {
        if let cache { return cache }
        var out: [String: Double] = [:]
        for (id, value) in defaults.dictionary(forKey: key) ?? [:] {
            if let number = value as? NSNumber {
                out[id] = number.doubleValue
            } else if let number = value as? Double {
                out[id] = number
            } else if let number = value as? Int {
                out[id] = Double(number)
            }
        }
        cache = out
        return out
    }

    private func save(_ map: [String: Double]) {
        cache = map
        defaults.set(map, forKey: key)
    }
}
