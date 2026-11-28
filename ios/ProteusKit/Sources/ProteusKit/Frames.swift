import Foundation

// MARK: - Outgoing frames

/// An app -> hub frame. `t` is the frame type, `rid` is the optional request
/// id echoed by the hub, and `fields` holds the frame's payload. Building the
/// payload from a dictionary (instead of one struct per frame) keeps optional
/// versus absent fields explicit and mirrors `protocol.md` §2 one row at a time.
public struct ClientFrame: Sendable {
    public var t: String
    public var rid: String?
    public var fields: [String: JSONValue]

    public init(_ t: String, rid: String? = nil, _ fields: [String: JSONValue] = [:]) {
        self.t = t
        self.rid = rid
        self.fields = fields
    }

    public func encoded() throws -> Data {
        var object = fields
        object["t"] = .string(t)
        if let rid { object["rid"] = .string(rid) }
        return try JSONEncoder.proteus.encode(JSONValue.object(object))
    }

    public func jsonString() throws -> String {
        String(data: try encoded(), encoding: .utf8) ?? "{}"
    }
}

public extension JSONValue {
    /// Convert any Encodable value (models, image arrays) into a JSON tree.
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.proteus.encode(value)
        return try JSONDecoder.proteus.decode(JSONValue.self, from: data)
    }
}

// Request constructors for every app -> hub frame in protocol.md §2.
public extension ClientFrame {
    static func hello(token: String, client: String = "ios", version: Int = 1) -> ClientFrame {
        ClientFrame("hello", [
            "token": .string(token),
            "client": .string(client),
            "version": .int(version),
        ])
    }

    static func sessionsList(rid: String? = nil) -> ClientFrame {
        ClientFrame("sessions.list", rid: rid)
    }

