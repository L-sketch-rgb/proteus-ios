import SwiftUI
import ProteusKit

/// Which bucket of chats a pushed screen shows (docs/design/v19-ios-shell.md
/// §2.1, §2.2).
enum ChatScope: Hashable {
    case project(String)
    case unfiled

    var title: String {
        switch self {
        case .project(let name): return name
        case .unfiled: return "Unfiled chats"
        }
    }

    var isUnfiled: Bool {
        if case .unfiled = self { return true }
        return false
    }
}

/// One bucket's chats: a project's, or the ones that never got a project.
///
/// Both screens are the same list — the project's folder path on top, then
/// Needs you / Active / Older — because the difference between "the chats in
/// Proteus" and "the chats in no project at all" is only which rows come back.
struct ProjectChatsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    let scope: ChatScope

    @State private var collapsed: Set<String> = []
    @State private var renameTarget: SessionInfo?
    @State private var deleteTarget: SessionInfo?

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var project: ProjectDef? {
        if case .project(let name) = scope {
            return app.projects.first { $0.name == name }
        }
        return nil
    }

    private var chats: [SessionInfo] {
        switch scope {
        case .project(let name):
            return app.sessions.filter { $0.project == name }
        case .unfiled:
            let known = Set(app.projects.map(\.name))
            return app.sessions.filter { $0.project.isEmpty || !known.contains($0.project) }
        }
    }

    private var groups: [ChatGroup] {
        ChatGroups.groups(
            for: chats,
            scope: scope.isUnfiled ? .oneOff : .project,
            lastSeen: { app.lastSeenAt($0) }
        )
    }

    var body: some View {
        List {
            if let cwd = project?.cwd, !cwd.isEmpty {
                pathRow(cwd)
            }

            if chats.isEmpty {
                Text(scope.isUnfiled ? "No unfiled chats" : "No chats in this project yet")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMeta)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } else {
                ForEach(groups) { group in
                    Section {
                        if !(group.collapsible && collapsed.contains(group.id)) {
                            ForEach(group.sessions) { session in
                                row(session)
                            }
                        }
                    } header: {
                        header(group)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(theme.readingSurface)
        .clipShape(panelShape)
        .overlay { panelShape.strokeBorder(theme.rim, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .screenWave()
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .chromeToolbar(theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: NewChatTarget(project: project?.name ?? "")) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
            }
        }
        .themedSheet(item: $renameTarget) { session in
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
    }

    // MARK: - Pieces

    private func pathRow(_ cwd: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMeta)
            Text(cwd)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textMeta)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.hairline)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
            ChatListRowView(session: session, showsProject: scope.isUnfiled)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.hairline)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
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
    }
}
