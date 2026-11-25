import Foundation

public enum ChatRowKind: String, Equatable, Sendable {
    case user
    case assistant
    case thinking
    case tool
    /// v10 §2: one collapsed row for a run of 2+ tool cards.
    case toolgroup
    case error
    case notice
}

/// One row in a chat transcript. Streaming deltas mutate `text` in place; the
/// identity stays stable so SwiftUI keeps the row.
public struct ChatRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: ChatRowKind
    public var text: String
    public var streaming: Bool
    /// Events from a subagent carry `data.parent`; the UI indents those.
    public var nested: Bool
    /// Number of attached images on a user message (`event.data.images`).
    public var images: Int

    // Tool card
    public var toolId: String?
    public var toolName: String?
    public var toolSummary: String?
    /// Compact JSON of `tool_use.input`, shown when the card is expanded.
    public var toolInput: String?
    public var toolResult: String?
    public var toolError: Bool
    public var toolDone: Bool

    /// v6 live task state, matched by `toolUseId`.
    public var task: TaskData?

    // v10 §3: timestamp display form, plus the raw value for spans.
    public var tsRaw: String
    public var timestamp: String

    // v10 §2: a grouped tool card carries its header's group id and state.
    // The header itself has kind .toolgroup.
    public var groupId: String
    public var groupExpanded: Bool
    public var groupCount: Int
    public var groupLabel: String
    public var groupSummary: String
    public var groupSpan: String
    public var groupRunning: Bool
    public var groupFailed: Int
    public var groupLatest: String

    // v10 §11: a user message that was edited and re-sent.
    public var edited: Bool

    // v10 §8: structured background notice (task / reminder / agent / stopped).
    public var noticeKind: String?
    public var noticeFrom: String?
    public var noticeReport: String?

    // v10 §13: the event seq this row came from (0 for history items), so a
    // pin can scroll back to it.
    public var eventSeq: Int
    // v10 §16: the call was cut off by Stop; draw grey "stopped", not an error.
    public var toolStopped: Bool
    // v10 §16: every call in this group was stopped.
    public var groupStopped: Bool

    public init(
        id: String,
        kind: ChatRowKind,
        text: String = "",
        streaming: Bool = false,
        nested: Bool = false,
        images: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.streaming = streaming
        self.nested = nested
        self.images = images
        self.toolId = nil
        self.toolName = nil
        self.toolSummary = nil
        self.toolInput = nil
        self.toolResult = nil
        self.toolError = false
        self.toolDone = false
        self.task = nil
        self.tsRaw = ""
        self.timestamp = ""
        self.groupId = ""
        self.groupExpanded = false
        self.groupCount = 0
        self.groupLabel = ""
        self.groupSummary = ""
        self.groupSpan = ""
        self.groupRunning = false
        self.groupFailed = 0
        self.groupLatest = ""
        self.edited = false
        self.noticeKind = nil
        self.noticeFrom = nil
        self.noticeReport = nil
        self.eventSeq = 0
        self.toolStopped = false
        self.groupStopped = false
    }
}

public extension ChatRow {
    /// v10 §13: the pin kind for this row, nil when it cannot be pinned.
    var pinKind: String? {
        switch kind {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .toolgroup: return "group"
        default: return nil
        }
    }

    /// The text a pin excerpt is built from and matched against.
    var pinText: String {
        switch kind {
        case .tool:
            if let summary = toolSummary, !summary.isEmpty { return summary }
            return toolName ?? ""
        case .toolgroup:
            return groupSummary.isEmpty ? groupLabel : groupSummary
        default:
            return text
        }
    }
}

