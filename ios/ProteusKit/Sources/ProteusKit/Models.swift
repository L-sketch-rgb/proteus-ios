import Foundation

// MARK: - Sessions

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waiting
    case error
    case stopped
}

public struct SessionInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String
    public var project: String
    public var model: String
    public var account: String
    public var status: String
    public var mode: String
    public var updatedAt: String
    public var live: Bool
    public var agentsRunning: Int
    /// v9 §2: prompts waiting in this chat's queue, for the "⏱ n" chip.
    public var queued: Int
    /// v9 §2: slash commands the Claude engine advertised in its last init.
    public var commands: [String]

    public var statusKind: SessionStatus { SessionStatus(rawValue: status) ?? .idle }

    public init(
        id: String,
        title: String,
        cwd: String,
        project: String = "",
        model: String,
        account: String = "",
        status: String = "idle",
        mode: String = "default",
        updatedAt: String = "",
        live: Bool = false,
        agentsRunning: Int = 0,
        queued: Int = 0,
        commands: [String] = []
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.project = project
        self.model = model
        self.account = account
        self.status = status
        self.mode = mode
        self.updatedAt = updatedAt
        self.live = live
        self.agentsRunning = agentsRunning
        self.queued = queued
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, project, model, account, status, mode, updatedAt, live, agentsRunning
        case queued, commands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "default"
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        agentsRunning = try c.decodeIfPresent(Int.self, forKey: .agentsRunning) ?? 0
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
    }
}

// MARK: - Accounts and usage

public struct UsageWindow: Codable, Hashable, Sendable {
    /// Fraction 0...1. The hub already normalises percentages.
    public var utilization: Double
    public var resetsAt: String?

    public init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct AccountUsage: Codable, Hashable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var status: String?
    public var updatedAt: String?

    public init(
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        status: String? = nil,
        updatedAt: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var label: String
    public var email: String?
    public var provider: String?
    public var kind: String?
    public var loggedIn: Bool
    public var keyHint: String?
    public var usage: AccountUsage?

    public var id: String { name }

    public init(
        name: String,
        label: String,
        email: String? = nil,
        provider: String? = nil,
        kind: String? = nil,
        loggedIn: Bool = false,
        keyHint: String? = nil,
        usage: AccountUsage? = nil
    ) {
        self.name = name
        self.label = label
        self.email = email
        self.provider = provider
        self.kind = kind
        self.loggedIn = loggedIn
        self.keyHint = keyHint
        self.usage = usage
    }

    public var isSubscription: Bool { kind == "claude-subscription" }
}

// MARK: - Projects and agents

public struct SubagentDef: Codable, Hashable, Sendable {
    public var name: String
    public var when: String
    public var model: String
    public var tools: String
    public var prompt: String?

    public init(name: String, when: String, model: String = "inherit", tools: String = "all", prompt: String? = nil) {
        self.name = name
        self.when = when
        self.model = model
        self.tools = tools
        self.prompt = prompt
    }
}

public struct ProjectDef: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var cwd: String?
    public var defaultModel: String?
    public var instructions: String?
    public var agentPolicy: String?
    public var subagents: [SubagentDef]

    public var id: String { name }

    public init(
        name: String,
        cwd: String? = nil,
        defaultModel: String? = nil,
        instructions: String? = nil,
        agentPolicy: String? = nil,
        subagents: [SubagentDef] = []
    ) {
        self.name = name
        self.cwd = cwd
        self.defaultModel = defaultModel
        self.instructions = instructions
        self.agentPolicy = agentPolicy
        self.subagents = subagents
    }

    private enum CodingKeys: String, CodingKey {
        case name, cwd, defaultModel, instructions, agentPolicy, subagents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
        agentPolicy = try c.decodeIfPresent(String.self, forKey: .agentPolicy)
        subagents = try c.decodeIfPresent([SubagentDef].self, forKey: .subagents) ?? []
    }
}

/// v10 §15.4: a user-made project preset, stored on the hub and synced to
/// every device. Nothing is seeded from code.
public struct ProjectPreset: Codable, Hashable, Identifiable, Sendable {
    public var presetId: String
    public var name: String
    public var agentPolicy: String?
    public var subagents: [SubagentDef]