    static func sessionOpen(id: String, since: Int? = nil, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id)]
        if let since { fields["since"] = .int(since) }
        return ClientFrame("session.open", rid: rid, fields)
    }

    static func sessionClose(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.close", rid: rid, ["id": .string(id)])
    }

    static func sessionNew(
        cwd: String,
        model: String,
        text: String,
        images: [ImageIn]? = nil,
        permissionMode: String? = nil,
        project: String? = nil,
        rid: String? = nil
    ) throws -> ClientFrame {
        var fields: [String: JSONValue] = [
            "cwd": .string(cwd),
            "model": .string(model),
            "text": .string(text),
        ]
        if let images, !images.isEmpty { fields["images"] = try .from(images) }
        if let permissionMode { fields["permissionMode"] = .string(permissionMode) }
        if let project { fields["project"] = .string(project) }
        return ClientFrame("session.new", rid: rid, fields)
    }

    static func sessionDelete(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.delete", rid: rid, ["id": .string(id)])
    }

    static func sessionSend(id: String, text: String, images: [ImageIn]? = nil, rid: String? = nil) throws -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id), "text": .string(text)]
        if let images, !images.isEmpty { fields["images"] = try .from(images) }
        return ClientFrame("session.send", rid: rid, fields)
    }

    /// v10 §11: edit a sent prompt. The hub interrupts a running turn, then
    /// sends the text exactly as `session.send` would.
    static func sessionResend(id: String, text: String, images: [ImageIn]? = nil, rid: String? = nil) throws -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id), "text": .string(text)]
        if let images, !images.isEmpty { fields["images"] = try .from(images) }
        return ClientFrame("session.resend", rid: rid, fields)
    }

    static func sessionInterrupt(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.interrupt", rid: rid, ["id": .string(id)])
    }

    static func sessionStop(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.stop", rid: rid, ["id": .string(id)])
    }

    static func sessionSetModel(id: String, model: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.setModel", rid: rid, ["id": .string(id), "model": .string(model)])
    }

    static func sessionSetMode(id: String, mode: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.setMode", rid: rid, ["id": .string(id), "mode": .string(mode)])
    }

    static func sessionRename(id: String, title: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.rename", rid: rid, ["id": .string(id), "title": .string(title)])
    }

    static func sessionSetProject(id: String, project: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("session.setProject", rid: rid, ["id": .string(id), "project": .string(project)])
    }

    static func projectSave(project: ProjectDef, oldName: String? = nil, rid: String? = nil) throws -> ClientFrame {
        var fields: [String: JSONValue] = ["project": try .from(project)]
        if let oldName { fields["oldName"] = .string(oldName) }
        return ClientFrame("project.save", rid: rid, fields)
    }

    static func projectDelete(name: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("project.delete", rid: rid, ["name": .string(name)])
    }

    static func agentsList(rid: String? = nil) -> ClientFrame {
        ClientFrame("agents.list", rid: rid)
    }

    static func permissionReply(
        id: String,
        reqId: String,
        allow: Bool,
        always: Bool? = nil,
        message: String? = nil,
        answers: [String: String]? = nil,
        annotations: [String: [String: String]]? = nil,
        rid: String? = nil
    ) -> ClientFrame {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "reqId": .string(reqId),
            "allow": .bool(allow),
        ]
        if let always { fields["always"] = .bool(always) }
        if let message { fields["message"] = .string(message) }
        if let answers {
            fields["answers"] = .object(answers.mapValues { .string($0) })
        }
        if let annotations {
            fields["annotations"] = .object(
                annotations.mapValues { notes in
                    .object(notes.mapValues { .string($0) })
                }
            )
        }
        return ClientFrame("permission.reply", rid: rid, fields)
    }

    static func accountSwitch(name: String, now: Bool? = nil, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = ["name": .string(name)]
        if let now { fields["now"] = .bool(now) }
        return ClientFrame("account.switch", rid: rid, fields)
    }

    static func accountLogin(name: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("account.login", rid: rid, ["name": .string(name)])
    }

    static func accountRename(name: String, label: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("account.rename", rid: rid, ["name": .string(name), "label": .string(label)])
    }

    static func accountAdd(provider: String, name: String, label: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("account.add", rid: rid, [
            "provider": .string(provider),
            "name": .string(name),
            "label": .string(label),
        ])
    }

    static func accountRemove(name: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("account.remove", rid: rid, ["name": .string(name)])
    }

    static func providerSave(_ provider: ProviderConfig, rid: String? = nil) throws -> ClientFrame {
        ClientFrame("provider.save", rid: rid, ["provider": try .from(provider)])
    }

    static func providerDelete(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("provider.delete", rid: rid, ["id": .string(id)])
    }

    static func providerSetActive(provider: String, account: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("provider.setActive", rid: rid, [
            "provider": .string(provider),
            "account": .string(account),
        ])
    }

    /// `key == nil` clears the stored key (protocol `secret.set`).
    static func secretSet(account: String, key: String?, rid: String? = nil) -> ClientFrame {
        ClientFrame("secret.set", rid: rid, [
            "account": .string(account),
            "key": key.map(JSONValue.string) ?? .null,
        ])
    }

    static func defaultsSet(model: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("defaults.set", rid: rid, ["model": .string(model)])
    }

    // MARK: - Drafts, queue and notifications (v9)

    static func draftSet(id: String, text: String, client: String? = nil, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id), "text": .string(text)]
        if let client { fields["client"] = .string(client) }
        return ClientFrame("draft.set", rid: rid, fields)
    }

    /// `at == nil` queues the prompt after the current turn.
    static func queueAdd(id: String, text: String, at: String? = nil, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id), "text": .string(text)]
        if let at { fields["at"] = .string(at) }
        return ClientFrame("queue.add", rid: rid, fields)
    }

    /// `at` is an enum so "leave unchanged" and "clear to null" stay distinct.
    static func queueUpdate(
        qid: String,
        text: String? = nil,
        at: QueueTimeUpdate = .unchanged,
        rid: String? = nil
    ) -> ClientFrame {
        var fields: [String: JSONValue] = ["qid": .string(qid)]
        if let text { fields["text"] = .string(text) }
        switch at {
        case .unchanged:
            break
        case .none:
            fields["at"] = .null
        case .at(let iso):
            fields["at"] = .string(iso)
        }
        return ClientFrame("queue.update", rid: rid, fields)
    }

    static func queueRemove(qid: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("queue.remove", rid: rid, ["qid": .string(qid)])
    }

    static func queueSendNow(qid: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("queue.sendNow", rid: rid, ["qid": .string(qid)])
    }

    // MARK: - Pins and presets (v10 §13, §15.4)

    /// `ts` is the item's ISO time; omitted when the app has none.
    static func pinAdd(
        id: String,
        seq: Int,
        kind: String,
        excerpt: String,
        ts: String? = nil,
        rid: String? = nil
    ) -> ClientFrame {
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "seq": .int(seq),
            "kind": .string(kind),
            "excerpt": .string(excerpt),
        ]
        if let ts, !ts.isEmpty { fields["ts"] = .string(ts) }
        return ClientFrame("pin.add", rid: rid, fields)
    }

    static func pinRemove(id: String, pinId: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("pin.remove", rid: rid, ["id": .string(id), "pinId": .string(pinId)])
    }

    static func presetSave(
        name: String,
        agentPolicy: String?,
        subagents: [SubagentDef],
        rid: String? = nil
    ) throws -> ClientFrame {
        ClientFrame("preset.save", rid: rid, [
            "name": .string(name),
            "agentPolicy": .string(agentPolicy ?? ""),
            "subagents": try .from(subagents),
        ])
    }

    static func presetDelete(presetId: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("preset.delete", rid: rid, ["presetId": .string(presetId)])
    }

    static func modelsList(rid: String? = nil) -> ClientFrame {
        ClientFrame("models.list", rid: rid)
    }

    static func fsDirs(path: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("fs.dirs", rid: rid, ["path": .string(path)])
    }

    /// v10 §7: list one folder of a chat's tree. `id` scopes the request to
    /// that chat's folder on the hub.
    static func fsList(id: String, path: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("fs.list", rid: rid, ["id": .string(id), "path": .string(path)])
    }

    /// v10 §7: read one file (read-only). `maxBytes` caps the returned text.
    static func fsRead(id: String, path: String, maxBytes: Int? = nil, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = ["id": .string(id), "path": .string(path)]
        if let maxBytes { fields["maxBytes"] = .int(maxBytes) }
        return ClientFrame("fs.read", rid: rid, fields)
    }

    static func termOpen(cwd: String?, cols: Int, rows: Int, plain: Bool = false, rid: String? = nil) -> ClientFrame {
        var fields: [String: JSONValue] = [
            "cols": .int(cols),
            "rows": .int(rows),
        ]
        if let cwd { fields["cwd"] = .string(cwd) }
        // Only sent when true; hubs that predate `plain` keep working.
        if plain { fields["plain"] = .bool(true) }
        return ClientFrame("term.open", rid: rid, fields)
    }

    static func termAttach(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("term.attach", rid: rid, ["id": .string(id)])
    }

    static func termInput(id: String, dataBase64: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("term.input", rid: rid, ["id": .string(id), "data": .string(dataBase64)])
    }

    static func termResize(id: String, cols: Int, rows: Int, rid: String? = nil) -> ClientFrame {
        ClientFrame("term.resize", rid: rid, ["id": .string(id), "cols": .int(cols), "rows": .int(rows)])
    }

    static func termClose(id: String, rid: String? = nil) -> ClientFrame {
        ClientFrame("term.close", rid: rid, ["id": .string(id)])
    }

    static func termList(rid: String? = nil) -> ClientFrame {
        ClientFrame("term.list", rid: rid)
    }

    static func ping(rid: String? = nil) -> ClientFrame {
        ClientFrame("ping", rid: rid)
    }
}

