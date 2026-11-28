import SwiftUI
import ProteusKit

struct NewChatSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var folder = ""
    @State private var model = ""
    @State private var project: String
    @State private var permissionMode = "default"
    @State private var folderPickerShown = false
    @State private var showHelp = false
    /// Device-local only: a new chat has no hub chat id yet, so its first
    /// message cannot use the synced draft store (v9 §1).
    @AppStorage("proteus.newChatDraft") private var text = ""

    init(project: String = "") {
        _project = State(initialValue: project)
    }

    private static let modeOptions: [(id: String, label: String)] = [
        ("default", "Ask"),
        ("acceptEdits", "Accept edits"),
        ("plan", "Plan"),
        ("auto", "Auto"),
    ]

    private var slashRows: [SlashCommand] {
        // The new-chat composer offers only /model, /mode and /help.
        SlashCommands.menu(for: text, engineCommands: [], newChat: true)
    }

    private var canCreate: Bool {
        !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = app.errorText {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("Folder") {
                    HStack {
                        TextField("/path/to/folder", text: $folder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            folderPickerShown = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Browse folders")
                    }
                    if !app.recentFolders.isEmpty {
                        Menu("Recent folders") {
                            ForEach(app.recentFolders, id: \.self) { path in
                                Button {
                                    folder = path
                                } label: {
                                    Text(path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }

                Section("Project") {
                    Picker("Project", selection: $project) {
                        Text("None").tag("")
                        ForEach(app.projects) { definition in
                            Text(definition.name).tag(definition.name)
                        }
                    }
                }

                Section("Model") {
                    ModelMenuButton(
                        title: app.modelLabel(for: model),
                        menu: app.modelMenu,
                        selected: model,
                        onSelect: { model = $0 }
                    )
                }

                Section("Permission mode") {
                    Picker("Mode", selection: $permissionMode) {
                        ForEach(Self.modeOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("First message") {
                    TextField("What should Claude do?", text: $text, axis: .vertical)
                        .lineLimit(3...10)

                    if !slashRows.isEmpty {
                        ForEach(slashRows) { command in
                            Button {
                                choose(command)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(command.name)
                                        .font(.callout.monospaced())
                                    Text(command.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                }
            }
            .onAppear {
                if folder.isEmpty { folder = app.defaultFolder }
                if model.isEmpty { model = app.defaultModelForNewChat(project: project) }
            }
            .onChange(of: project) { _, value in
                model = app.defaultModelForNewChat(project: value)
            }
            .sheet(isPresented: $folderPickerShown) {
                FolderPickerSheet(
                    title: "Chat folder",
                    initialPath: folder.isEmpty ? app.defaultFolder : folder
                ) { path in
                    folder = path
                }
            }
            .sheet(isPresented: $showHelp) {
                SlashHelpSheet()
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    /// New-chat `/` rows act on the sheet's own pickers instead of a hub chat.
    private func choose(_ command: SlashCommand) {
        switch command.name {
        case "/model":
            text = ""
        case "/mode":
            let modes = Self.modeOptions.map(\.id)
            if let index = modes.firstIndex(of: permissionMode) {
                permissionMode = modes[(index + 1) % modes.count]
            }
            text = ""
        case "/help":
            text = ""
            showHelp = true
        default:
            break
        }
    }

    private func create() {
        let raw = text
        if let parsed = SlashCommands.parse(raw), SlashCommands.isProteusCommand(parsed.command) {
            switch parsed.command {
            case "/model":
                if !parsed.argument.isEmpty {
                    if let id = matchModel(parsed.argument) {
                        model = id
                        text = ""
                    } else {
                        app.errorText = "No available model matches “\(parsed.argument)”."
                    }
                }
                return
            case "/mode":
                if !parsed.argument.isEmpty {
                    let query = parsed.argument.lowercased()
                    if let option = Self.modeOptions.first(where: {
                        $0.id.lowercased() == query || $0.label.lowercased() == query
                    }) {
                        permissionMode = option.id
                        text = ""
                    } else {
                        app.errorText = "Unknown mode “\(parsed.argument)”."
                    }
                }
                return
            case "/help":
                text = ""
                showHelp = true
                return
            default:
                break
            }
        }

        guard canCreate else { return }
        if app.createChat(
            cwd: folder,
            model: model,
            text: raw,
            project: project,
            permissionMode: permissionMode
        ) {
            text = ""
            dismiss()
        }
    }

    private func matchModel(_ query: String) -> String? {
        let models = (app.modelMenu.sections + app.modelMenu.more)
            .flatMap(\.models)
            .filter(\.available)
        let q = query.lowercased()
        if let exact = models.first(where: {
            $0.id.lowercased() == q || $0.label.lowercased() == q
        }) {
            return exact.id
        }
        return models.first {
            $0.id.lowercased().contains(q) || $0.label.lowercased().contains(q)
        }?.id
    }
}
