import SwiftUI
import ProteusKit

/// Chats, rebuilt for touch (docs/design/v18-ios.md §3).
///
/// The desktop's 56 px project rail becomes a horizontal strip of chips that
/// stays under the nav bar; the slot's list is one scrolling column with the
/// desktop's Active / Older split. Everything rare lives in the long-press menu
/// so the screen stays a list of chats, not a control panel.
struct ChatsHomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @State private var rail: RailSelection = .all
    @State private var search = ""
    @State private var path = NavigationPath()
    @State private var collapsed: Set<String> = []
    @State private var showNewChat = false
    @State private var newChatProject = ""
    @State private var renameTarget: SessionInfo?
    @State private var deleteTarget: SessionInfo?
    @State private var projectEditorTarget: ProjectEditTarget?
    @State private var deleteProjectTarget: ProjectDef?
    @State private var didRouteDemo = false
    @State private var showWorkstations = false

    // MARK: - Data

    private var visibleSessions: [SessionInfo] {
        let listing = app.filteredListing(search: search)
        let all = listing.projects.flatMap(\.sessions) + listing.chats
        switch rail {
        case .all:
            return all
        case .project(let name):
            return all.filter { $0.project == name }
        case .chats:
            let known = Set(app.projects.map(\.name))
            return all.filter { $0.project.isEmpty || !known.contains($0.project) }
        }
    }

    private var groups: [ChatGroup] {
        ChatGroups.groups(
            for: visibleSessions,
            scope: rail == .chats ? .oneOff : .project,
            lastSeen: { app.lastSeenAt($0) }
        )
    }

    private var needsYouCount: Int {
        groups.first(where: { $0.kind == .needsYou })?.sessions.count ?? 0
    }

    private var summary: String {
        let total = visibleSessions.count
        if total == 0 { return "" }
        var parts: [String] = []
        if needsYouCount > 0 { parts.append("\(needsYouCount) need you") }
        parts.append("\(total) chat\(total == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if visibleSessions.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(groups) { group in
                        section(for: group)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.readingSurface)
            .listRowSpacing(0)
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search chats"
            )
            .refreshable { app.reconnect() }
            .navigationTitle(rail.title)
            // Inline, not large: with a top safe-area inset (the pinned rail)
            // the large title lays out its space but never draws, which left an
            // empty band above the search field in the CI screenshot.
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { projectRail }
            .safeAreaInset(edge: .bottom, spacing: 0) { banners }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newChatProject = rail.projectName ?? ""
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
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
        .sheet(isPresented: $showWorkstations) {
            NavigationStack {
                WorkstationsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWorkstations = false }
                        }
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
            rail = .all
            path.append(id)
        }
        .onAppear {
            DispatchQueue.main.async { routeDemoIfNeeded() }
        }
    }

    // MARK: - Rail

    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(for: .all, dot: groupNeedsYou(.all))
                    ForEach(app.projects) { project in
                        chip(for: .project(project.name), dot: groupNeedsYou(.project(project.name)))
                            .contextMenu {
                                Button {
                                    projectEditorTarget = ProjectEditTarget(project: project)
                                } label: {
                                    Label("Project settings…", systemImage: "slider.horizontal.3")
                                }
                                Button {
                                    newChatProject = project.name
                                    showNewChat = true
                                } label: {
                                    Label("New chat here", systemImage: "plus.bubble")
                                }
                                Button {
                                    newChatProject = project.name
                                    path.append(TerminalTarget.new(cwd: project.cwd ?? ""))
                                } label: {
                                    Label("Open terminal here", systemImage: "terminal")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deleteProjectTarget = project
                                } label: {
                                    Label("Delete project…", systemImage: "trash")
                                }
                            }
                    }
                    chip(for: .chats, dot: groupNeedsYou(.chats))
                    Button {
                        projectEditorTarget = ProjectEditTarget(project: nil)
                    } label: {
                        Chip(title: "New project", icon: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New project")
                }
                .padding(.horizontal, ProteusTheme.Space.screen)
                .padding(.vertical, 8)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMeta)
                    .padding(.horizontal, ProteusTheme.Space.screen)
                    .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private func chip(for selection: RailSelection, dot: StatusDot.Kind?) -> some View {
        Button {
            rail = selection
            collapsed.removeAll()
        } label: {
            Chip(title: selection.title, selected: rail == selection, dot: dot)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.title)
        .accessibilityAddTraits(rail == selection ? .isSelected : [])
    }

    /// The most urgent state inside one chip: error > needs you > unread.
    private func groupNeedsYou(_ selection: RailSelection) -> StatusDot.Kind? {
        let known = Set(app.projects.map(\.name))
        let sessions: [SessionInfo]
        switch selection {
        case .all:
            sessions = app.sessions
        case .project(let name):
            sessions = app.sessions.filter { $0.project == name }
        case .chats:
            sessions = app.sessions.filter { $0.project.isEmpty || !known.contains($0.project) }
        }
        if sessions.contains(where: { $0.statusKind == .error }) { return .error }
        if sessions.contains(where: { $0.statusKind == .waiting }) { return .needsYou }
        if sessions.contains(where: { app.isUnread($0) }) { return .unread }
        return nil
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(for group: ChatGroup) -> some View {
        Section {
            if group.collapsible, collapsed.contains(group.id) {
                EmptyView()
            } else {
                ForEach(group.sessions) { session in
                    row(session)
                }
            }
        } header: {
            header(group)
        }
    }

    @ViewBuilder
    private func header(_ group: ChatGroup) -> some View {
        if group.collapsible {
            Button {
                if collapsed.contains(group.id) {
                    collapsed.remove(group.id)
                } else {
                    collapsed.insert(group.id)
                }
            } label: {
                HStack(spacing: 6) {
                    SectionLabel(text: group.title, count: group.sessions.count)
                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textMeta)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed.contains(group.id)
                ? "Show \(group.sessions.count) older chats"
                : "Hide older chats")
        } else {
            SectionLabel(text: group.title, count: group.sessions.count)
                .frame(minHeight: 32)
        }
    }

    private func row(_ session: SessionInfo) -> some View {
        NavigationLink(value: session.id) {
            ChatListRowView(session: session)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.hairline)
        .listRowInsets(EdgeInsets(top: 0, leading: ProteusTheme.Space.screen, bottom: 0, trailing: 12))
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
            Button {
                path.append(TerminalTarget.new(cwd: session.cwd))
            } label: {
                Label("Open terminal here", systemImage: "terminal")
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaletteMark(selection: UserDefaults.standard.string(forKey: "proteus.palette") ?? "blue")
                .frame(width: 96, height: 96)
                .opacity(0.9)

            if app.hasWorkstation {
                Text(search.isEmpty ? "No chats here yet" : "No matches")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(search.isEmpty
                     ? "Start one with the button above. It runs on your workstation, not on this phone."
                     : "Try a project name, a folder or a model.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                if search.isEmpty {
                    Button {
                        newChatProject = rail.projectName ?? ""
                        showNewChat = true
                    } label: {
                        Text("New chat")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
                }
            } else {
                // First run on an install that was not launched with
                // -ProteusDemo: say what the app needs and open the screen that
                // adds it, instead of pointing at a chat button that cannot work.
                Text("No workstation yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Proteus runs your chats on a machine you own. Add its address and token to start.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Button {
                    showWorkstations = true
                } label: {
                    Text("Add workstation")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, ProteusTheme.Space.screen)
        .padding(.vertical, 40)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let error = app.errorText {
                ErrorBanner(text: error) { app.errorText = nil }
            }
            if app.oldHubNotice {
                OldHubBanner { app.dismissOldHubNotice() }
            }
            if app.connection != .connected, app.hasWorkstation {
                ConnectionBanner(
                    state: app.connection,
                    hasWorkstation: app.hasWorkstation,
                    onRetry: { app.reconnect() }
                )
            }
        }
    }

    // MARK: - Demo routing

    /// `-ProteusDemoScreen=<name>` opens one screen for the CI screenshots.
    private func routeDemoIfNeeded() {
        guard app.isDemo, !didRouteDemo else { return }
        didRouteDemo = true
        switch app.demoScreen {
        case "project":
            projectEditorTarget = ProjectEditTarget(project: app.projects.first)
        case "agents":
            if let first = app.sessions.first {
                path.append(first.id)
            }
        default:
            break
        }
    }
}

// MARK: - Rail selection

enum RailSelection: Hashable {
    case all
    case project(String)
    case chats

    var title: String {
        switch self {
        case .all: return "All chats"
        case .project(let name): return name
        case .chats: return "Chats"
        }
    }

    var projectName: String? {
        if case .project(let name) = self { return name }
        return nil
    }
}

// MARK: - Row

/// One chat: dot, title, project · model, relative age. 56 pt tall, the whole
/// row tappable.
struct ChatListRowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    let session: SessionInfo

    init(session: SessionInfo) {
        self.session = session
    }

    private var unread: Bool { app.isUnread(session) }

    private var subtitle: String {
        let place = session.project.isEmpty
            ? ((session.cwd as NSString).lastPathComponent)
            : session.project
        let model = app.modelLabel(for: session.model)
        if place.isEmpty { return model }
        return model.isEmpty ? place : "\(place) · \(model)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusDot(state: theme.status(for: session.statusKind, isUnread: unread), size: 8)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled chat" : session.title)
                    .font(.system(size: 16, weight: unread ? .semibold : .regular))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textMeta)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(RelativeTime.short(iso: session.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMeta)
                if session.agentsRunning > 0 {
                    Label("\(session.agentsRunning)", systemImage: "gearshape.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(theme.textSecondary)
                } else if session.queued > 0 {
                    Label("\(session.queued)", systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [session.title.isEmpty ? "Untitled chat" : session.title]
        switch session.statusKind {
        case .running: parts.append("working")
        case .waiting: parts.append("needs you")
        case .error: parts.append("error")
        case .idle, .stopped: parts.append(unread ? "unread" : "idle")
        }
        if !subtitle.isEmpty { parts.append(subtitle) }
        let age = RelativeTime.short(iso: session.updatedAt)
        if !age.isEmpty { parts.append(age) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Project editor target

struct ProjectEditTarget: Identifiable {
    let project: ProjectDef?
    var id: String { project?.name ?? "new-project" }
}

// MARK: - Rename

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