// MARK: - Incoming frames

public struct WelcomeFrame: Codable, Sendable {
    public var hubVersion: String?
    public var accounts: [Account]
    public var active: String
    public var sessions: [SessionInfo]
    public var projects: [String]
    public var projectDefs: [ProjectDef]
    public var models: [ModelInfo]
    public var defaultModel: String
    public var terms: [TermInfo]
    /// v7: the synced custom-colour slots, when the hub sends them.
    public var appearance: AppearanceInfo?
    /// v9 §1: every non-empty unsent composer text, keyed by session id.
    public var drafts: [String: DraftWire]
    /// v9 §2: every non-empty prompt queue, in due order.
    public var queues: [String: [QueueItem]]
    /// v8 §3: the ntfy configuration (topic is a secret).
    public var notifications: NotificationSettings?
    /// v10 §15.1: optional features this hub supports. Absent means an older
    /// hub, and every optional control is disabled.
    public var features: [String]?
    /// v10 §13: every chat's non-empty pin list, keyed by session id.
    public var pins: [String: [Pin]]
    /// v10 §15.4: the user-made project presets, in the hub's stored order.
    public var presets: [ProjectPreset]

    private enum CodingKeys: String, CodingKey {
        case hubVersion, accounts, active, sessions, projects, projectDefs, models, defaultModel, terms, appearance
        case drafts, queues, notifications, features, pins, presets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubVersion = try c.decodeIfPresent(String.self, forKey: .hubVersion)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        active = try c.decodeIfPresent(String.self, forKey: .active) ?? ""
        sessions = try c.decodeIfPresent([SessionInfo].self, forKey: .sessions) ?? []
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        projectDefs = try c.decodeIfPresent([ProjectDef].self, forKey: .projectDefs) ?? []
        models = try c.decodeIfPresent([ModelInfo].self, forKey: .models) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        terms = try c.decodeIfPresent([TermInfo].self, forKey: .terms) ?? []
        appearance = try c.decodeIfPresent(AppearanceInfo.self, forKey: .appearance)
        drafts = try c.decodeIfPresent([String: DraftWire].self, forKey: .drafts) ?? [:]
        queues = try c.decodeIfPresent([String: [QueueItem]].self, forKey: .queues) ?? [:]
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications)
        features = try c.decodeIfPresent([String].self, forKey: .features)
        pins = try c.decodeIfPresent([String: [Pin]].self, forKey: .pins) ?? [:]
        presets = try c.decodeIfPresent([ProjectPreset].self, forKey: .presets) ?? []
    }
}