    public var id: String { presetId }

    public init(
        presetId: String,
        name: String,
        agentPolicy: String? = nil,
        subagents: [SubagentDef] = []
    ) {
        self.presetId = presetId
        self.name = name
        self.agentPolicy = agentPolicy
        self.subagents = subagents
    }

    private enum CodingKeys: String, CodingKey { case presetId, name, agentPolicy, subagents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        agentPolicy = try c.decodeIfPresent(String.self, forKey: .agentPolicy)
        subagents = try c.decodeIfPresent([SubagentDef].self, forKey: .subagents) ?? []
    }
}

public struct AgentType: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var description: String
    public var model: String?
    public var source: String

    public var id: String { name }

    public init(name: String, description: String, model: String? = nil, source: String = "user") {
        self.name = name
        self.description = description
        self.model = model
        self.source = source
    }
}

// MARK: - Providers and models

public struct ProviderModelConfig: Codable, Hashable, Sendable {
    public var key: String
    public var engineModel: String
    public var label: String
    public var tier: String?

    public init(key: String, engineModel: String, label: String, tier: String? = nil) {
        self.key = key
        self.engineModel = engineModel
        self.label = label
        self.tier = tier
    }
}

public struct ProviderConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var baseUrl: String?
    public var sanitize: String?
    public var models: [ProviderModelConfig]?
    public var active: String?

    public init(
        id: String,
        kind: String,
        label: String,
        baseUrl: String? = nil,
        sanitize: String? = nil,
        models: [ProviderModelConfig]? = nil,
        active: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.baseUrl = baseUrl
        self.sanitize = sanitize
        self.models = models
        self.active = active
    }
}

public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public var provider: String
    public var engine: String
    public var engineModel: String
    public var resolvedModel: String?
    public var tier: String?
    public var available: Bool
    public var unavailableReason: String?
    public var pinned: Bool?

    public init(
        id: String,
        label: String,
        description: String? = nil,
        provider: String,
        engine: String = "claude-code",
        engineModel: String,
        resolvedModel: String? = nil,
        tier: String? = nil,
        available: Bool = true,
        unavailableReason: String? = nil,
        pinned: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.provider = provider
        self.engine = engine
        self.engineModel = engineModel
        self.resolvedModel = resolvedModel
        self.tier = tier
        self.available = available
        self.unavailableReason = unavailableReason
        self.pinned = pinned
    }

    /// Greyed-out rows in a model menu.
    public var isSelectable: Bool { available }
}

// MARK: - Terminals

public struct TermInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String
    public var pid: Int
    public var createdAt: String
    public var alive: Bool

    public init(id: String, title: String, cwd: String, pid: Int = 0, createdAt: String = "", alive: Bool = true) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.pid = pid
        self.createdAt = createdAt
        self.alive = alive
    }
}

// MARK: - Events

public struct HubEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var seq: Int
    public var ts: String
    public var kind: String
    public var data: JSONValue

    public init(id: String, seq: Int, ts: String, kind: String, data: JSONValue) {
        self.id = id
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.data = data
    }
}

/// v10 §13: one pinned transcript item, stored on the hub and synced.
/// `ts` is `""` when the item has no time; `seq` is 0 for history-derived
/// items, which are matched by kind plus excerpt.
public struct Pin: Codable, Hashable, Identifiable, Sendable {
    public var pinId: String
    public var seq: Int
    public var kind: String
    public var excerpt: String
    public var ts: String
    public var pinnedAt: String

    public var id: String { pinId }

    public init(
        pinId: String,
        seq: Int = 0,
        kind: String,
        excerpt: String,
        ts: String = "",
        pinnedAt: String = ""
    ) {
        self.pinId = pinId
        self.seq = seq
        self.kind = kind
        self.excerpt = excerpt
        self.ts = ts
        self.pinnedAt = pinnedAt
    }

