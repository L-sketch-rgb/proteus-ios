import SwiftUI
import ProteusKit

/// Sub-agents of one chat: a compact card per agent (name, status, what it
/// was asked, elapsed time). Tapping a card pushes its detail with the full
/// request and result; the back button returns to the list.
struct AgentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var chat: ChatSessionModel

    /// "Show in chat" from the detail view: returns to the transcript and
    /// scrolls to the agent's tool card.
    var onSelect: ((TaskData) -> Void)? = nil

    private var running: [TaskData] {
        chat.sortedTasks.filter(\.isRunning)
    }

    private var finished: [TaskData] {
        chat.sortedTasks.filter { !$0.isRunning }
    }

    /// Inside the Inspector sheet the view supplies its own chrome and
    /// navigation stack; the detail view then pushes onto the inspector's.
    var embedded = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle("Sub-agents")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private var content: some View {
        List {
            if chat.sortedTasks.isEmpty {
                Text("No sub-agents or background commands in this chat yet.")
                    .foregroundStyle(.secondary)
            }
            if !running.isEmpty {
                Section("Running (\(running.count))") {
                    ForEach(running) { task in card(task) }
                }
            }
            if !finished.isEmpty {
                Section("Finished (\(finished.count))") {
                    ForEach(finished) { task in card(task) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationDestination(for: String.self) { taskId in
            if let task = chat.sortedTasks.first(where: { $0.taskId == taskId }) {
                AgentDetailView(task: task, chat: chat, onShowInChat: onSelect.map { handler in
                    { handler(task) }
                })
            } else {
                Text("This agent is no longer listed.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func card(_ task: TaskData) -> some View {
        NavigationLink(value: task.taskId) {
            AgentCard(task: task)
        }
    }
}

// MARK: - Shared helpers

enum AgentText {
    /// `local_bash` and friends are internal ids; show something readable.
    static func name(_ task: TaskData) -> String {
        let raw = task.agent.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "Agent" }
        // A path is never a title: keep the last component.
        if raw.contains("/"), let last = raw.split(separator: "/").last { return String(last) }
        switch raw {
        case "local_bash", "bash": return "Background command"
        case "general-purpose": return "General agent"
        default:
            let cleaned = raw.replacingOccurrences(of: "local_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
    }

    /// The first non-empty line, so a heredoc is not dumped into a card.
    static func firstLine(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static func statusLabel(_ task: TaskData) -> String {
        switch task.statusKind {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    static func statusColor(_ task: TaskData) -> Color {
        switch task.statusKind {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    static func statusIcon(_ task: TaskData) -> String {
        switch task.statusKind {
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    /// Elapsed time: live while running, else the recorded or derived span.
    static func elapsed(_ task: TaskData, now: Date) -> String? {
        if task.isRunning {
            guard let seconds = Formatting.elapsedSeconds(sinceISO: task.startedAt, now: now) else { return nil }
            return Formatting.duration(seconds: seconds)
        }
        if let ms = task.durationMs, ms > 0 { return Formatting.duration(milliseconds: ms) }
        if let start = Formatting.parseISO(task.startedAt),
           let endIso = task.endedAt, let end = Formatting.parseISO(endIso) {
            return Formatting.duration(seconds: max(0, Int(end.timeIntervalSince(start))))
        }
        return nil
    }
}

// MARK: - Card

private struct AgentCard: View {
    let task: TaskData

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: AgentText.statusIcon(task))
                    .foregroundStyle(AgentText.statusColor(task))
                Text(AgentText.name(task))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(AgentText.statusLabel(task))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AgentText.statusColor(task))
            }

            let ask = AgentText.firstLine(task.description)
            if !ask.isEmpty {
                Text(ask)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TimelineView(.periodic(from: .now, by: task.isRunning ? 1.0 : 3600)) { context in
                HStack(spacing: 10) {
                    if let elapsed = AgentText.elapsed(task, now: context.date) {
                        Label(elapsed, systemImage: "clock")
                            .monospacedDigit()
                    }
                    if let tools = task.toolUses, tools > 0 {
                        Label("\(tools) tool\(tools == 1 ? "" : "s")", systemImage: "wrench")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct AgentDetailView: View {
    let task: TaskData
    @ObservedObject var chat: ChatSessionModel
    var onShowInChat: (() -> Void)?

    @State private var showFullRequest = false

    /// The agent's result: its tool result in the transcript, else the
    /// task summary the hub reported.
    private var result: String {
        if let toolUseId = task.toolUseId, !toolUseId.isEmpty,
           let row = chat.allRows.last(where: { $0.toolId == toolUseId }),
           let text = row.toolResult, !text.isEmpty {
            return text
        }
        return task.summary ?? ""
    }

    /// The agent's own tool calls: the nested rows that follow its card in the
    /// transcript. The same command twice in a row is shown once.
    private var calls: [ChatRow] {
        guard let toolUseId = task.toolUseId, !toolUseId.isEmpty else { return [] }
        let all = chat.allRows
        guard let start = all.lastIndex(where: { $0.toolId == toolUseId }) else { return [] }
        var out: [ChatRow] = []
        var last = ""
        for row in all[(start + 1)...] {
            guard row.nested else { break }
            guard row.kind == .tool else { continue }
            let line = (row.toolName ?? "") + (row.toolSummary ?? "")
            if line == last { continue }
            last = line
            out.append(row)
        }
        return out
    }

    private var requestText: String {
        task.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: AgentText.statusIcon(task))
                    Text(AgentText.statusLabel(task))
                        .font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: task.isRunning ? 1.0 : 3600)) { context in
                        if let elapsed = AgentText.elapsed(task, now: context.date) {
                            Text(elapsed)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(AgentText.statusColor(task))

                section("Asked") {
                    let full = task.description
                    let lines = full.components(separatedBy: "\n")
                    let long = lines.count > 4 || full.count > 400
                    Text(showFullRequest || !long ? full : AgentText.firstLine(full))
                        .font(.callout)
                        .lineLimit(showFullRequest || !long ? nil : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if long {
                        Button(showFullRequest ? "Show less" : "Show full request") {
                            showFullRequest.toggle()
                        }
                        .font(.caption)
                    }
                }

                if !calls.isEmpty {
                    section("Tool calls (\(calls.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(calls) { call in
                                AgentCallLine(row: call)
                            }
                        }
                    }
                } else if let tools = task.toolUses, tools > 0 {
                    Text("\(tools) tool call\(tools == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("Result") {
                    if result.isEmpty || result.trimmingCharacters(in: .whitespacesAndNewlines) == requestText {
                        Text(task.isRunning ? "Still running. The result appears here when it finishes." : "No result was reported.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        MarkdownText(text: result)
                    }
                }

                if let onShowInChat {
                    Button {
                        onShowInChat()
                    } label: {
                        Label("Show in chat", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
        .navigationTitle(AgentText.name(task))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// One tool call of a sub-agent on one line; tap to see its input and result.
private struct AgentCallLine: View {
    let row: ChatRow
    @State private var expanded = false

    private var title: String {
        let name = row.toolName?.isEmpty == false ? row.toolName! : "Tool"
        let summary = ToolCardView.shortSummary(row.toolSummary ?? "", tool: name)
        return summary.isEmpty ? name : "\(name) · \(summary)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let result = row.toolResult, !result.isEmpty {
                Text(Formatting.truncate(result, 1500))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
