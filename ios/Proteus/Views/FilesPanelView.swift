import SwiftUI
import UIKit
import ProteusKit

/// Phone-native file explorer (v10 §7, v13 §2.1, v17). The root is a "Places"
/// list built from the hub's real roots (`fs.roots`: places, projects,
/// devices); folders push like Files.app with big rows, a breadcrumb, pull to
/// refresh, swipe actions and context menus, name search, New folder, Rename,
/// Delete and a text/image/Markdown preview. A hub without `fs_roots` falls
/// back to the chats' working folders, read-only.
///
/// Opened from the Files tab (Places root) and from a chat's menu (starts in
/// that chat's folder).
struct FilesPanelView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The chat whose folder to start in; nil opens the Places root.
    let chat: ChatSessionModel?
    /// True when shown as the Files tab: no Done button, and "Attach to chat"
    /// switches to the Chats tab instead of dismissing a sheet.
    let isTab: Bool

    @State private var stack: [FsRoute] = []
    @State private var seeded = false

    init(chat: ChatSessionModel? = nil, isTab: Bool = false) {
        self.chat = chat
        self.isTab = isTab
    }

    var body: some View {
        NavigationStack(path: $stack) {
            PlacesView()
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if !isTab {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .navigationDestination(for: FsRoute.self) { route in
                    switch route {
                    case .dir(let place, let path):
                        FsDirectoryView(
                            place: place, path: path, stack: $stack,
                            canAttach: attachTarget != nil, onAttach: attach
                        )
                    case .file(let place, let path):
                        FileViewerView(scope: place.scope, root: place.root, path: path) {
                            attach(place, path)
                        }
                    }
                }
        }
        .onAppear {
            if app.hasFeature("fs_roots") { app.fsLoadRoots() }
            seedIfReady()
        }
        .onChange(of: app.fsRoots) { _, _ in seedIfReady() }
    }

    /// The chat to attach to: this panel's chat, the open chat, or (from the
    /// Files tab with no chat open) the most recently active one.
    private var attachTarget: String? {
        if let id = chat?.id ?? app.activeChat?.id { return id }
        guard isTab else { return nil }
        return app.sessions.max { $0.updatedAt < $1.updatedAt }?.id
    }

    /// Start in the chat's folder: inside a hub root when one contains it (so
    /// writes work), else read-only through the chat.
    private func seedIfReady() {
        guard !seeded, let chat, let cwd = chat.session?.cwd, !cwd.isEmpty else { return }
        if let root = FsPaths.root(containing: cwd, in: app.fsRoots) {
            seeded = true
            stack = [.dir(FsPlace(scope: .root(root.id), root: root.path), cwd)]
        } else if !app.hasFeature("fs_roots") {
            seeded = true
            stack = [.dir(FsPlace(scope: .chat(chat.id), root: cwd), cwd)]
        } else if !app.fsRoots.isEmpty {
            seeded = true
            stack = [.dir(FsPlace(scope: .chat(chat.id), root: cwd), cwd)]
        }
    }

    /// "Attach to chat": an image file attaches the picture itself; anything
    /// else appends an @-reference to the draft. Then go to the chat.
    private func attach(_ place: FsPlace, _ path: String) {
        guard let target = attachTarget else {
            app.errorText = "Open a chat first to attach files to it."
            return
        }
        if isImageFile(path) {
            app.attachImageFile(scope: place.scope, path: path, chatId: target)
        } else {
            let cwd = app.sessions.first { $0.id == target }?.cwd ?? place.root
            app.insertIntoDraft("@\(relative(path, from: cwd))", for: target)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if chat == nil {
            app.pendingOpenChatId = target
        }
        if !isTab { dismiss() }
    }
}

/// A browsable root. `scope` decides the frames used; `root` is its path.
struct FsPlace: Hashable {
    let scope: FsScope
    let root: String

    var rootId: String? { scope.rootId }
}

enum FsRoute: Hashable {
    case dir(FsPlace, String)
    case file(FsPlace, String)
}

private func isImageFile(_ path: String) -> Bool {
    ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
}

// MARK: - Places root

private struct PlacesView: View {
    @EnvironmentObject private var app: AppModel

    @State private var query = ""
    @State private var searched = ""

    private struct ChatPlace: Identifiable {
        let place: FsPlace
        let chats: Int
        var id: String { place.root }
    }

    /// Pre-v17 fallback: one place per distinct chat working folder.
    private var chatPlaces: [ChatPlace] {
        let sorted = app.sessions
            .filter { !$0.cwd.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        var counts: [String: Int] = [:]
        var result: [FsPlace] = []
        for session in sorted {
            if counts[session.cwd] == nil {
                result.append(FsPlace(scope: .chat(session.id), root: session.cwd))
            }
            counts[session.cwd, default: 0] += 1
        }
        return result.map { ChatPlace(place: $0, chats: counts[$0.root] ?? 1) }
    }

    private var computer: FsRoot? {
        app.fsRoots.first { $0.id == "computer" }
    }

    var body: some View {
        Group {
            if !searched.isEmpty, let computer {
                FsSearchResults(
                    place: FsPlace(scope: .root(computer.id), root: computer.path),
                    query: searched, folder: nil
                )
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search this PC")
        .onSubmit(of: .search) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let computer else { return }
            searched = trimmed
            app.fsFind(root: computer.id, query: trimmed, path: nil)
        }
        .onChange(of: query) { _, text in
            if text.isEmpty { searched = "" }
        }
    }

    private var list: some View {
        List {
            if !app.hasFeature("fs") {
                Label("This hub is too old for files. Update the hub.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !app.fsRoots.isEmpty {
                ForEach(FsPaths.grouped(app.fsRoots), id: \.group) { group in
                    Section(groupTitle(group.group)) {
                        ForEach(group.roots) { root in
                            rootRow(root)
                        }
                    }
                }
            } else if !chatPlaces.isEmpty {
                Section("Chat folders") {
                    ForEach(chatPlaces) { item in
                        placeLink(
                            FsPlace(scope: item.place.scope, root: item.place.root),
                            symbol: "folder.fill", title: name(of: item.place.root),
                            subtitle: item.place.root,
                            trailing: item.chats > 1 ? "\(item.chats) chats" : nil
                        )
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No places yet")
                        .font(.headline)
                    Text("Pull down to load this workstation's folders.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            if app.hasFeature("fs_roots") { app.fsLoadRoots() }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    private func groupTitle(_ group: String) -> String {
        switch group {
        case "projects": return "Projects"
        case "devices": return "Devices"
        default: return "Places"
        }
    }

    private func rootRow(_ root: FsRoot) -> some View {
        var subtitle = root.path
        if let free = root.free, let total = root.total, total > 0 {
            subtitle = "\(sizeLabel(free)) free of \(sizeLabel(total))"
        }
        return placeLink(
            FsPlace(scope: .root(root.id), root: root.path),
            symbol: rootSymbol(root.icon), title: root.label, subtitle: subtitle, trailing: nil
        )
    }

    private func placeLink(_ place: FsPlace, symbol: String, title: String, subtitle: String, trailing: String?) -> some View {
        NavigationLink(value: FsRoute.dir(place, place.root)) {
            HStack(spacing: 14) {
                FsIconTile(symbol: symbol, tint: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 56)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = place.root
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
        }
    }

    private func rootSymbol(_ icon: String) -> String {
        switch icon {
        case "home": return "house.fill"
        case "desktop": return "menubar.dock.rectangle"
        case "documents": return "doc.fill"
        case "downloads": return "arrow.down.circle.fill"
        case "pictures": return "photo.fill"
        case "music": return "music.note"
        case "videos": return "film"
        case "computer": return "desktopcomputer"
        case "drive": return "externaldrive.fill"
        default: return "folder.fill"
        }
    }
}

private struct FsIconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Search results

private struct FsSearchResults: View {
    @EnvironmentObject private var app: AppModel

    let place: FsPlace
    let query: String
    let folder: String?

    private var found: FsFoundFrame? {
        guard let frame = app.fsFound, frame.root == place.rootId else { return nil }
        return frame
    }

    var body: some View {
        List {
            if let error = app.fsErrorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let found {
                if found.entries.isEmpty {
                    Text("No matches for “\(query)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(found.entries, id: \.path) { entry in
                        let full = entry.path ?? entry.name
                        NavigationLink(value: entry.dir ? FsRoute.dir(place, full) : FsRoute.file(place, full)) {
                            HStack(spacing: 14) {
                                FsIconTile(symbol: entry.dir ? "folder.fill" : "doc.text", tint: entry.dir ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(FsPaths.parent(of: full))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            .frame(minHeight: 56)
                        }
                    }
                    if found.truncated {
                        Text("Showing the first matches only. Refine the search.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - One folder

private struct FsDirectoryView: View {
    @EnvironmentObject private var app: AppModel

    let place: FsPlace
    let path: String
    @Binding var stack: [FsRoute]
    let canAttach: Bool
    let onAttach: (FsPlace, String) -> Void

    @State private var filter = ""
    @State private var searchEverywhere = false
    @State private var submitted = ""
    @State private var showHidden = false
    @State private var sortByDate = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var deleteTarget: FsEntry?

    private var listing: FsListingFrame? { app.fsListing(for: path) }

    /// Writes and search need a workstation root (never a chat scope).
    private var rootId: String? { place.rootId }

    private var entries: [FsEntry] {
        var items = listing?.entries ?? []
        if !showHidden { items = items.filter { !$0.hidden } }
        if !filter.isEmpty, submitted.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        return items.sorted { lhs, rhs in
            if lhs.dir != rhs.dir { return lhs.dir }
            if sortByDate {
                let l = Formatting.parseISO(lhs.mtime) ?? .distantPast
                let r = Formatting.parseISO(rhs.mtime) ?? .distantPast
                if l != r { return l > r }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Path segments from the place's root down to this folder.
    private var crumbs: [(label: String, path: String)] {
        var result: [(label: String, path: String)] = [(label: name(of: place.root), path: place.root)]
        let rel = relative(path, from: place.root)
        if rel != path {
            var current = place.root
            for part in rel.split(separator: "/") {
                current = join(current, String(part))
                result.append((label: String(part), path: current))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if !submitted.isEmpty, rootId != nil {
                FsSearchResults(place: place, query: submitted, folder: searchEverywhere ? nil : path)
            } else {
                folderList
            }
        }
        .navigationTitle(name(of: path))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: rootId == nil ? "Filter this folder" : "Filter or search")
        .searchScopes($searchEverywhere) {
            if rootId != nil {
                Text("This folder").tag(false)
                Text("Everywhere").tag(true)
            }
        }
        .onSubmit(of: .search) {
            let trimmed = filter.trimmingCharacters(in: .whitespaces)
            guard let rootId, !trimmed.isEmpty else { return }
            submitted = trimmed
            app.fsFind(root: rootId, query: trimmed, path: searchEverywhere ? nil : path)
        }
        .onChange(of: filter) { _, text in
            if text.isEmpty { submitted = "" }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if rootId != nil {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Label("New folder", systemImage: "folder.badge.plus")
                        }
                    }
                    Toggle(isOn: $showHidden) {
                        Label("Show hidden files", systemImage: "eye")
                    }
                    Picker("Sort", selection: $sortByDate) {
                        Label("Name", systemImage: "textformat").tag(false)
                        Label("Date modified", systemImage: "calendar").tag(true)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = path
                    } label: {
                        Label("Copy folder path", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Folder options")
            }
        }
        .onAppear {
            if listing == nil { app.fsList(scope: place.scope, path: path) }
        }
        .onChange(of: app.fsDone) { _, done in
            guard let done else { return }
            // Reload when a write landed in this folder.
            if FsPaths.parent(of: done.path) == path || done.path == path {
                app.fsList(scope: place.scope, path: path)
            }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespaces)
                if let rootId, !trimmed.isEmpty {
                    app.fsMkdir(root: rootId, path: join(path, trimmed))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let rootId, let target = renameTarget, !trimmed.isEmpty,
                   trimmed != (target as NSString).lastPathComponent {
                    app.fsRename(root: rootId, path: target, name: trimmed)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.name)”?" } ?? "Delete",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let rootId, let target = deleteTarget {
                    app.fsDelete(root: rootId, path: join(path, target.name))
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if deleteTarget?.dir == true {
                Text("The folder and everything in it will be deleted. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    private var folderList: some View {
        List {
            breadcrumb
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if let error = app.fsErrorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let listing {
                if listing.skipped {
                    note("This folder is not listed (for example .git or node_modules).")
                } else if entries.isEmpty {
                    note(filter.isEmpty ? "Empty folder" : "No matches")
                } else {
                    ForEach(entries, id: \.name) { entry in
                        row(entry)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await refresh() }
    }

    private var breadcrumb: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button {
                        stack.removeAll()
                    } label: {
                        Image(systemName: "externaldrive")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Places")
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button(crumb.label) {
                            pop(to: crumb.path)
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .disabled(index == crumbs.count - 1)
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
        }
    }

    /// Drop pushed routes until the folder `target` is on top.
    private func pop(to target: String) {
        while let last = stack.last {
            if case .dir(_, let p) = last, p == target { return }
            stack.removeLast()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowSeparator(.hidden)
    }

    private func refresh() async {
        app.fsList(scope: place.scope, path: path)
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    @ViewBuilder
    private func row(_ entry: FsEntry) -> some View {
        let full = join(path, entry.name)
        NavigationLink(value: entry.dir ? FsRoute.dir(place, full) : FsRoute.file(place, full)) {
            HStack(spacing: 14) {
                FsIconTile(symbol: symbol(for: entry), tint: tint(for: entry))
                    .opacity(entry.hidden ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 56)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if rootId != nil {
                Button(role: .destructive) {
                    deleteTarget = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    renameText = entry.name
                    renameTarget = full
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
            if canAttach {
                Button {
                    onAttach(place, full)
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                UIPasteboard.general.string = full
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            .tint(.gray)
        }
        .contextMenu {
            if canAttach {
                Button {
                    onAttach(place, full)
                } label: {
                    Label("Attach to chat", systemImage: "paperclip")
                }
            }
            if rootId != nil {
                Button {
                    renameText = entry.name
                    renameTarget = full
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            Button {
                UIPasteboard.general.string = full
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = entry.name
            } label: {
                Label("Copy name", systemImage: "textformat")
            }
            ShareLink(item: full) {
                Label("Share path", systemImage: "square.and.arrow.up")
            }
            if rootId != nil {
                Button(role: .destructive) {
                    deleteTarget = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func subtitle(_ entry: FsEntry) -> String {
        var parts: [String] = []
        if entry.dir {
            if let count = entry.count { parts.append(count == 1 ? "1 item" : "\(count) items") }
        } else {
            parts.append(sizeLabel(entry.size))
        }
        if let date = Formatting.parseISO(entry.mtime) {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if parts.isEmpty { return entry.dir ? "Folder" : "" }
        return parts.joined(separator: " · ")
    }

    private func symbol(for entry: FsEntry) -> String {
        if entry.dir { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return "photo" }
        if ["md", "markdown"].contains(ext) { return "doc.richtext" }
        if ["zip", "gz", "tar", "tgz", "xz", "7z"].contains(ext) { return "doc.zipper" }
        if ["swift", "ts", "js", "py", "rs", "go", "c", "cpp", "h", "json", "yml", "yaml", "sh", "html", "css"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc.text"
    }

    private func tint(for entry: FsEntry) -> Color {
        if entry.dir { return .accentColor }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return .pink }
        if ["md", "markdown"].contains(ext) { return .orange }
        return .secondary
    }
}

/// The in-panel viewer (v10 §7): images, Markdown preview/source, or a
/// line-numbered monospaced source view. It never writes.
struct FileViewerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let scope: FsScope
    let root: String
    let path: String
    let onAddToMessage: () -> Void

    @State private var showSource = false

    private var file: FsFileFrame? { app.fsFile(for: path) }

    private var name: String { (path as NSString).lastPathComponent }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let file {
                content(file)
            } else if let error = app.fsErrorText {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(20)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isMarkdown, file?.text != nil {
                    Button(showSource ? "Preview" : "Source") {
                        showSource.toggle()
                    }
                }
                Menu {
                    Button {
                        onAddToMessage()
                    } label: {
                        Label("Attach to chat", systemImage: "paperclip")
                    }
                    Button {
                        UIPasteboard.general.string = path
                    } label: {
                        Label("Copy path", systemImage: "doc.on.doc")
                    }
                    if let text = file?.text {
                        ShareLink(item: text) {
                            Label("Share contents", systemImage: "square.and.arrow.up")
                        }
                    } else if let base64 = file?.image, let data = Data(base64Encoded: base64),
                              let image = UIImage(data: data) {
                        ShareLink(
                            item: Image(uiImage: image),
                            preview: SharePreview(name, image: Image(uiImage: image))
                        ) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("File actions")
            }
        }
        .onAppear {
            if file == nil {
                app.fsRead(scope: scope, path: path)
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    @ViewBuilder
    private func content(_ file: FsFileFrame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(relative(file.path, from: root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(sizeLabel(file.size))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if file.truncated {
                Text("Showing the beginning of this file only.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()

            if let base64 = file.image, let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
            } else if file.binary {
                VStack(spacing: 6) {
                    Image(systemName: "doc.zipper")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Binary file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let text = file.text {
                if isMarkdown, !showSource {
                    ScrollView {
                        MarkdownText(text: text)
                            .padding(16)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(numbered(text))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("This file could not be shown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
    }

    private func numbered(_ text: String) -> String {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            String(format: "%5d  ", index + 1) + line
        }.joined(separator: "\n")
    }
}

// MARK: - Shared helpers (file private to the panel)

private func join(_ directory: String, _ name: String) -> String {
    if directory.isEmpty { return name }
    return directory.hasSuffix("/") ? directory + name : directory + "/" + name
}

private func relative(_ path: String, from root: String) -> String {
    let base = root.hasSuffix("/") ? String(root.dropLast()) : root
    if !base.isEmpty, path.hasPrefix(base + "/") {
        return String(path.dropFirst(base.count + 1))
    }
    return path
}

private func sizeLabel(_ size: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}

private func name(of path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let name = (trimmed as NSString).lastPathComponent
    return name.isEmpty ? path : name
}