public struct SessionsFrame: Codable, Sendable {
    public var rid: String?
    public var sessions: [SessionInfo]
    public var projects: [String]
    public var projectDefs: [ProjectDef]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        sessions = try c.decodeIfPresent([SessionInfo].self, forKey: .sessions) ?? []
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        projectDefs = try c.decodeIfPresent([ProjectDef].self, forKey: .projectDefs) ?? []
    }

    private enum CodingKeys: String, CodingKey { case rid, sessions, projects, projectDefs }
}

public struct HistoryFrame: Codable, Sendable {
    public var id: String
    public var items: [HistoryItem]
    public var lastSeq: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        items = try c.decodeIfPresent([HistoryItem].self, forKey: .items) ?? []
        lastSeq = try c.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case id, items, lastSeq }
}

public struct EventFrame: Decodable, Sendable {
    public var event: HubEvent

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try c.decodeIfPresent(HubEvent.self, forKey: .event) {
            event = nested
        } else {
            // protocol.md §3 documents the fields directly on the frame.
            event = try HubEvent(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case event }
}

public struct SessionUpdatedFrame: Codable, Sendable {
    public var session: SessionInfo
}

public struct PermissionRequestFrame: Decodable, Sendable {
    public var id: String
    public var reqId: String
    public var tool: String
    public var input: JSONValue
    public var title: String?
    public var description: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        reqId = try c.decode(String.self, forKey: .reqId)
        tool = try c.decode(String.self, forKey: .tool)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey { case id, reqId, tool, input, title, description }
}

public struct PermissionResolvedFrame: Codable, Sendable {
    public var id: String
    public var reqId: String
}

public struct AccountsFrame: Codable, Sendable {
    public var accounts: [Account]
    public var active: String
}

public struct ModelsFrame: Codable, Sendable {
    public var rid: String?
    public var models: [ModelInfo]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        models = try c.decodeIfPresent([ModelInfo].self, forKey: .models) ?? []
    }

