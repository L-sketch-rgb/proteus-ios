import SwiftUI
import ProteusKit

/// v10 §13: the chat's pinned items, newest first. Tapping a row closes the
/// sheet and scrolls the chat to that item; the × unpins it.
struct PinsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var chat: ChatSessionModel

    /// Called with the pin the user wants to jump to.
    var onSelect: ((Pin) -> Void)? = nil

    private var pins: [Pin] {
        app.pins(for: chat.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if !app.hasFeature("pins") {
                    Text("Pins need a newer hub.")
                        .foregroundStyle(.secondary)
                } else if pins.isEmpty {
                    Text("No pins in this chat yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pins) { pin in
                        row(pin)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Pins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private func row(_ pin: Pin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onSelect?(pin)
                dismiss()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(pin.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pin.excerpt)
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            Text(kindLabel(pin.kind))
                            if !pin.ts.isEmpty {
                                Text(Formatting.timestamp(pin.ts))
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                app.removePin(pin, chatId: chat.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unpin")
        }
        .padding(.vertical, 2)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "user": return "person"
        case "assistant": return "text.bubble"
        case "tool": return "hammer"
        case "group": return "square.stack.3d.up"
        default: return "pin"
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "user": return "Message"
        case "assistant": return "Reply"
        case "tool": return "Tool"
        case "group": return "Tool group"
        default: return "Pin"
        }
    }
}
