import SwiftUI
import ProteusKit

struct AgentsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var chat: ChatSessionModel

    /// Remembered across chats and launches (v9 §4).
    @AppStorage("proteus.agents.finishedCollapsed") private var finishedCollapsed = true

    /// Tapping an agent returns to the chat and scrolls to its tool card.
    var onSelect: ((TaskData) -> Void)? = nil

    /// Inside the Inspector sheet the view supplies its own chrome.
    var embedded = false

    private var running: [TaskData] {
        chat.sortedTasks.filter(\.isRunning)
    }

    private var finished: [TaskData] {
        chat.sortedTasks.filter { !$0.isRunning }
    }

    private var finishedExpanded: Binding<Bool> {
        Binding(
            get: { !finishedCollapsed },
            set: { finishedCollapsed = !$0 }
        )
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle("Agents")
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
                Section {
                    if running.isEmpty {
                        Text("No sub-agents are running right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(running) { task in
                            row(task)
                        }
                    }
                } header: {
                    Text(chat.taskSummary)
                }

                Section {
                    DisclosureGroup(isExpanded: finishedExpanded) {
                        if finished.isEmpty {
                            Text("No finished sub-agents yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(finished) { task in
                                row(task)
                            }
                        }
                    } label: {
                        Text("Finished (\(finished.count))")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ task: TaskData) -> some View {
        if let onSelect {
            Button {
                onSelect(task)
            } label: {
                AgentRow(task: task)
            }
            .buttonStyle(.plain)
        } else {
            AgentRow(task: task)
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var app: AppModel
    let task: TaskData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(task.agent)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Spacer()
            }

            Text(task.description.isEmpty ? "(no description)" : task.description)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            TaskLiveLine(
                task: task,
                modelLabel: task.model.map { app.modelLabel(for: $0) }
            )

            if let summary = task.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var statusLabel: String {
        switch task.statusKind {
        case .running: return "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    private var statusColor: Color {
        switch task.statusKind {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}