    private enum CodingKeys: String, CodingKey {
        case pinId, seq, kind, excerpt, ts, pinnedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinId = try c.decodeIfPresent(String.self, forKey: .pinId) ?? ""
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        pinnedAt = try c.decodeIfPresent(String.self, forKey: .pinnedAt) ?? ""
    }
}

/// History items are events without id/seq.
public struct HistoryItem: Codable, Hashable, Sendable {
    public var ts: String
    public var kind: String
    public var data: JSONValue

    public init(ts: String = "", kind: String, data: JSONValue) {
        self.ts = ts
        self.kind = kind
        self.data = data
    }
}

/// One block of a final assistant message.
public struct Block: Codable, Hashable, Sendable {
    public var type: String
    public var text: String?
    public var id: String?
    public var name: String?
    public var input: JSONValue?

    public init(type: String, text: String? = nil, id: String? = nil, name: String? = nil, input: JSONValue? = nil) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ImageIn: Codable, Hashable, Sendable {
    public var mediaType: String
    public var data: String

    public init(mediaType: String, data: String) {
        self.mediaType = mediaType
        self.data = data
    }
}

// MARK: - Sub-agent tasks (v6)

public enum TaskStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case stopped
}

public struct TaskData: Codable, Hashable, Identifiable, Sendable {
    public var taskId: String
    public var toolUseId: String?
    public var parentTaskId: String?
    public var agent: String
    public var description: String
    public var model: String?
    public var status: String
    public var startedAt: String
    public var endedAt: String?
    /// Unknown values from transcript-derived history stay nil; never synth 0.
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?
    public var lastTool: String?
    public var summary: String?

    public var id: String { taskId }
    public var statusKind: TaskStatus { TaskStatus(rawValue: status) ?? .running }
    public var isRunning: Bool { statusKind == .running }

    public init(
        taskId: String,
        toolUseId: String? = nil,
        parentTaskId: String? = nil,
        agent: String,
        description: String,
        model: String? = nil,
        status: String,
        startedAt: String,
        endedAt: String? = nil,
        tokens: Int? = nil,
        toolUses: Int? = nil,
        durationMs: Int? = nil,
        lastTool: String? = nil,
        summary: String? = nil
    ) {
        self.taskId = taskId
        self.toolUseId = toolUseId
        self.parentTaskId = parentTaskId
        self.agent = agent
        self.description = description
        self.model = model
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = tokens
        self.toolUses = toolUses
        self.durationMs = durationMs
        self.lastTool = lastTool
        self.summary = summary
    }
}

// MARK: - Permissions and login

public struct PermissionRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var reqId: String
    public var tool: String
    public var input: JSONValue
    public var title: String?
    public var description: String?

    public var identity: String { "\(id)/\(reqId)" }

    public init(id: String, reqId: String, tool: String, input: JSONValue = .object([:]), title: String? = nil, description: String? = nil) {
        self.id = id
        self.reqId = reqId
        self.tool = tool
        self.input = input
        self.title = title
        self.description = description
    }
}

public struct LoginUpdate: Codable, Hashable, Sendable {
    public var name: String
    public var url: String?
    public var status: String
    public var message: String?

    public init(name: String, url: String? = nil, status: String, message: String? = nil) {
        self.name = name
        self.url = url
        self.status = status
        self.message = message
    }
}

// MARK: - Event payloads

public struct ToolResultData: Codable, Hashable, Sendable {
    public var toolUseId: String
    public var isError: Bool
    public var text: String

    public init(toolUseId: String, isError: Bool = false, text: String = "") {
        self.toolUseId = toolUseId
        self.isError = isError
        self.text = text
    }
}

public struct ResultData: Codable, Hashable, Sendable {
    public var ok: Bool
    public var costUsd: Double?
    public var durationMs: Int
    public var error: String?
    public var apiStatus: Int?

    public init(ok: Bool, costUsd: Double? = nil, durationMs: Int = 0, error: String? = nil, apiStatus: Int? = nil) {
        self.ok = ok
        self.costUsd = costUsd
        self.durationMs = durationMs
        self.error = error
        self.apiStatus = apiStatus
    }
}

public struct ErrorData: Codable, Hashable, Sendable {
    public var message: String
    public var code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}
