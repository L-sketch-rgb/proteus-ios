import Foundation

/// One row of the composer's `/` menu (docs/design/v9-commands-drafts-perf.md §3).
public struct SlashCommand: Identifiable, Equatable, Sendable {
    public enum Group: String, Equatable, Sendable {
        /// Handled in the app and never sent as text.
        case proteus = "Proteus"
        /// Advertised by the Claude engine (`SessionInfo.commands`); sent as text.
        case engine = "Claude Code"
    }

    /// Includes the leading slash, e.g. `/queue`.
    public var name: String
    public var summary: String
    public var group: Group
    /// The new-chat composer only offers `/model`, `/mode` and `/help`.
    public var allowedInNewChat: Bool

    public var id: String { "\(group.rawValue)/\(name)" }

    public init(name: String, summary: String, group: Group = .proteus, allowedInNewChat: Bool = false) {
        self.name = name
        self.summary = summary
        self.group = group
        self.allowedInNewChat = allowedInNewChat
    }
}

/// The Proteus command table, filtering and parsing for the `/` menu.
public enum SlashCommands {

    /// The commands the app itself understands, in menu order.
    public static let proteus: [SlashCommand] = [
        SlashCommand(name: "/queue", summary: "Queue the message after the current turn"),
        SlashCommand(name: "/schedule", summary: "Send the message at a chosen time"),
        SlashCommand(name: "/model", summary: "Change the chat's model", allowedInNewChat: true),
        SlashCommand(name: "/mode", summary: "Change the permission mode", allowedInNewChat: true),
        SlashCommand(name: "/stop", summary: "Stop the running turn"),
        SlashCommand(name: "/rename", summary: "Rename this chat"),
        SlashCommand(name: "/new", summary: "New chat in the same folder and project"),
        SlashCommand(name: "/help", summary: "List commands", allowedInNewChat: true),
    ]

    private static let engineSummaries: [String: String] = [
        "/compact": "Compact the conversation",
        "/review": "Review a pull request",
        "/init": "Initialize project instructions",
        "/help": "List Claude Code commands",
        "/model": "Change the Claude model",
    ]

    /// Proteus commands first, then the engine's own commands under
    /// "Claude Code". Duplicate names (an engine `/model`, say) are dropped.
    public static func list(engineCommands: [String], newChat: Bool = false) -> [SlashCommand] {
        var seen = Set<String>()
        var rows: [SlashCommand] = []
        for command in proteus {
            if newChat && !command.allowedInNewChat { continue }
            seen.insert(command.name)
            rows.append(command)
        }
        for raw in engineCommands {
            let name = raw.hasPrefix("/") ? raw : "/" + raw
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            rows.append(SlashCommand(
                name: name,
                summary: engineSummaries[name] ?? "Claude Code command",
                group: .engine
            ))
        }
        return rows
    }

    /// Rows for the menu above the composer. The menu is open only while the
    /// text is a single `/word` (no whitespace yet); it filters by prefix.
    public static func menu(
        for text: String,
        engineCommands: [String],
        newChat: Bool = false
    ) -> [SlashCommand] {
        guard let token = commandToken(in: text) else { return [] }
        let query = token.lowercased()
        return list(engineCommands: engineCommands, newChat: newChat)
            .filter { $0.name.lowercased().hasPrefix(query) }
    }

    /// The `/word` at the start of the composer, or nil when the menu should be
    /// closed (no leading slash, or the user has typed past the command name).
    public static func commandToken(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let token = String(text.prefix { !$0.isWhitespace })
        guard token.count == text.count else { return nil }
        return token
    }

    /// Split `/command argument` into its command and the rest. The text must
    /// start with a slash on its first character.
    public static func parse(_ text: String) -> (command: String, argument: String)? {
        guard text.hasPrefix("/") else { return nil }
        let token = String(text.prefix { !$0.isWhitespace })
        let rest = text.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (token.lowercased(), rest)
    }

    public static func isProteusCommand(_ command: String) -> Bool {
        proteus.contains { $0.name.lowercased() == command.lowercased() }
    }
}