/// Folds hub events into chat rows. The rules are a direct port of
/// linux/src/chatmodel.cpp (user, deltas, assistant blocks, tool results,
/// result/error/notice, plus v6 task events). `status` and unknown kinds are
/// not chat rows.
///
/// v10 §2 stores the canonical, ungrouped rows in `entries` and publishes a
/// display list in `rows`: a run of 2+ consecutive tool cards becomes a
/// collapsed `toolgroup` header followed by the cards themselves (the UI hides
/// the children while the group is collapsed).
public final class ChatStore {
    /// The display rows: tool groups have a header, children follow it.
    public private(set) var rows: [ChatRow] = []
    /// Canonical rows without group headers, for counts and tool matching.
    private var entries: [ChatRow] = []
    public private(set) var lastSeq: Int = 0
    public private(set) var sessionId: String?
    /// Latest full task state per task id, from `task` events.
    public private(set) var tasks: [String: TaskData] = [:]

    public var onChange: (() -> Void)?
    /// Forwarded for a per-chat TaskStore / Agents sheet.
    public var onTask: ((TaskData) -> Void)?

    private var rowCounter = 0
    private var tasksByToolUseId: [String: TaskData] = [:]
    /// v10 §2: expanded state is per group, in memory; new groups start closed.
    private var expandedGroups: Set<String> = []
    /// v10 §3: parents whose current assistant turn already showed its time.
    private var assistantTurnStarted: Set<String> = []

    public init() {}

    public func reset(sessionId: String? = nil) {
        self.sessionId = sessionId
        rows = []
        entries = []
        tasks = [:]
        tasksByToolUseId = [:]
        expandedGroups = []
        assistantTurnStarted = []
        lastSeq = 0
        rowCounter = 0
        onChange?()
    }

    public var runningTaskCount: Int {
        tasks.values.filter(\.isRunning).count
    }

    /// Number of canonical rows (group children counted once).
    public var entryCount: Int { entries.count }

    /// Rows the transcript draws: collapsed group children are omitted.
    public var visibleRows: [ChatRow] {
        rows.filter { row in
            !(row.kind == .tool && !row.groupId.isEmpty && !row.groupExpanded)
        }
    }

    /// Build from `history` items (which carry no seq), then continue from
    /// `lastSeq` with live events.
    public func applyHistory(_ items: [HistoryItem], lastSeq: Int) {
        reset(sessionId: sessionId)
        for item in items {
            let parent = item.data["parent"]?.stringValue ?? ""
            // History items carry no seq; pins match them by kind + excerpt.
            applyItem(kind: item.kind, data: item.data, live: false, parent: parent, ts: item.ts, seq: 0)
        }
        self.lastSeq = max(0, lastSeq)
        rebuildRows()
        onChange?()
    }

    /// Apply one live event. Any event whose seq is not greater than the last
    /// held seq is ignored (protocol.md §4: replay may repeat events).
    public func apply(_ event: HubEvent) {
        guard event.seq > lastSeq else { return }
        lastSeq = event.seq
        if sessionId == nil { sessionId = event.id }
        let parent = event.data["parent"]?.stringValue ?? ""
        applyItem(kind: event.kind, data: event.data, live: true, parent: parent, ts: event.ts, seq: event.seq)
        rebuildRows()
        onChange?()
    }

    public func toolRow(withId toolId: String) -> ChatRow? {
        entries.last { $0.toolId == toolId }
    }

    public func task(forToolUse toolUseId: String) -> TaskData? {
        tasksByToolUseId[toolUseId]
    }

    /// v10 §13: the row a pin points at. Live rows match by event seq (a
    /// group by its first tool's seq); history rows, and pins whose item has
    /// since been rebuilt, match by kind plus excerpt. Nil when it is gone.
    public func row(matching pin: Pin) -> ChatRow? {
        let wanted = Self.rowKind(forPinKind: pin.kind)
        guard let wanted else { return nil }
        if pin.seq > 0 {
            let sameSeq = rows.filter { $0.kind == wanted && $0.eventSeq == pin.seq }
            if let exact = sameSeq.first(where: { Self.excerpt(pin.excerpt, matches: $0) }) {
                return exact
            }
            if let first = sameSeq.first { return first }
        }
        return rows.first { $0.kind == wanted && Self.excerpt(pin.excerpt, matches: $0) }
    }

