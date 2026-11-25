import SwiftUI
import UIKit
import ProteusKit

/// v10 §7 on iPhone: the chat's working folder as a read-only sheet, with
/// lazily loaded folders, pinned project files and a file viewer. The hub
/// enforces that every path is inside the chat's cwd (or a project folder).
struct FilesPanelView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let chat: ChatSessionModel

    @State private var path: [String] = []
    @State private var filter = ""
    @State private var expanded: Set<String> = []

    private var root: String {
        chat.session?.cwd ?? ""
    }

    private var rootListing: FsListingFrame? {
        guard !root.isEmpty else { return nil }
        return app.fsListing(for: root)
    }

    private var rootEntries: [FsEntry] {
        sorted(rootListing?.entries ?? [])
    }

    /// Pinned files that actually exist in the root listing (v10 §7).
    private var pinnedPaths: [String] {
        guard let rootListing else { return [] }
        let rootNames = Set(rootListing.entries.map(\.name))
        var paths: [String] = []
        for name in ["CLAUDE.md", "README.md"] where rootNames.contains(name) {
            paths.append(name)
        }
        if rootNames.contains("docs"), let docs = app.fsListing(for: join(root, "docs")) {
            let names = Set(docs.entries.map(\.name))
            for name in ["STATE.md", "PLAN.md", "DECISIONS.md"] where names.contains(name) {
                paths.append("docs/" + name)
            }
        }
        return paths
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = app.fsErrorText {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }

                    if !pinnedPaths.isEmpty {
                        sectionLabel("Pinned")
                        ForEach(pinnedPaths, id: \.self) { relative in
                            pinnedRow(relative)
                        }
                    }

                    sectionLabel(root.isEmpty ? "No working folder" : name(of: root))

                    if let listing = rootListing {
                        if listing.skipped {
                            skippedRow
                        } else if listing.entries.isEmpty {
                            Text("Empty folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(visible(rootEntries, in: root), id: \.name) { entry in
                                FsNodeRow(
                                    chatId: chat.id,
                                    root: root,
                                    parentPath: root,
                                    entry: entry,
                                    depth: 0,
                                    filter: filter,
                                    expanded: $expanded,
                                    onOpen: open
                                )
                            }
                        }
                    } else if root.isEmpty {
                        Text("This chat does not report a working folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $filter,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Filter files"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh files")
                }
            }
            .navigationDestination(for: String.self) { filePath in
                FileViewerView(chatId: chat.id, root: root, path: filePath) {
                    app.insertIntoDraft("@\(relative(filePath, from: root))", for: chat.id)
                    dismiss()
                }
            }
            .onKeyPress(.escape) {
                guard path.isEmpty else {
                    path.removeLast()
                    return .handled
                }
                dismiss()
                return .handled
            }
            .onChange(of: app.fsListings.count) { _, _ in
                loadDocsIfNeeded()
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !root.isEmpty else { return }
        app.fsList(chatId: chat.id, path: root)
        loadDocsIfNeeded()
    }

    private func loadDocsIfNeeded() {
        guard let listing = rootListing,
              listing.entries.contains(where: { $0.dir && $0.name == "docs" }) else { return }
        let docs = join(root, "docs")
        if app.fsListing(for: docs) == nil {
            app.fsList(chatId: chat.id, path: docs)
        }
    }

    private func refresh() {
        guard !root.isEmpty else { return }
        app.fsList(chatId: chat.id, path: root)
        for directory in expanded {
            app.fsList(chatId: chat.id, path: directory)
        }
    }

    private func open(_ filePath: String) {
        path.append(filePath)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func pinnedRow(_ relativePath: String) -> some View {
        let filePath = join(root, relativePath)
        return Button {
            path.append(filePath)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(relativePath)
                    .font(.callout)
                Spacer(minLength: 8)
                if let file = app.fsFile(for: filePath), file.size > 0 {
                    Text(sizeLabel(file.size))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var skippedRow: some View {
        Text("This folder is not listed (for example .git or node_modules).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    /// Filter matches a name, or a directory with a matching loaded descendant.
    private func visible(_ entries: [FsEntry], in directory: String) -> [FsEntry] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { entry in
            matches(entry, in: directory)
        }
    }

    private func matches(_ entry: FsEntry, in directory: String) -> Bool {
        if entry.name.localizedCaseInsensitiveContains(filter) { return true }
        guard entry.dir else { return false }
        let childPath = join(directory, entry.name)
        guard let listing = app.fsListing(for: childPath) else { return false }
        return listing.entries.contains { matches($0, in: childPath) }
    }

    private func sorted(_ entries: [FsEntry]) -> [FsEntry] {
        entries.sorted { lhs, rhs in
            if lhs.dir != rhs.dir { return lhs.dir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// One tree row. Folders load lazily on first expand; a skipped folder shows a
/// muted line instead of an empty list.
private struct FsNodeRow: View {
    @EnvironmentObject private var app: AppModel

    let chatId: String
    let root: String
    let parentPath: String
    let entry: FsEntry
    let depth: Int
    let filter: String
    @Binding var expanded: Set<String>
    let onOpen: (String) -> Void

    private var fullPath: String { join(parentPath, entry.name) }

    private var isExpanded: Bool { expanded.contains(fullPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if entry.dir {
                    toggle()
                } else {
                    onOpen(fullPath)
                }
            } label: {
                HStack(spacing: 8) {
                    Color.clear.frame(width: CGFloat(depth) * 16 + 2, height: 1)
                    Image(systemName: entry.dir ? (isExpanded ? "chevron.down" : "chevron.right") : " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(entry.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(entry.hidden ? 0.55 : 1)
                    if entry.hidden {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if !entry.dir {
                        Text(sizeLabel(entry.size))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if entry.dir, isExpanded {
                children
            }
        }
    }

    @ViewBuilder
    private var children: some View {
        if let listing = app.fsListing(for: fullPath) {
            if listing.skipped {
                Text("Not listed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth) * 16 + 52)
                    .padding(.vertical, 8)
            } else if listing.entries.isEmpty {
                Text("Empty")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth) * 16 + 52)
                    .padding(.vertical, 8)
            } else {
                ForEach(visible(listing.entries), id: \.name) { child in
                    FsNodeRow(
                        chatId: chatId,
                        root: root,
                        parentPath: fullPath,
                        entry: child,
                        depth: depth + 1,
                        filter: filter,
                        expanded: $expanded,
                        onOpen: onOpen
                    )
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, CGFloat(depth) * 16 + 52)
                .padding(.vertical, 8)
        }
    }

    private func toggle() {
        if isExpanded {
            expanded.remove(fullPath)
        } else {
            expanded.insert(fullPath)
            if app.fsListing(for: fullPath) == nil {
                app.fsList(chatId: chatId, path: fullPath)
            }
        }
    }

    private func visible(_ entries: [FsEntry]) -> [FsEntry] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.dir != rhs.dir { return lhs.dir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        guard !filter.isEmpty else { return sorted }
        return sorted.filter { child in
            child.name.localizedCaseInsensitiveContains(filter)
                || (child.dir && hasMatchBelow(child))
        }
    }

    private func hasMatchBelow(_ child: FsEntry) -> Bool {
        let childPath = join(fullPath, child.name)
        guard let listing = app.fsListing(for: childPath) else { return false }
        return listing.entries.contains { descendant in
            descendant.name.localizedCaseInsensitiveContains(filter)
                || (descendant.dir && hasMatchBelow(childPath: childPath, entry: descendant))
        }
    }

    private func hasMatchBelow(childPath: String, entry: FsEntry) -> Bool {
        let next = join(childPath, entry.name)
        guard let listing = app.fsListing(for: next) else { return false }
        return listing.entries.contains { descendant in
            descendant.name.localizedCaseInsensitiveContains(filter)
                || (descendant.dir && hasMatchBelow(childPath: next, entry: descendant))
        }
    }

    private var icon: String {
        if entry.dir { return isExpanded ? "folder.fill" : "folder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return "photo" }
        if ["md", "markdown"].contains(ext) { return "doc.richtext" }
        return "doc.text"
    }
}

/// The in-panel viewer (v10 §7): images, Markdown preview/source, or a
/// line-numbered monospaced source view. It never writes.
struct FileViewerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let chatId: String
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
                        Label("Add to message", systemImage: "text.bubble")
                    }
                    Button {
                        UIPasteboard.general.string = path
                    } label: {
                        Label("Copy path", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("File actions")
            }
        }
        .onAppear {
            if file == nil {
                app.fsRead(chatId: chatId, path: path)
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