    private enum CodingKeys: String, CodingKey { case rid, models }
}

public struct ProjectsFrame: Codable, Sendable {
    public var projectDefs: [ProjectDef]
    public var projects: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectDefs = try c.decodeIfPresent([ProjectDef].self, forKey: .projectDefs) ?? []
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
    }

    private enum CodingKeys: String, CodingKey { case projectDefs, projects }
}

public struct SessionRemovedFrame: Codable, Sendable {
    public var id: String
}

/// v10 §13: `{t:"pins", id, pins}` after a pin change (or chat deletion).
public struct PinsFrame: Codable, Sendable {
    public var id: String
    public var pins: [Pin]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, pins }
}

/// v10 §15.4: `{t:"presets", presets}` after a save or delete.
public struct PresetsFrame: Codable, Sendable {
    public var presets: [ProjectPreset]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presets = try c.decodeIfPresent([ProjectPreset].self, forKey: .presets) ?? []
    }

    private enum CodingKeys: String, CodingKey { case presets }
}

public struct AgentsFrame: Codable, Sendable {
    public var rid: String?
    public var agents: [AgentType]
}

public struct TermsFrame: Codable, Sendable {
    public var rid: String?
    public var terms: [TermInfo]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        terms = try c.decodeIfPresent([TermInfo].self, forKey: .terms) ?? []
    }

    private enum CodingKeys: String, CodingKey { case rid, terms }
}

public struct TermOpenedFrame: Codable, Sendable {
    public var rid: String?
    public var term: TermInfo
}

public struct TermOutputFrame: Codable, Sendable {
    public var id: String
    public var data: String
    public var replay: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        data = try c.decodeIfPresent(String.self, forKey: .data) ?? ""
        replay = try c.decodeIfPresent(Bool.self, forKey: .replay)
    }

    private enum CodingKeys: String, CodingKey { case id, data, replay }
}

public struct TermExitFrame: Codable, Sendable {
    public var id: String
    public var code: Int
}

public struct DirsFrame: Codable, Sendable {
    public var rid: String?
    public var path: String
    public var dirs: [String]
}

// MARK: - Files (v10 §7)

/// One `fs.listing` entry. Directories come first in the hub's answer.
public struct FsEntry: Codable, Hashable, Sendable {
    public var name: String
    public var dir: Bool
    public var size: Int
    public var mtime: String
    /// Hidden names still appear, flagged (docs/design v10 §7).
    public var hidden: Bool