    private static func rowKind(forPinKind kind: String) -> ChatRowKind? {
        switch kind {
        case "user": return .user
        case "assistant": return .assistant
        case "tool": return .tool
        case "group": return .toolgroup
        default: return nil
        }
    }

    private static func excerpt(_ excerpt: String, matches row: ChatRow) -> Bool {
        // The hub cuts excerpts to 160 characters with a trailing ellipsis;
        // strip it so a history row (no seq) can still match its pin.
        func trimmed(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("…") { text.removeLast() }
            return text
        }
        let wanted = trimmed(excerpt)
        let text = trimmed(row.pinText)
        guard !wanted.isEmpty, !text.isEmpty else { return false }
        return text.hasPrefix(wanted) || wanted.hasPrefix(text)
    }

    // MARK: - v10 §2 groups

    public func toggleGroup(_ groupId: String) {
        guard !groupId.isEmpty else { return }
        if expandedGroups.contains(groupId) {
            expandedGroups.remove(groupId)
        } else {
            expandedGroups.insert(groupId)
        }
        rebuildRows()
        onChange?()
    }

    public func expandGroup(_ groupId: String) {
        guard !groupId.isEmpty, !expandedGroups.contains(groupId) else { return }
        expandedGroups.insert(groupId)
        rebuildRows()
        onChange?()
    }

