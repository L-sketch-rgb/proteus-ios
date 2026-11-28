import SwiftUI
import ProteusKit

/// New/edit project dialog, mirroring `linux/qml/ProjectDialog.qml`: the app
/// default folder/model are empty strings, sub-agent tiers are inherit/top/
/// mid/fast, and saved presets replace the old fixed style.
struct ProjectEditorSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let original: ProjectDef?

    @State private var draft: ProjectDef
    @State private var folderPickerShown = false
    @State private var deleteConfirmShown = false
    @State private var expandedPrompts: Set<Int> = []
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var deletePresetTarget: ProjectPreset?

    init(project: ProjectDef?) {
        original = project
        _draft = State(initialValue: project ?? ProjectDef(name: ""))
    }

    private var isEditing: Bool { original != nil }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cwdBinding: Binding<String> {
        Binding(
            get: { draft.cwd ?? "" },
            set: { draft.cwd = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    HStack {
                        TextField("App default (home folder)", text: cwdBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            folderPickerShown = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }

                    Menu {
                        Button("App default") { draft.defaultModel = nil }
                        ForEach(app.modelMenu.sections) { section in
                            ForEach(section.models) { model in
                                Button("\(section.title) · \(model.label)") {
                                    draft.defaultModel = model.id
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Default model")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(draft.defaultModel.map { app.modelLabel(for: $0) } ?? "App default")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Project")
                }

                Section {
                    TextEditor(text: Binding(
                        get: { draft.instructions ?? "" },
                        set: { draft.instructions = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 90)
                    .font(.footnote)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Appended to the system prompt of every chat in this project.")
                }

                Section("Sub-agent policy") {
                    TextEditor(text: Binding(
                        get: { draft.agentPolicy ?? "" },
                        set: { draft.agentPolicy = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 80)
                    .font(.footnote)
                    // v10 §15.4: a neutral placeholder, nothing personal.
                    .overlay(alignment: .topLeading) {
                        if (draft.agentPolicy ?? "").isEmpty {
                            Text("e.g. Delegate searches and mechanical edits; keep design decisions yourself.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }

                Section {
                    ForEach(draft.subagents.indices, id: \.self) { index in
                        subagentRow(index)
                    }
                    .onDelete { offsets in
                        draft.subagents.remove(atOffsets: offsets)
                        expandedPrompts.removeAll()
                    }

                    Button {
                        draft.subagents.append(SubagentDef(name: "", when: ""))
                    } label: {
                        Label("Add sub-agent", systemImage: "plus")
                    }

                    // v10 §15.4: user-made presets from the hub replace the
                    // owner's fixed style. Nothing is seeded from code.
                    Menu {
                        ForEach(app.presets) { preset in
                            Button(preset.name) { apply(preset) }
                        }
                        if !app.presets.isEmpty {
                            Divider()
                            Menu {
                                ForEach(app.presets) { preset in
                                    Button(role: .destructive) {
                                        deletePresetTarget = preset
                                    } label: {
                                        Text(preset.name)
                                    }
                                }
                            } label: {
                                Label("Delete preset", systemImage: "trash")
                            }
                            Divider()
                        }
                        Button {
                            presetName = ""
                            showSavePreset = true
                        } label: {
                            Label("Save current as preset…", systemImage: "plus")
                        }
                    } label: {
                        Label("Presets", systemImage: "square.stack.3d.up")
                    }
                    .disabled(!app.hasFeature("presets"))
                    .accessibilityHint(app.hasFeature("presets") ? "" : "Needs a newer hub")
                } header: {
                    HStack {
                        Text("Sub-agents")
                    }
                } footer: {
                    Text("Sub-agents never make design decisions; the main model keeps every judgment call.")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            deleteConfirmShown = true
                        } label: {
                            Label("Delete project…", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Project settings" : "New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .themedSheet(isPresented: $folderPickerShown) {
                FolderPickerSheet(
                    title: "Default folder",
                    initialPath: draft.cwd ?? app.defaultFolder
                ) { path in
                    draft.cwd = path
                }
            }
            .confirmationDialog(
                "Delete this project?",
                isPresented: $deleteConfirmShown,
                titleVisibility: .visible
            ) {
                Button("Delete project", role: .destructive) {
                    if let original {
                        app.deleteProject(original.name)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its chats stay, but they are no longer grouped under it.")
            }
            .alert("Save current as preset", isPresented: $showSavePreset) {
                TextField("Name", text: $presetName)
                    .textInputAutocapitalization(.never)
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The preset is stored on the hub and synced to every device. Saving under an existing name overwrites it.")
            }
            .confirmationDialog(
                "Delete this preset?",
                isPresented: Binding(
                    get: { deletePresetTarget != nil },
                    set: { if !$0 { deletePresetTarget = nil } }
                ),
                presenting: deletePresetTarget
            ) { preset in
                Button("Delete preset", role: .destructive) {
                    app.deletePreset(preset)
                    deletePresetTarget = nil
                }
                Button("Cancel", role: .cancel) { deletePresetTarget = nil }
            } message: { preset in
                Text("“\(preset.name)” is removed from every device. The project keeps its current policy.")
            }
        }
    }

    // MARK: - Presets (v10 §15.4)

    /// Apply a saved preset to the draft only; the project is stored when the
    /// dialog's Save is pressed.
    private func apply(_ preset: ProjectPreset) {
        draft.agentPolicy = preset.agentPolicy?.isEmpty == false ? preset.agentPolicy : nil
        draft.subagents = preset.subagents
        expandedPrompts.removeAll()
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let agents = draft.subagents.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        app.savePreset(name: name, agentPolicy: draft.agentPolicy, subagents: agents)
    }

    @ViewBuilder
    private func subagentRow(_ index: Int) -> some View {
        if draft.subagents.indices.contains(index) {
            let agent = $draft.subagents[index]
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name (e.g. coder)", text: agent.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.weight(.semibold))

                HStack {
                    Menu {
                        Button("Same as chat") { agent.wrappedValue.model = "inherit" }
                        Button("Strongest") { agent.wrappedValue.model = "top" }
                        Button("Balanced") { agent.wrappedValue.model = "mid" }
                        Button("Fastest") { agent.wrappedValue.model = "fast" }
                        Divider()
                        ForEach(app.modelMenu.sections) { section in
                            ForEach(section.models) { model in
                                Button("\(section.title) · \(model.label)") {
                                    agent.wrappedValue.model = model.id
                                }
                            }
                        }
                    } label: {
                        Text(modelLabel(agent.wrappedValue.model))
                            .font(.footnote)
                    }

                    Spacer()

                    Picker("Tools", selection: agent.tools) {
                        Text("All tools").tag("all")
                        Text("Read-only").tag("read-only")
                    }
                    .pickerStyle(.menu)
                    .font(.footnote)
                }

                TextField("When to use", text: agent.when, axis: .vertical)
                    .font(.footnote)

                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedPrompts.contains(index) },
                        set: { expanded in
                            if expanded { expandedPrompts.insert(index) } else { expandedPrompts.remove(index) }
                        }
                    )
                ) {
                    TextEditor(text: Binding(
                        get: { agent.wrappedValue.prompt ?? "" },
                        set: { agent.wrappedValue.prompt = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 70)
                    .font(.footnote)
                } label: {
                    Text("Prompt (optional, new agent types only)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func modelLabel(_ value: String) -> String {
        switch value {
        case "top": return "Strongest"
        case "mid": return "Balanced"
        case "fast": return "Fastest"
        case "inherit", "": return "Same as chat"
        default: return app.modelLabel(for: value)
        }
    }

    private func save() {
        var project = draft
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.subagents = project.subagents.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard app.saveProject(project, oldName: original?.name) else { return }
        dismiss()
    }
}

// MARK: - Folder picker

/// `fs.dirs` folder browser shared by the project dialog, new chat and new
/// terminal sheets.
struct FolderPickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialPath: String
    let onChoose: (String) -> Void

    @State private var path: String

    init(title: String, initialPath: String, onChoose: @escaping (String) -> Void) {
        self.title = title
        self.initialPath = initialPath
        self.onChoose = onChoose
        _path = State(initialValue: initialPath)
    }

    private var entries: [String] {
        guard app.dirsRequestedPath == path else { return [] }
        return app.dirsEntries
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("/path/to/folder", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                            .onSubmit { app.requestDirs(path: path) }
                        Button("Go") { app.requestDirs(path: path) }
                            .buttonStyle(.borderless)
                    }
                    if path != "/" {
                        Button {
                            path = parent(of: path)
                            app.requestDirs(path: path)
                        } label: {
                            Label("Parent folder", systemImage: "arrow.up")
                        }
                    }
                }

                Section("Folders") {
                    if app.dirsRequestedPath == path && entries.isEmpty {
                        Text("No sub-folders")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries, id: \.self) { name in
                        Button {
                            path = join(path, name)
                            app.requestDirs(path: path)
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Folder") {
                        onChoose(path)
                        dismiss()
                    }
                }
            }
            .onAppear { app.requestDirs(path: path) }
        }
    }

    private func parent(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func join(_ base: String, _ name: String) -> String {
        (base as NSString).appendingPathComponent(name)
    }
}
