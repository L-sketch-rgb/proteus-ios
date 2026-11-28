import SwiftUI
import Foundation
import ProteusKit

struct ChatsView: View {
    @EnvironmentObject private var app: AppModel

    @State private var search = ""
    @State private var path = NavigationPath()
    @State private var showNewChat = false
    @State private var newChatProject = ""
    @State private var showSettings = false
    @State private var showFiles = false
    @State private var collapsedProjects: Set<String> = []
    @State private var terminalsExpanded = true
    @State private var showNewTerminal = false
    @State private var renameTarget: SessionInfo?
    @State private var deleteTarget: SessionInfo?
    @State private var projectEditorTarget: ProjectEditTarget?
    @State private var deleteProjectTarget: ProjectDef?
    @State private var didRouteDemo = false

    private var listing: SessionListing {
        app.filteredListing(search: search)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if app.sessions.isEmpty && search.isEmpty {
                    EmptyChatsRow(showSettings: $showSettings)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    if !listing.projects.isEmpty {
                        Section {
                            ForEach(listing.projects) { group in
                                DisclosureGroup(isExpanded: expansion(for: group.name)) {
                                    if group.sessions.isEmpty {
                                        Text("No chats in this project")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(group.sessions) { session in
                                            sessionLink(session)
                                        }
                                    }
                                } label: {
                                    ProjectHeader(name: group.name, count: group.sessions.count)
                                        .contentShape(Rectangle())
                                        .contextMenu {
                                            Button {
                                                projectEditorTarget = ProjectEditTarget(project: group.project)
                                            } label: {
                                                Label("Project settings…", systemImage: "slider.horizontal.3")
                                            }
                                            Button {
                                                newChatProject = group.name
                                                showNewChat = true
                                            } label: {
                                                Label("New chat in project", systemImage: "plus.bubble")
                                            }
                                            Button {
                                                path.append(TerminalTarget.new(cwd: group.project.cwd ?? ""))
                                            } label: {
                                                Label("Open terminal in project", systemImage: "terminal")
                                            }
                                            Divider()
                                            Button(role: .destructive) {
                                                deleteProjectTarget = group.project
                                            } label: {
                                                Label("Delete project…", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Projects")
                                Spacer()
                                Button {
                                    projectEditorTarget = ProjectEditTarget(project: nil)
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("New project")
                            }
                        }
                    }

                    Section {
                        if listing.chats.isEmpty {
                            Text(search.isEmpty ? "No chats yet" : "No matches")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(listing.chats) { session in
                                sessionLink(session)
                            }
                        }
                    } header: {
                        Text("Chats")
                    }
                }

                // Terminals stay visible even when the hub has no chats yet:
                // shells started on the desktop must be reachable from here.
                terminalsSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("Chats")
            .glassToolbar()
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = app.errorText {
                        ErrorBanner(text: error) { app.errorText = nil }
                    }
                    if app.oldHubNotice {
                        OldHubBanner { app.dismissOldHubNotice() }
                    }
                    ConnectionBanner(
                        state: app.connection,
                        hasWorkstation: app.hasWorkstation,
                        onRetry: { app.reconnect() }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFiles = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Files")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newChatProject = ""
                        showNewChat = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatView(chat: app.chatModel(for: id))
            }
            .navigationDestination(for: TerminalTarget.self) { target in
                TerminalScreen(target: target)
            }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(project: newChatProject)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFiles) {
            FilesPanelView()
        }
        .sheet(isPresented: $showNewTerminal) {
            NewTerminalSheet { cwd in
                showNewTerminal = false
                DispatchQueue.main.async {
                    path.append(TerminalTarget.new(cwd: cwd))
                }
            }
        }
        .sheet(item: $projectEditorTarget) { target in
            ProjectEditorSheet(project: target.project)
        }
        .sheet(item: $renameTarget) { session in
            RenameChatSheet(session: session)
        }
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { session in
            Button("Delete", role: .destructive) {
                app.delete(session)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { session in
            Text("“\(session.title)” disappears from every device. The hub keeps the transcript in its trash folder.")
        }
        .alert(
            "Delete project?",
            isPresented: Binding(
                get: { deleteProjectTarget != nil },
                set: { if !$0 { deleteProjectTarget = nil } }
            ),
            presenting: deleteProjectTarget
        ) { project in
            Button("Delete project", role: .destructive) {
                app.deleteProject(project.name)
                deleteProjectTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteProjectTarget = nil }
        } message: { _ in
            Text("Its chats stay, but they are no longer grouped under it.")
        }
        .onChange(of: app.pendingOpenChatId) { _, id in
            guard let id else { return }
            app.pendingOpenChatId = nil
            path.append(id)
        }
        .onAppear {
            // The demo data is loaded by AppModel.start(); give it one run-loop
            // turn so the requested screenshot screen sees the data.
            DispatchQueue.main.async { routeDemoIfNeeded() }
        }
    }

    @ViewBuilder
    private var terminalsSection: some View {
        Section {
            if terminalsExpanded {
                if app.terminals.isEmpty {
                    Text("No terminals open")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.terminals) { term in
                        terminalLink(term)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        terminalsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: terminalsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                        Text("Terminals")
                        if !app.terminals.isEmpty {
                            Text("\(app.terminals.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(terminalsExpanded ? "Collapse terminals" : "Expand terminals")
                Spacer()
                Button {
                    showNewTerminal = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New terminal")
            }
        }
    }

    private func terminalLink(_ term: TermInfo) -> some View {
        NavigationLink(value: TerminalTarget.existing(term.id)) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.callout)
                    .foregroundStyle(term.alive ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.title.isEmpty ? "Terminal" : term.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(term.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if term.pid > 0 {
                    Text("pid \(term.pid)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                app.closeTerminal(term.id)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private func sessionLink(_ session: SessionInfo) -> some View {
        NavigationLink(value: session.id) {
            SessionRowView(session: session, modelLabel: app.modelLabel(for: session.model))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if session.statusKind == .running || session.statusKind == .waiting {
                Button {
                    app.stop(session)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                renameTarget = session
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Menu {
                Button("None") { app.move(session, toProject: "") }
                ForEach(app.projects) { project in
                    Button(project.name) { app.move(session, toProject: project.name) }
                }
            } label: {
                Label("Move to project", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func expansion(for name: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjects.contains(name) },
            set: { expanded in
                if expanded {
                    collapsedProjects.remove(name)
                } else {
                    collapsedProjects.insert(name)
                }
            }
        )
    }

    /// `-ProteusDemoScreen=<name>` opens one screen for the CI screenshots.
    /// Everything else starts on the chats list.
    private func routeDemoIfNeeded() {
        guard app.isDemo, !didRouteDemo else { return }
        didRouteDemo = true
        switch app.demoScreen {
        case "project":
            projectEditorTarget = ProjectEditTarget(project: app.projects.first)
        case "terminal":
            if let term = app.terminals.first {
                path.append(TerminalTarget.existing(term.id))
            } else {
                path.append(TerminalTarget.new(cwd: app.projects.first?.cwd ?? ""))
            }
        case "agents":
            if let first = app.sessions.first {
                path.append(first.id)
            }
        case "settings":
            showSettings = true
        default:
            break
        }
    }
}

private struct ProjectEditTarget: Identifiable {
    let project: ProjectDef?
    var id: String { project?.name ?? "new-project" }
}

private struct ProjectHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionRowView: View {
    let session: SessionInfo
    let modelLabel: String

    private var folder: String {
        let last = (session.cwd as NSString).lastPathComponent
        return last.isEmpty ? "—" : last
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.statusKind.color)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Untitled chat" : session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(modelLabel)
                        .lineLimit(1)
                    Text("·")
                    Text(folder)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if session.agentsRunning > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape.2.fill")
                    Text("\(session.agentsRunning)")
                }
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(session.agentsRunning) agents running")
            }

            if session.queued > 0 {
                Text("⏱ \(session.queued)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(session.queued) queued prompts")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyChatsRow: View {
    @EnvironmentObject private var app: AppModel
    @Binding var showSettings: Bool
    @AppStorage("proteus.palette") private var paletteKey = "blue"

    var body: some View {
        VStack(spacing: 16) {
            PaletteMark(selection: paletteKey)
                .frame(width: 120, height: 120)
                .opacity(0.9)
            Text("Proteus")
                .font(.title2.weight(.semibold))
            Text(app.hasWorkstation
                 ? "Start a chat with +."
                 : "Add your workstation in Settings to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !app.hasWorkstation {
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}

struct RenameChatSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: SessionInfo

    @State private var title: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .textInputAutocapitalization(.sentences)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Rename chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") {
                        app.rename(session, title: title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if title.isEmpty { title = session.title }
            }
        }
        .presentationDetents([.height(180)])
        .presentationBackground(.ultraThinMaterial)
    }
}
