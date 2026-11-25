import SwiftUI
import ProteusKit

/// The pending strip above the composer (v9 §3). Shows the chat's queue items
/// with Edit / Send now / Remove, and the paused line when the chat is in error.
struct PendingStripView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var chat: ChatSessionModel

    @State private var editingId: String?
    @State private var editText = ""
    @State private var rescheduleItem: QueueItem?

    private var items: [QueueItem] {
        app.queueItems[chat.id] ?? []
    }

    private var isPaused: Bool {
        chat.session?.statusKind == .error
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if isPaused {
                        Label("Paused: the chat hit an error", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(10)
                .glassCard(cornerRadius: 14)
            }
        }
        .sheet(item: $rescheduleItem) { item in
            ScheduleSheet(
                title: "Send at",
                initialDate: item.scheduledDate
            ) { date in
                app.updateQueueItem(item, text: nil, at: .at(SchedulePresets.isoString(date)))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: QueueItem) -> some View {
        if editingId == item.qid {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Prompt", text: $editText, axis: .vertical)
                    .lineLimit(1...3)
                HStack(spacing: 10) {
                    if item.isScheduled {
                        Button {
                            rescheduleItem = item
                        } label: {
                            Label("Time…", systemImage: "clock")
                        }
                        .font(.caption)
                    }
                    Spacer()
                    Button("Cancel") {
                        editingId = nil
                    }
                    .font(.caption)
                    Button("Save") {
                        app.updateQueueItem(item, text: editText, at: .unchanged)
                        editingId = nil
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(6)
        } else {
            HStack(spacing: 8) {
                if item.isScheduled {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timeLabel(item))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Next")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.text)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    // v10 §3: the queued item's creation time (the Linux
                    // tooltip; iOS has no hover).
                    Text("Created \(createdLabel(item))")
                    Button {
                        editText = item.text
                        editingId = item.qid
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        app.sendQueueItemNow(item)
                    } label: {
                        Label("Send now", systemImage: "paperplane")
                    }
                    Divider()
                    Button(role: .destructive) {
                        app.removeQueueItem(item)
                    } label: {
                        Label("Cancel this queued prompt", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Queue actions")
            }
        }
    }

    private func timeLabel(_ item: QueueItem) -> String {
        guard let date = item.scheduledDate else { return "—" }
        // v11 §1: the system locale decides 12/24 h and the day names.
        return Formatting.timestamp(date)
    }

    /// v10 §3: the creation time of a queued item, in the same local form as
    /// the chat timestamps (empty when the hub sent none).
    private func createdLabel(_ item: QueueItem) -> String {
        let label = Formatting.timestamp(item.createdAt)
        return label.isEmpty ? "—" : label
    }
}
