import Foundation

public struct ProjectGroup: Identifiable, Equatable, Sendable {
    public var project: ProjectDef
    public var sessions: [SessionInfo]

    public var id: String { project.name }
    public var name: String { project.name }

    public init(project: ProjectDef, sessions: [SessionInfo]) {
        self.project = project
        self.sessions = sessions
    }
}

/// The sidebar model from v4: project groups first, then ungrouped chats.
public struct SessionListing: Equatable, Sendable {
    /// Projects with chats (newest activity first), then empty projects (alphabetical).
    public var projects: [ProjectGroup]
    /// Ungrouped chats, newest first. A new chat is the first row here.
    public var chats: [SessionInfo]

    public init(projects: [ProjectGroup] = [], chats: [SessionInfo] = []) {
        self.projects = projects
        self.chats = chats
    }
}

/// Sessions and project definitions from the hub, with the v4 ordering and
/// grouping rules. Grouping is explicit only: `SessionInfo.project` is the
/// single source of truth; folder prefixes are never matched here.
public final class SessionStore {
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var projectDefs: [ProjectDef] = []

    /// Called after any mutation. The app wraps this in @Observable.
    public var onChange: (() -> Void)?

    public init() {}

    public var projectNames: [String] { projectDefs.map(\.name) }

    public func replace(sessions: [SessionInfo], projects: [ProjectDef]? = nil) {
        self.sessions = Formatting.sortedNewestFirst(dedupe(sessions))
        if let projects {
            projectDefs = projects
        }
        onChange?()
    }

    public func replace(projectDefs: [ProjectDef], names: [String]? = nil) {
        if let names, projectDefs.isEmpty {
            self.projectDefs = names.map { ProjectDef(name: $0) }
        } else {
            self.projectDefs = projectDefs
        }
        onChange?()
    }

    public func setProjects(_ defs: [ProjectDef]) {
        projectDefs = defs
        onChange?()
    }

    public func upsert(_ session: SessionInfo) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions = Formatting.sortedNewestFirst(sessions)
        onChange?()
    }

    public func remove(id: String) {
        let before = sessions.count
        sessions.removeAll { $0.id == id }
        if sessions.count != before {
            onChange?()
        }
    }

    public func session(id: String) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    public func sessions(inProject name: String) -> [SessionInfo] {
        sessions.filter { $0.project == name }
    }

    public func project(named name: String) -> ProjectDef? {
        projectDefs.first { $0.name == name }
    }

    /// The v4 listing. `search` filters across titles, folders and project names.
    public func listing(search: String? = nil) -> SessionListing {
        let query = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let knownProjects = Set(projectDefs.map(\.name))
        let visible = query.isEmpty ? sessions : sessions.filter { session in
            session.title.lowercased().contains(query)
                || session.cwd.lowercased().contains(query)
                || session.project.lowercased().contains(query)
                || session.model.lowercased().contains(query)
        }

        var groups: [ProjectGroup] = []
        var chats: [SessionInfo] = []
        for session in visible {
            if !session.project.isEmpty, knownProjects.contains(session.project) {
                if let index = groups.firstIndex(where: { $0.project.name == session.project }) {
                    groups[index].sessions.append(session)
                } else if let def = project(named: session.project) {
                    groups.append(ProjectGroup(project: def, sessions: [session]))
                }
            } else {
                // Unknown/removed project assignments are shown as ungrouped
                // instead of silently disappearing.
                chats.append(session)
            }
        }

        // Active projects: newest activity first (groups already see sessions
        // newest-first, so the first element is the group's newest).
        groups.sort { lhs, rhs in
            let l = lhs.sessions.first.flatMap { Formatting.parseISO($0.updatedAt) } ?? .distantPast
            let r = rhs.sessions.first.flatMap { Formatting.parseISO($0.updatedAt) } ?? .distantPast
            if l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        // Empty projects still show, after active ones, alphabetically.
        let empty = projectDefs
            .filter { def in !groups.contains(where: { $0.project.name == def.name }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        groups.append(contentsOf: empty.map { ProjectGroup(project: $0, sessions: []) })

        return SessionListing(projects: groups, chats: chats)
    }

    public func allProjectGroups() -> [ProjectGroup] {
        listing(search: nil).projects
    }

    private func dedupe(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var seen = Set<String>()
        var out: [SessionInfo] = []
        out.reserveCapacity(sessions.count)
        for session in sessions where !seen.contains(session.id) {
            seen.insert(session.id)
            out.append(session)
        }
        return out
    }
}
