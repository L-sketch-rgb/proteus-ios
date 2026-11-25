import SwiftUI
import ProteusKit

extension SlashCommand.Group {
    var title: String { rawValue }
}

/// The `/` menu that floats above the composer (v9 §3). Proteus commands come
/// first, engine commands after, grouped under their headings.
struct SlashMenuView: View {
    let rows: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, command in
                        if index == 0 || rows[index - 1].group != command.group {
                            Text(command.group.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 8 : 10)
                                .padding(.bottom, 2)
                        }
                        Button {
                            onSelect(command)
                        } label: {
                            HStack(spacing: 10) {
                                Text(command.name)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.primary)
                                Text(command.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 220)
        }
        .glassCard(cornerRadius: 14)
    }
}

/// `/model` without an argument: the catalog, filtered to usable models.
struct SlashModelPickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String) -> Void

    private var sections: [ModelSection] {
        (app.modelMenu.sections + app.modelMenu.more)
            .filter { section in section.models.contains(where: \.available) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.models.filter(\.available)) { model in
                            Button {
                                onSelect(model.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.label)
                                        .foregroundStyle(.primary)
                                    Text(model.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if sections.isEmpty {
                    Text("No models available.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// `/help`: the Proteus commands. Engine commands are listed by the hub and
/// appear in the `/` menu, so they are not duplicated here.
struct SlashHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Proteus commands") {
                    ForEach(SlashCommands.proteus) { command in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.name)
                                .font(.callout.monospaced())
                            Text(command.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    Text("Queued prompts run one after another when a turn finishes. Scheduled prompts wait for their time. Hold the send button (or press Option-Return on a hardware keyboard) to queue the composer text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
