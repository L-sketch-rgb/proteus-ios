import SwiftUI
import ProteusKit

/// Chats: the project browser (docs/design/v19-ios-shell.md §2).
///
/// The tab is a 2-up grid of project tiles — pinned ones first — with the chats
/// that never got a project as one link row underneath. A chat lives inside its
/// project, so no screen lists the same chats twice and the list has nothing to
/// group.
struct ChatsHomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @AppStorage(PinnedProjects.key) private var pinnedRaw = PinnedProjects.encode([])

    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var searchPresented = false
    @State private var renameTarget: SessionInfo?
    @State private var deleteTarget: SessionInfo?
    @State private var projectEditorTarget: ProjectEditTarget?
    @State private var deleteProjectTarget: ProjectDef?
    @State private var showWorkstations = false
    @State private var didRouteDemo = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    // MARK: - Data

    private var pinned: [String] { PinnedProjects.decode(pinnedRaw) }

    private func chats(in name: String) -> [SessionInfo] {
        app.sessions.filter { $0.project == name }
    }

    private var unfiledChats: [SessionInfo] {
        let known = Set(app.projects.map(\.name))
        return app.sessions.filter { $0.project.isEmpty || !known.contains($0.project) }
    }

    private func lastUpdate(_ chats: [SessionInfo]) -> Date {
        chats.compactMap { Formatting.parseISO($0.updatedAt) }.max() ?? .distantPast
    }

    private func latest(_ chats: [SessionInfo]) -> SessionInfo? {
        chats.max { lhs, rhs in
            (Formatting.parseISO(lhs.updatedAt) ?? .distantPast)
                < (Formatting.parseISO(rhs.updatedAt) ?? .distantPast)
        }
    }

    private func needsYou(_ chats: [SessionInfo]) -> Bool {
        chats.contains { session in
            session.statusKind == .waiting || session.statusKind == .error || app.isUnread(session)
        }
    }

    /// Pinned projects in pin order, then everything else by last activity.
    private var orderedProjects: [ProjectDef] {
        var byName: [String: ProjectDef] = [:]
        for project in app.projects { byName[project.name] = project }
        var out: [ProjectDef] = []
        for name in pinned {
            if let project = byName.removeValue(forKey: name) { out.append(project) }
        }
        let rest = byName.values.sorted { lastUpdate(chats(in: $0.name)) > lastUpdate(chats(in: $1.name)) }
        return out + rest
    }

    private var pinnedProjects: [ProjectDef] {
        let pins = pinned
        return orderedProjects.filter { pins.contains($0.name) }
    }

    private var otherProjects: [ProjectDef] {
        let pins = pinned
        return orderedProjects.filter { !pins.contains($0.name) }
    }

    private var showsEmptyState: Bool {
        search.isEmpty && app.projects.isEmpty && unfiledChats.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if showsEmptyState {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    panel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenWave()
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .chromeToolbar(theme)
            .searchable(
                text: $search,
                isPresented: $searchPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search all chats"
            )
            .safeAreaInset(edge: .bottom, spacing: 0) { banners }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        searchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search chats")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(NewChatTarget())
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .navigationDestination(for: NewChatTarget.self) { target in
                ChatView(chat: app.draftChat(for: target))
            }
            .navigationDestination(for: String.self) { id in
                ChatView(chat: app.chatModel(for: id))
            }
            .navigationDestination(for: TerminalTarget.self) { target in
                TerminalScreen(target: target)
            }
            .navigationDestination(for: ChatScope.self) { scope in
                ProjectChatsView(scope: scope)
            }
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
            path.append(id)
        }
        .onAppear {
            DispatchQueue.main.async { routeDemoIfNeeded() }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if search.isEmpty {
                    tiles
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(theme.readingSurface)
        .clipShape(panelShape)
        .overlay { panelShape.strokeBorder(theme.rim, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Tiles

    @ViewBuilder
    private var tiles: some View {
        if !pinnedProjects.isEmpty {
            SectionLabel(text: "Pinned")
                .padding(.horizontal, 6)
            projectGrid(pinnedProjects)
        }

        SectionLabel(text: "Projects")
            .padding(.horizontal, 6)

        if otherProjects.isEmpty {
            Text("No projects yet.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textMeta)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
        } else {
            projectGrid(otherProjects)
        }

        newProjectTile
        unfiledRow
    }

    /// `＋` in the nav asks a question now; making a project lives here, in the
    /// grid of projects (D57).
    private var newProjectTile: some View {
        Button {
            projectEditorTarget = ProjectEditTarget(project: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("New project")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.rim, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New project")
    }

    private func projectGrid(_ projects: [ProjectDef]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(projects) { project in
                tile(project)
            }
        }
    }

    private func tile(_ project: ProjectDef) -> some View {
        let list = chats(in: project.name)
        let newest = latest(list)
        let isPinned = pinned.contains(project.name)
        return NavigationLink(value: ChatScope.project(project.name)) {
            ProjectTile(
                name: project.name,
                chats: list.count,
                age: newest.map { RelativeTime.short(iso: $0.updatedAt) } ?? "",
                lastTitle: newest?.title ?? "",
                needsYou: needsYou(list),
                isPinned: isPinned
            )
        }
        .buttonStyle(.plain)
        .contextMenu { projectMenu(project) }
    }

    private var unfiledRow: some View {
        NavigationLink(value: ChatScope.unfiled) {
            HStack(spacing: 8) {
                Text("Unfiled chats")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
                Text("\(unfiledChats.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMeta)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textMeta)
            }
            .frame(height: 48)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(theme.hairline).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        let listing = app.filteredListing(search: search)
        let all = listing.projects.flatMap(\.sessions) + listing.chats
        if all.isEmpty {
            Text("No matches")
                .font(.system(size: 13))
                .foregroundStyle(theme.textMeta)
                .padding(.horizontal, 6)
                .padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(all.enumerated()), id: \.element.id) { index, session in
                    searchRow(session, first: index == 0)
                }
            }
        }
    }

    private func searchRow(_ session: SessionInfo, first: Bool) -> some View {
        NavigationLink(value: session.id) {
            ChatListRowView(session: session, showsProject: true)
                .padding(.horizontal, 8)
                .frame(height: 62)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { chatMenu(session) }
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 1)
                    .padding(.leading, 26)
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func chatMenu(_ session: SessionInfo) -> some View {
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
        if session.statusKind == .running || session.statusKind == .waiting {
            Button {
                app.stop(session)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = session
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: ProjectDef) -> some View {
        Button {
            togglePin(project)
        } label: {
            Label(pinned.contains(project.name) ? "Unpin" : "Pin",
                  systemImage: pinned.contains(project.name) ? "pin.slash" : "pin")
        }
        Button {
            path.append(NewChatTarget(project: project.name))
        } label: {
            Label("New chat here", systemImage: "plus.bubble")
        }
        Button {
            path.append(TerminalTarget.new(cwd: project.cwd ?? ""))
        } label: {
            Label("Open terminal here", systemImage: "terminal")
        }
        Button {
            projectEditorTarget = ProjectEditTarget(project: project)
        } label: {
            Label("Project settings…", systemImage: "slider.horizontal.3")
        }
        Divider()
        Button(role: .destructive) {
            deleteProjectTarget = project
        } label: {
            Label("Delete project…", systemImage: "trash")
        }
    }

    private func togglePin(_ project: ProjectDef) {
        var pins = pinned
        if let index = pins.firstIndex(of: project.name) {
            pins.remove(at: index)
        } else {
            pins.insert(project.name, at: 0)
        }
        if pins.count > PinnedProjects.maximum {
            pins = Array(pins.prefix(PinnedProjects.maximum))
        }
        pinnedRaw = PinnedProjects.encode(pins)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaletteMark(selection: UserDefaults.standard.string(forKey: "proteus.palette") ?? "blue")
                .frame(width: 96, height: 96)
                .opacity(0.9)

            if app.hasWorkstation {
                Text("No projects or chats yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Start one with ＋. It runs on your workstation, not on this phone.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Button {
                    path.append(NewChatTarget())
                } label: {
                    Text("New chat")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
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
        case "unfiled":
            path.append(ChatScope.unfiled)
        case "projectchats":
            if let name = app.projects.first?.name {
                path.append(ChatScope.project(name))
            }
        case "agents":
            if let first = app.sessions.first {
                path.append(first.id)
            }
        case "newchat":
            path.append(NewChatTarget(project: app.projects.first?.name ?? ""))
        default:
            break
        }
    }
}

// MARK: - Tile

/// One project tile: name, active chat count with an amber dot when something
/// needs you, and the last chat's title. 100 pt tall, the whole tile is the
/// target.
struct ProjectTile: View {
    @Environment(\.proteusTheme) private var theme

    let name: String
    let chats: Int
    let age: String
    let lastTitle: String
    let needsYou: Bool
    let isPinned: Bool

    private var countLine: String {
        if chats == 0 { return "no chats" }
        let noun = chats == 1 ? "chat" : "chats"
        return age.isEmpty ? "\(chats) \(noun)" : "\(chats) \(noun) · \(age)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textMeta)
                }
            }

            HStack(spacing: 6) {
                if needsYou {
                    Circle()
                        .fill(theme.statusNeedsYou)
                        .frame(width: 6, height: 6)
                }
                Text(countLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textMeta)
                    .lineLimit(1)
            }
            .padding(.top, 3)

            Spacer(minLength: 8)

            Text(chats == 0 ? "no chats yet" : lastTitle)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isPinned ? theme.rim : theme.hairline, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(countLine)\(needsYou ? ", needs you" : "")")
    }
}

// MARK: - Chat row

/// One chat: dot, title, project · model, relative age. 56 pt tall, the whole
/// row tappable.
struct ChatListRowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    let session: SessionInfo
    /// Inside a project the project is implied, so only the model is shown.
    var showsProject: Bool

    init(session: SessionInfo, showsProject: Bool = true) {
        self.session = session
        self.showsProject = showsProject
    }

    private var unread: Bool { app.isUnread(session) }

    private var subtitle: String {
        let model = app.modelLabel(for: session.model)
        guard showsProject else { return model }
        let place = session.project.isEmpty
            ? ((session.cwd as NSString).lastPathComponent)
            : session.project
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