    public init(name: String, dir: Bool, size: Int = 0, mtime: String = "", hidden: Bool = false) {
        self.name = name
        self.dir = dir
        self.size = size
        self.mtime = mtime
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case name, dir, size, mtime, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        dir = try c.decodeIfPresent(Bool.self, forKey: .dir) ?? false
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(String.self, forKey: .mtime) ?? ""
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

public struct FsListingFrame: Codable, Hashable, Sendable {
    public var rid: String?
    /// The resolved real path the hub answered for.
    public var path: String
    public var entries: [FsEntry]
    /// True for `.git` / `node_modules`: the row exists, its contents do not.
    public var skipped: Bool

    public init(rid: String? = nil, path: String, entries: [FsEntry], skipped: Bool = false) {
        self.rid = rid
        self.path = path
        self.entries = entries
        self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey { case rid, path, entries, skipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        entries = try c.decodeIfPresent([FsEntry].self, forKey: .entries) ?? []
        skipped = try c.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }
}

/// `fs.file` payload. `image` is base64 without a `data:` prefix.
public struct FsFileFrame: Codable, Hashable, Sendable {
    public var rid: String?
    public var path: String
    public var size: Int
    public var mtime: String
    public var binary: Bool
    public var truncated: Bool
    public var text: String?
    public var image: String?

    public init(
        rid: String? = nil,
        path: String,
        size: Int = 0,
        mtime: String = "",
        binary: Bool = false,
        truncated: Bool = false,
        text: String? = nil,
        image: String? = nil
    ) {
        self.rid = rid
        self.path = path
        self.size = size
        self.mtime = mtime
        self.binary = binary
        self.truncated = truncated
        self.text = text
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case rid, path, size, mtime, binary, truncated, text, image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(String.self, forKey: .mtime) ?? ""
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        image = try c.decodeIfPresent(String.self, forKey: .image)
    }
}

public struct LoginFrame: Codable, Sendable {
    public var name: String
    public var url: String?
    public var status: String
    public var message: String?
}

public struct OkFrame: Codable, Sendable {
    public var rid: String?
    public var id: String?
    /// v9 §2: the new item's id, for `queue.add`.
    public var qid: String?
    /// v10 §13: the new pin's id, for `pin.add`.
    public var pinId: String?
    /// v10 §15.4: the saved preset's id, for `preset.save`.
    public var presetId: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(String.self, forKey: .rid)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        qid = try c.decodeIfPresent(String.self, forKey: .qid)
        pinId = try c.decodeIfPresent(String.self, forKey: .pinId)
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId)
    }

    private enum CodingKeys: String, CodingKey { case rid, id, qid, pinId, presetId }
}

public struct ErrFrame: Codable, Sendable {
    public var rid: String?
    public var code: String
    public var message: String?
}

public struct PongFrame: Codable, Sendable {
    public var rid: String?
}

/// Decoded hub -> app frame. Unknown types are preserved instead of failing
/// the connection, which keeps the client forward-compatible as the protocol
/// grows (v6, v7, ...).
public enum ServerMessage: Sendable {
    case welcome(WelcomeFrame)
    case sessions(SessionsFrame)
    case history(HistoryFrame)
    case event(EventFrame)
    case sessionUpdated(SessionUpdatedFrame)
    case sessionRemoved(SessionRemovedFrame)
    case permissionRequest(PermissionRequestFrame)
    case permissionResolved(PermissionResolvedFrame)
    case accounts(AccountsFrame)
    case appearance(AppearanceFrame)
    case draft(DraftFrame)
    case queue(QueueFrame)
    case notifications(NotificationsFrame)
    case pins(PinsFrame)
    case presets(PresetsFrame)
    case models(ModelsFrame)
    case projects(ProjectsFrame)
    case agents(AgentsFrame)
    case terms(TermsFrame)
    case termOpened(TermOpenedFrame)
    case termOutput(TermOutputFrame)
    case termExit(TermExitFrame)
    case dirs(DirsFrame)
    case fsListing(FsListingFrame)
    case fsFile(FsFileFrame)
    case login(LoginFrame)
    case ok(OkFrame)
    case err(ErrFrame)
    case pong(PongFrame)
    case unknown(t: String, raw: JSONValue)

    public var type: String {
        switch self {
        case .welcome: return "welcome"
        case .sessions: return "sessions"
        case .history: return "history"
        case .event: return "event"
        case .sessionUpdated: return "session.updated"
        case .sessionRemoved: return "session.removed"
        case .permissionRequest: return "permission.request"
        case .permissionResolved: return "permission.resolved"
        case .accounts: return "accounts"
        case .appearance: return "appearance"
        case .draft: return "draft"
        case .queue: return "queue"
        case .notifications: return "notifications"
        case .pins: return "pins"
        case .presets: return "presets"
        case .models: return "models"
        case .projects: return "projects"
        case .agents: return "agents"
        case .terms: return "terms"
        case .termOpened: return "term.opened"
        case .termOutput: return "term.output"
        case .termExit: return "term.exit"
        case .dirs: return "dirs"
        case .fsListing: return "fs.listing"
        case .fsFile: return "fs.file"
        case .login: return "login"
        case .ok: return "ok"
        case .err: return "err"
        case .pong: return "pong"
        case .unknown(let t, _): return t
        }
    }