    /// v10 §11: mark a user row as edited (the original stays in place).
    public func markEdited(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.kind == .user }) else { return }
        guard !entries[index].edited else { return }
        entries[index].edited = true
        rebuildRows()
        onChange?()
    }

    private static func isGroupable(_ row: ChatRow) -> Bool {
        row.kind == .tool && !row.nested
            && row.toolName != "Task" && row.toolName != "Agent"
    }

    private func rebuildRows() {
        var out: [ChatRow] = []
        var index = 0
        while index < entries.count {
            guard Self.isGroupable(entries[index]) else {
                out.append(entries[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < entries.count && Self.isGroupable(entries[end]) {
                end += 1
            }
            if end - index >= 2 {
                let children = Array(entries[index..<end])
                out.append(makeGroup(children: children))
                let groupId = out[out.count - 1].groupId
                let expanded = out[out.count - 1].groupExpanded
                for var child in children {
                    child.groupId = groupId
                    child.groupExpanded = expanded
                    out.append(child)
                }
            } else {
                out.append(entries[index])
            }
            index = end
        }
        rows = out
    }

    private func makeGroup(children: [ChatRow]) -> ChatRow {
        // The first child with a tool id names the group (Linux parity).
        let groupId = children.first(where: { $0.toolId?.isEmpty == false })?.toolId
            ?? "group-\(children[0].id)"
        let expanded = expandedGroups.contains(groupId)

        var names: [String] = []
        var counts: [Int] = []
        for child in children {
            let name = child.toolName?.isEmpty == false ? child.toolName! : "Tool"
            if let at = names.firstIndex(of: name) {
                counts[at] += 1
            } else {
                names.append(name)
                counts.append(1)
            }
        }
        let summary = zip(names, counts).map { "\($0.0) ×\($0.1)" }.joined(separator: " · ")
        let allBash = children.allSatisfy { $0.toolName == "Bash" }
        let failed = children.filter(\.toolError).count
        let latest = children.last.map {
            ($0.toolSummary?.isEmpty == false ? $0.toolSummary! : $0.toolName) ?? ""
        } ?? ""

        var header = ChatRow(id: "groupheader-\(groupId)", kind: .toolgroup)
        header.groupId = groupId
        header.groupExpanded = expanded
        header.groupCount = children.count
        header.groupLabel = allBash ? "commands" : "tool calls"
        header.groupSummary = summary
        header.groupSpan = Formatting.timeRange(children[0].tsRaw, children[children.count - 1].tsRaw)
        header.groupRunning = children.contains { !$0.toolDone && !$0.toolStopped }
        header.groupStopped = children.contains { $0.toolStopped } && !header.groupRunning
        header.groupFailed = children.filter { $0.toolError && !$0.toolStopped }.count
        header.groupLatest = latest
        header.tsRaw = children[0].tsRaw
        header.timestamp = children[0].timestamp
        // v10 §13: a group's pin seq is its first tool's event seq.
        header.eventSeq = children[0].eventSeq
        return header
    }

    // MARK: - Folding

    private func nextId() -> String {
        rowCounter += 1
        return "row-\(rowCounter)"
    }

    private func appendEntry(_ row: ChatRow) {
        entries.append(row)
    }

    private func applyItem(kind: String, data: JSONValue, live: Bool, parent: String, ts: String, seq: Int) {
        let nested = !parent.isEmpty
        let timestamp = Formatting.timestamp(ts)

        switch kind {
        case "text_delta", "thinking_delta":
            let assistant = kind == "text_delta"
            let expected: ChatRowKind = assistant ? .assistant : .thinking
            if let last = entries.last, last.streaming, last.kind == expected {
                entries[entries.count - 1].text += data["text"]?.stringValue ?? ""
            } else {
                var row = ChatRow(id: nextId(), kind: expected, streaming: true, nested: nested)
                row.text = data["text"]?.stringValue ?? ""
                row.tsRaw = ts
                row.eventSeq = seq
                // v10 §3: only the turn's first assistant text row shows a time.
                if assistant && !assistantTurnStarted.contains(parent) {
                    assistantTurnStarted.insert(parent)
                    row.timestamp = timestamp
                }
                appendEntry(row)
            }

        case "user":
            clearStreamingFlags()
            // A user message starts a new assistant turn for its parent.
            assistantTurnStarted.remove(parent)
            var row = ChatRow(id: nextId(), kind: .user, nested: nested)
            row.text = data["text"]?.stringValue ?? ""
            row.images = data["images"]?.intValue ?? 0
            row.tsRaw = ts
            row.timestamp = timestamp
            row.eventSeq = seq
            appendEntry(row)

        case "assistant":
            // The final message replaces the deltas shown so far.
            var carriedTimestamp = ""
            for row in entries.reversed() where row.streaming {
                if row.kind == .assistant && !row.timestamp.isEmpty {
                    carriedTimestamp = row.timestamp
                    break
                }
            }
            removeTrailingStreaming()
            let blocks: [Block] = (try? data["blocks"]?.decode([Block].self)) ?? []
            var firstText = true
            for block in blocks {
                switch block.type {
                case "text":
                    let text = block.text ?? ""
                    if text.isEmpty { continue }
                    var row = ChatRow(id: nextId(), kind: .assistant, text: text, nested: nested)
                    row.tsRaw = ts
                    row.eventSeq = seq
                    if firstText {
                        firstText = false
                        if !assistantTurnStarted.contains(parent) {
                            assistantTurnStarted.insert(parent)
                            row.timestamp = timestamp
                        } else if !carriedTimestamp.isEmpty {
                            row.timestamp = carriedTimestamp
                        }
                    }
                    appendEntry(row)
                case "thinking":
                    var row = ChatRow(id: nextId(), kind: .thinking, text: block.text ?? "", nested: nested)
                    row.tsRaw = ts
                    row.eventSeq = seq
                    appendEntry(row)
                case "tool_use":
                    let name = block.name ?? ""
                    let toolId = block.id ?? ""
                    var row = ChatRow(id: nextId(), kind: .tool, nested: nested)
                    row.toolId = toolId
                    row.toolName = name
                    row.toolSummary = Formatting.toolSummary(name: name, input: block.input)
                    row.toolInput = block.input?.compactJSONString()
                    row.tsRaw = ts
                    row.timestamp = timestamp
                    row.eventSeq = seq
                    if let task = tasksByToolUseId[toolId] {
                        row.task = task
                    }
                    appendEntry(row)
                default:
                    continue
                }
            }

        case "tool_result":
            let result = try? data.decode(ToolResultData.self)
            let toolId = result?.toolUseId ?? data["toolUseId"]?.stringValue ?? ""
            guard let index = entries.lastIndex(where: { $0.toolId == toolId }) else { return }
            entries[index].toolResult = result?.text ?? data["text"]?.stringValue ?? ""
            entries[index].toolError = result?.isError ?? (data["isError"]?.boolValue ?? false)
            entries[index].toolDone = true

        case "result":
            let ok = data["ok"]?.boolValue ?? false
            if ok { return }
            let text = data["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "The turn failed."
            var row = ChatRow(id: nextId(), kind: .error, text: text, nested: nested)
            row.tsRaw = ts
            row.timestamp = timestamp
            row.eventSeq = seq
            appendEntry(row)

        case "error":
            var text = data["message"]?.stringValue ?? "The turn failed."
            if data["code"]?.stringValue == "rate_limit" {
                text += " — switch account in Settings."
            }
            var row = ChatRow(id: nextId(), kind: .error, text: text, nested: nested)
            row.tsRaw = ts
            row.timestamp = timestamp
            row.eventSeq = seq
            appendEntry(row)

        case "notice":
            let plain = data["text"]?.stringValue ?? ""
            var row: ChatRow
            if !plain.isEmpty {
                row = ChatRow(id: nextId(), kind: .notice, text: plain, nested: nested)
                row.tsRaw = ts
                row.timestamp = timestamp
            } else {
                let noticeKind = data["kind"]?.stringValue ?? ""
                let summary = data["summary"]?.stringValue ?? ""
                let status = data["status"]?.stringValue ?? ""
                switch noticeKind {
                case "task":
                    let base: String
                    if !summary.isEmpty {
                        base = summary
                    } else if !status.isEmpty {
                        base = "Background task \(status)"
                    } else {
                        base = "Background task"
                    }
                    row = ChatRow(id: nextId(), kind: .notice, text: "⚙ \(base)", nested: nested)
                case "reminder":
                    if summary.isEmpty { return }
                    row = ChatRow(id: nextId(), kind: .notice, text: summary, nested: nested)
                case "agent":
                    let from = data["from"]?.stringValue ?? ""
                    let line = summary.isEmpty ? "Sub-agent report" : "Sub-agent report: \(summary)"
                    row = ChatRow(id: nextId(), kind: .notice, text: "↩ \(line)", nested: nested)
                    row.noticeFrom = from.isEmpty ? nil : from
                    // The hub (v10 §8.1) may include the full report text; when
                    // it does not, the summary is all the app has and there is
                    // nothing extra to expand.
                    let report = data["text"]?.stringValue
                        ?? data["report"]?.stringValue
                        ?? data["detail"]?.stringValue
                    row.noticeReport = report?.isEmpty == false ? report : nil
                    row.noticeKind = "agent"
                case "stopped":
                    // v10 §16: an interrupted turn is not an error. Show a
                    // muted centred line and mark its unfinished calls stopped.
                    row = ChatRow(id: nextId(), kind: .notice, text: "Stopped", nested: nested)
                    row.noticeKind = "stopped"
                    for index in entries.indices
                    where entries[index].kind == .tool && !entries[index].toolDone {
                        entries[index].toolStopped = true
                    }
                default:
                    // Unknown notice kinds are ignored (v10 §8).
                    return
                }
                row.tsRaw = ts
                row.timestamp = timestamp
                row.eventSeq = seq
            }
            appendEntry(row)

        case "task":
            guard let task = try? data.decode(TaskData.self) else { return }
            tasks[task.taskId] = task
            if let toolUseId = task.toolUseId, !toolUseId.isEmpty {
                tasksByToolUseId[toolUseId] = task
                if let index = entries.lastIndex(where: { $0.toolId == toolUseId }) {
                    entries[index].task = task
                }
            }
            onTask?(task)

        default:
            // "status" and unknown kinds are not chat rows.
            break
        }
    }

    private func clearStreamingFlags() {
        for index in entries.indices where entries[index].streaming {
            entries[index].streaming = false
        }
    }

    private func removeTrailingStreaming() {
        while let last = entries.last, last.streaming {
            entries.removeLast()
        }
    }
}
