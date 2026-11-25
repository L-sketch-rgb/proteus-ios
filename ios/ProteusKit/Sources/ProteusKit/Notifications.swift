import Foundation

// MARK: - Wire shape (v8 §3)

/// The hub's ntfy configuration. The topic is a secret: it is only shown in
/// Settings (as a subscribe link and QR) and is never logged.
public struct NotificationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var topic: String

    public static let defaultServer = "https://ntfy.sh"

    public init(enabled: Bool = false, server: String = NotificationSettings.defaultServer, topic: String = "") {
        self.enabled = enabled
        self.server = server
        self.topic = topic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? NotificationSettings.defaultServer
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case enabled, server, topic }

    public var hasTopic: Bool { !topic.isEmpty }

    /// `https://ntfy.sh/proteus-…` — used to POST. Never printed.
    public var postURL: URL? {
        guard hasTopic else { return nil }
        let base = server.hasSuffix("/") ? String(server.dropLast()) : server
        return URL(string: "\(base)/\(topic)")
    }

    /// The `ntfy://` deep link that opens the ntfy iOS app on this topic.
    public static func subscribeURL(server: String, topic: String) -> URL? {
        guard !topic.isEmpty, let parsed = URLComponents(string: server),
              let host = parsed.host, !host.isEmpty,
              parsed.scheme == "http" || parsed.scheme == "https" else { return nil }

        var components = URLComponents()
        components.scheme = "ntfy"
        components.host = host
        components.port = parsed.port
        var path = parsed.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/" + topic
        return components.url
    }

    public var subscribeURL: URL? {
        NotificationSettings.subscribeURL(server: server, topic: topic)
    }
}

/// `{t:"notifications", enabled, server, topic}` broadcast.
public struct NotificationsFrame: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var topic: String

    public init(enabled: Bool, server: String, topic: String) {
        self.enabled = enabled
        self.server = server
        self.topic = topic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? NotificationSettings.defaultServer
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case enabled, server, topic }

    public var settings: NotificationSettings {
        NotificationSettings(enabled: enabled, server: server, topic: topic)
    }
}

// MARK: - Store

/// Mirrors the hub's notification configuration and builds the two frames the
/// Settings screen sends. Holds no UI state beyond the settings.
public final class NotificationStore {
    public private(set) var settings: NotificationSettings

    public var onChange: (() -> Void)?

    public init(settings: NotificationSettings = NotificationSettings()) {
        self.settings = settings
    }

    public func apply(_ welcome: WelcomeFrame) {
        guard let incoming = welcome.notifications else { return }
        settings = incoming
        onChange?()
    }

    public func apply(_ frame: NotificationsFrame) {
        settings = frame.settings
        onChange?()
    }

    public func apply(_ settings: NotificationSettings) {
        self.settings = settings
        onChange?()
    }

    public func reset() {
        settings = NotificationSettings()
        onChange?()
    }

    public var isEnabled: Bool { settings.enabled }
    public var subscribeURL: URL? { settings.subscribeURL }

    // MARK: Frames

    /// `notifications.set`. Omitted fields keep their hub value.
    public static func setFrame(
        enabled: Bool? = nil,
        server: String? = nil,
        regenerate: Bool? = nil,
        rid: String? = nil
    ) -> ClientFrame {
        var fields: [String: JSONValue] = [:]
        if let enabled { fields["enabled"] = .bool(enabled) }
        if let server { fields["server"] = .string(server) }
        if let regenerate { fields["regenerate"] = .bool(regenerate) }
        return ClientFrame("notifications.set", rid: rid, fields)
    }

    /// `notifications.test`.
    public static func testFrame(rid: String? = nil) -> ClientFrame {
        ClientFrame("notifications.test", rid: rid)
    }
}
