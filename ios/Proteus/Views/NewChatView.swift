import SwiftUI
import Foundation
import ProteusKit

/// Where "new chat" goes. A destination, not a sheet: the desktop's new chat is
/// an empty composer (v15 §5.1), and asking a question should not need a form
/// (docs/DECISIONS.md D57).
struct NewChatTarget: Hashable {
    var project: String = ""
}

/// The new chat: type the question, everything else is a chip you can ignore.
///
/// v19 §2.4 replaced the sheet that asked for folder, project, model, mode and
/// a first message before it would let you press Create. Three of those four had
/// a right answer already (the project's folder, its default model, the last
/// mode), and the fourth was the only thing the user actually came here to do.
struct NewChatView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let target: NewChatTarget

    @AppStorage("proteus.newChatMode") private var mode = "default"

    @State private var project = ""
    @State private var folder = ""
    @State private var model = ""
    @State private var text = ""
    @State private var folderPicker = false
    @State private var didFill = false
    @FocusState private var typing: Bool

    private static let modeOptions: [(id: String, label: String)] = [
        ("default", "Ask"),
        ("acceptEdits", "Accept edits"),
        ("plan", "Plan"),
        ("auto", "Auto"),
    ]

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why pressing send would do nothing, in the user's words. Shown instead of
    /// a dead button, because a dead button is what made the old sheet look
    /// broken.
    private var blocker: String? {
        if !app.hasWorkstation { return "Add a workstation first — chats run on your machine, not this phone." }
        if app.connection != .connected { return "Not connected to \(app.activeWorkstation?.name ?? "the workstation")." }
        if folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose the folder this chat runs in." }
        if model.isEmpty { return "Choose a model." }
        return nil
    }

    private var canSend: Bool {
        !trimmedText.isEmpty && blocker == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            panel
            composer
        }
        .screenWave()
        .navigationTitle("New chat")
        .navigationBarTitleDisplayMode(.inline)
        .chromeToolbar(theme)
        .onAppear(perform: fillDefaults)
        .task {
            // Land ready to type: the push animation swallows an immediate focus.
            try? await Task.sleep(nanoseconds: 350_000_000)
            typing = true
        }
        .sheet(isPresented: $folderPicker) {
            FolderPickerSheet(
                title: "Chat folder",
                initialPath: folder.isEmpty ? app.defaultFolder : folder
            ) { path in
                folder = path
            }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    projectChip
                    folderChip
                    modelChip
                    modeChip
                }
                .padding(.vertical, 1)
            }

            if let message = blocker {
                notice(message, tint: theme.statusNeedsYou)
            } else if let error = app.errorText {
                notice(error, tint: theme.statusError)
            } else {
                Text(runLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textMeta)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.readingSurface)
        .clipShape(panelShape)
        .overlay { panelShape.strokeBorder(theme.rim, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func notice(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runLine: String {
        let where_ = folder.isEmpty ? "your workstation" : (folder as NSString).abbreviatingWithTildeInPath
        let machine = app.activeWorkstation?.name ?? "your workstation"
        return "Runs in \(where_) on \(machine). \(app.modelLabel(for: model)) · \(modeLabel)."
    }

    private var modeLabel: String {
        Self.modeOptions.first { $0.id == mode }?.label ?? "Ask"
    }

    // MARK: - Chips

    private var projectChip: some View {
        Menu {
            Button("No project") { setProject("") }
            ForEach(app.projects) { definition in
                Button(definition.name) { setProject(definition.name) }
            }
        } label: {
            Chip(title: project.isEmpty ? "No project" : project, icon: "square.stack")
        }
    }

    private var folderChip: some View {
        Menu {
            ForEach(app.recentFolders, id: \.self) { path in
                Button((path as NSString).abbreviatingWithTildeInPath) { folder = path }
            }
            if !app.recentFolders.isEmpty { Divider() }
            Button("Browse…") { folderPicker = true }
        } label: {
            Chip(
                title: folder.isEmpty ? "Folder" : (folder as NSString).lastPathComponent,
                icon: "folder"
            )
        }
    }

    private var modelChip: some View {
        ModelMenuButton(
            title: app.modelLabel(for: model),
            menu: app.modelMenu,
            selected: model,
            chip: true,
            onSelect: { model = $0 }
        )
    }

    private var modeChip: some View {
        Menu {
            ForEach(Self.modeOptions, id: \.id) { option in
                Button(option.label) { mode = option.id }
            }
        } label: {
            Chip(title: modeLabel, icon: "shield.lefthalf.filled")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything…", text: $text, axis: .vertical)
                .focused($typing)
                .lineLimit(1...6)
                .textInputAutocapitalization(.sentences)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.rim, lineWidth: 1)
                }
                .onSubmit(send)
                .submitLabel(.send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSend ? .white : theme.textMeta)
                    .frame(width: 38, height: 38)
                    .background(
                        canSend ? theme.accent : theme.fieldFill,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Start chat")
            .padding(.bottom, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .chromeBar(theme, edge: .top)
    }

    // MARK: - Actions

    private func fillDefaults() {
        guard !didFill else { return }
        didFill = true
        // Anything still showing belongs to wherever the user came from; this
        // screen reports its own failures below the chips.
        app.errorText = nil
        project = target.project
        folder = folderFor(project: project)
        model = app.defaultModelForNewChat(project: project)
    }

    /// The project's own folder, else the last one used, else the first project
    /// that has one. Empty only when the app has never seen a folder at all.
    private func folderFor(project name: String) -> String {
        if let definition = app.projects.first(where: { $0.name == name }),
           let cwd = definition.cwd, !cwd.isEmpty {
            return cwd
        }
        return app.defaultFolder
    }

    private func setProject(_ name: String) {
        project = name
        folder = folderFor(project: name)
        model = app.defaultModelForNewChat(project: name)
    }

    private func send() {
        guard canSend else { return }
        if app.createChat(
            cwd: folder,
            model: model,
            text: text,
            project: project,
            permissionMode: mode
        ) {
            text = ""
            dismiss()
        }
        // On failure `app.errorText` is set and the panel says what happened.
    }
}