    public static func decode(_ data: Data) throws -> ServerMessage {
        guard let object = try? JSONDecoder.proteus.decode(JSONValue.self, from: data),
              case .object(let dict) = object,
              case .string(let t)? = dict["t"] else {
            throw FrameError.invalidFrame
        }

        let decoder = JSONDecoder.proteus
        switch t {
        case "welcome": return .welcome(try decoder.decode(WelcomeFrame.self, from: data))
        case "sessions": return .sessions(try decoder.decode(SessionsFrame.self, from: data))
        case "history": return .history(try decoder.decode(HistoryFrame.self, from: data))
        case "event": return .event(try decoder.decode(EventFrame.self, from: data))
        case "session.updated": return .sessionUpdated(try decoder.decode(SessionUpdatedFrame.self, from: data))
        case "session.removed": return .sessionRemoved(try decoder.decode(SessionRemovedFrame.self, from: data))
        case "permission.request": return .permissionRequest(try decoder.decode(PermissionRequestFrame.self, from: data))
        case "permission.resolved": return .permissionResolved(try decoder.decode(PermissionResolvedFrame.self, from: data))
        case "accounts": return .accounts(try decoder.decode(AccountsFrame.self, from: data))
        case "appearance": return .appearance(try decoder.decode(AppearanceFrame.self, from: data))
        case "draft": return .draft(try decoder.decode(DraftFrame.self, from: data))
        case "queue": return .queue(try decoder.decode(QueueFrame.self, from: data))
        case "notifications": return .notifications(try decoder.decode(NotificationsFrame.self, from: data))
        case "pins": return .pins(try decoder.decode(PinsFrame.self, from: data))
        case "presets": return .presets(try decoder.decode(PresetsFrame.self, from: data))
        case "models": return .models(try decoder.decode(ModelsFrame.self, from: data))
        case "projects": return .projects(try decoder.decode(ProjectsFrame.self, from: data))
        case "agents": return .agents(try decoder.decode(AgentsFrame.self, from: data))
        case "terms": return .terms(try decoder.decode(TermsFrame.self, from: data))
        case "term.opened": return .termOpened(try decoder.decode(TermOpenedFrame.self, from: data))
        case "term.output": return .termOutput(try decoder.decode(TermOutputFrame.self, from: data))
        case "term.exit": return .termExit(try decoder.decode(TermExitFrame.self, from: data))
        case "dirs": return .dirs(try decoder.decode(DirsFrame.self, from: data))
        case "fs.listing": return .fsListing(try decoder.decode(FsListingFrame.self, from: data))
        case "fs.file": return .fsFile(try decoder.decode(FsFileFrame.self, from: data))
        case "login": return .login(try decoder.decode(LoginFrame.self, from: data))
        case "ok": return .ok(try decoder.decode(OkFrame.self, from: data))
        case "err": return .err(try decoder.decode(ErrFrame.self, from: data))
        case "pong": return .pong(try decoder.decode(PongFrame.self, from: data))
        default:
            return .unknown(t: t, raw: object)
        }
    }
}

public enum FrameError: Error, Equatable {
    case invalidFrame
    case notConnected
    case closed
    case authFailed
    case hub(String)
}

extension FrameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The hub sent a frame that is not valid JSON."
        case .notConnected: return "Not connected to a workstation."
        case .closed: return "The connection closed."
        case .authFailed: return "The workstation token was rejected."
        case .hub(let message): return message
        }
    }
}
