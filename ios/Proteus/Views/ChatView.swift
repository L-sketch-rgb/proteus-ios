import SwiftUI
import UIKit
import ProteusKit

struct ChatView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.proteusTheme) private var theme
    @ObservedObject var chat: ChatSessionModel
    @AppStorage("proteus.palette") private var paletteKey = "blue"
    @Environment(\.paletteAccent) private var accent

    @State private var atBottom = true
    @State private var didInitialScroll = false
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .agents
    @State private var showFiles = false
    /// v10 §13: the row a pin scrolled to, briefly outlined.
    @State private var highlightRowId: String?
    @State private var highlightOpacity: Double = 0
    @State private var renameTarget: SessionInfo?
    @State private var deleteTarget: SessionInfo?
    @State private var showMoveDialog = false
    @State private var scrollTargetId: String?
    @State private var didOpenDemoAgents = false
    /// v10 §12: first visible row and the count of rows added since scrolling up.
    @State private var anchorRowId: String?
    @State private var newSinceScrollUp = 0
    @State private var lastSeenEntryCount = 0

    private var selectedModel: String {
        chat.session?.model ?? app.defaultModel
    }

    private var currentMode: String {
        chat.session?.mode ?? "default"
    }

    private var modeLabel: String {
        switch currentMode {
        case "acceptEdits": return "Accept edits"
        case "plan": return "Plan"
        case "auto": return "Auto"
        default: return "Ask"
        }
    }

    private var unavailableReason: String? {
        guard let model = app.models.first(where: { $0.id == selectedModel }) else { return nil }
        guard !model.available else { return nil }
        switch model.unavailableReason {
        case "credits": return "This model needs usage credits on the active account."
        case .some(let reason) where !reason.isEmpty: return reason
        default: return "This model is not available on the active account."
        }
    }

    var body: some View {
        GeometryReader { outer in
            VStack(spacing: 0) {
                chatHeaderStrip
                if let error = app.errorText {
                    ErrorBanner(text: error) { app.errorText = nil }
                }
                if app.oldHubNotice {
                    OldHubBanner { app.dismissOldHubNotice() }
                }
                if app.connection != .connected {
                    ConnectionBanner(
                        state: app.connection,
                        hasWorkstation: app.hasWorkstation,
                        onRetry: { app.reconnect() }
                    )
                }
                transcript(outer: outer)

                if app.modelUnavailableChatId == chat.id {
                    modelUnavailableNotice
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }

                if !chat.permissions.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(chat.permissions) { request in
                            // v10 §15.1: a hub without "questions" shows the
                            // plain permission card for these two tools.
                            if request.tool == "AskUserQuestion", app.hasFeature("questions") {
                                QuestionCardView(request: request)
                            } else if request.tool == "ExitPlanMode", app.hasFeature("questions") {
                                PlanCardView(request: request)
                            } else {
                                PermissionCard(request: request)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }

                ComposerView(chat: chat)
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .screenWave()
        .chromeToolbar(theme)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chat.title.isEmpty ? "Chat" : chat.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let project = chat.session?.project, !project.isEmpty {
                        Text(project)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 220)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(!app.hasFeature("fs"))
                    .accessibilityHint(app.hasFeature("fs") ? "" : "Needs a newer hub")
                    Button {
                        showInspector = true
                        inspectorTab = .terminal
                    } label: {
                        Label("New terminal here", systemImage: "terminal")
                    }
                    Divider()
                    Button {
                        if let session = chat.session { renameTarget = session }
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    Button {
                        showMoveDialog = true
                    } label: {
                        Label("Move to project…", systemImage: "folder.badge.gearshape")
                    }
                    Button(role: .destructive) {
                        if let session = chat.session { deleteTarget = session }
                    } label: {
                        Label("Delete chat…", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                        if chat.runningTasks > 0 {
                            Text("\(chat.runningTasks)")
                                .font(.caption2.weight(.bold))
                        }
                    }
                }
                .accessibilityLabel("Chat actions")
            }
        }
        .sheet(isPresented: $showInspector) {
            InspectorSheet(
                chat: chat,
                tab: $inspectorTab,
                onAgent: { task in
                    let target = rowId(for: task)
                    showInspector = false
                    guard let target else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        scrollTargetId = target
                    }
                },
                onPin: { pin in
                    showInspector = false
                    selectPin(pin)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFiles) {
            FilesPanelView(chat: chat)
        }
        .sheet(item: $renameTarget) { session in
            RenameChatSheet(session: session)
        }
        .confirmationDialog("Move to project", isPresented: $showMoveDialog, titleVisibility: .visible) {
            Button("None") {
                if let session = chat.session { app.move(session, toProject: "") }
            }
            ForEach(app.projects) { project in
                Button(project.name) {
                    if let session = chat.session { app.move(session, toProject: project.name) }
                }
            }
            Button("Cancel", role: .cancel) {}
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
            Text("“\(session.title)” and its transcript are removed from the hub.")
        }
        .onAppear {
            app.attach(chat)
            app.openSession(chat.id)
            // v18 §3.5a: this chat counts as seen while it is open.
            app.markSeen(chat.id)
            if app.isDemo, app.demoScreen == "agents", !didOpenDemoAgents {
                didOpenDemoAgents = true
                DispatchQueue.main.async {
                    inspectorTab = .agents
                    showInspector = true
                }
            }
        }
        .onDisappear {
            app.detach(chat)
            app.markSeen(chat.id)
            if app.removedChatId != chat.id {
                app.closeSession(chat.id)
            }
        }
        .onChange(of: chat.session?.updatedAt) { _, _ in
            // Streaming keeps the row read without leaving the chat.
            app.markSeen(chat.id)
        }
        .onChange(of: app.removedChatId) { _, id in
            if id == chat.id {
                dismiss()
            }
        }
    }

    private var chatsRunningLabel: String {
        chat.runningTasks > 0 ? "Agents (\(chat.runningTasks) running)" : "Agents"
    }

    /// v18 §5.1: the desktop's header strip, phone-sized. One control for model
    /// and mode, one for the inspector; everything rare stays in ⋯.
    private var chatHeaderStrip: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Mode") {
                    ForEach(Self.modeOptions) { option in
                        Button {
                            app.setMode(option.id)
                        } label: {
                            Text((currentMode == option.id ? "✓ " : "") + option.label)
                        }
                    }
                }
                ForEach(app.modelMenu.sections) { section in
                    Section(section.title) {
                        ForEach(section.models) { model in
                            Button {
                                app.setModel(model.id)
                            } label: {
                                Text((model.id == selectedModel ? "✓ " : "") + model.label)
                            }
                        }
                    }
                }
                if !app.modelMenu.more.isEmpty {
                    Section("More") {
                        ForEach(app.modelMenu.more) { section in
                            ForEach(section.models) { model in
                                Button {
                                    app.setModel(model.id)
                                } label: {
                                    Text("\(section.title) · \(model.label)")
                                }
                                .disabled(!model.available)
                            }
                        }
                    }
                }
            } label: {
                Chip(
                    title: "\(app.modelLabel(for: selectedModel)) · \(modeLabel)",
                    icon: "shield.lefthalf.filled"
                )
            }
            .accessibilityLabel("Model and mode: \(app.modelLabel(for: selectedModel)), \(modeLabel)")

            Button {
                if chat.runningTasks > 0 { inspectorTab = .agents }
                showInspector = true
            } label: {
                Chip(
                    title: "Inspector",
                    dot: chat.runningTasks > 0 ? .working : nil,
                    icon: "sidebar.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspector")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ProteusTheme.Space.gutter)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var modelUnavailableNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Model unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(unavailableReason ?? "This model is not available on the active account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Use \(app.modelLabel(for: app.defaultModel))") {
                    app.useDefaultModelAndResend()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 14)
    }

    private func transcript(outer: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.rows.isEmpty {
                        EmptyChatHero(paletteKey: paletteKey)
                    }

                    ForEach(chat.rows) { row in
                        if !(row.kind == .tool && !row.groupId.isEmpty && !row.groupExpanded) {
                            ChatRowView(row: row, chat: chat)
                                .id(row.id)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: RowFrameKey.self,
                                            value: [row.id: geometry.frame(in: .named("chatScroll"))]
                                        )
                                    }
                                )
                                // v10 §13: a brief accent outline after a pin
                                // scrolls to its item.
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(accent, lineWidth: 2)
                                        .opacity(highlightRowId == row.id ? highlightOpacity : 0)
                                        .allowsHitTesting(false)
                                )
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomVisibleKey.self,
                                    value: geometry.frame(in: .named("chatScroll")).maxY <= outer.size.height + 24
                                )
                            }
                        )
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .coordinateSpace(name: "chatScroll")
            .onPreferenceChange(BottomVisibleKey.self) { visible in
                if visible != atBottom {
                    atBottom = visible
                    if visible {
                        lastSeenEntryCount = chat.entryCount
                    } else {
                        // v10 §12: remember where the user was when they left
                        // the bottom, for per-chat restore and the "N new" pill.
                        lastSeenEntryCount = chat.entryCount
                    }
                }
            }
            .onPreferenceChange(RowFrameKey.self) { frames in
                // v10 §12: the first row at least partly inside the viewport is
                // the anchor. Only tracked while scrolled up.
                guard !atBottom else { return }
                let visible = frames.filter { entry in
                    entry.value.maxY > 1 && entry.value.minY < outer.size.height
                }
                if let top = visible.min(by: { $0.value.minY < $1.value.minY }) {
                    anchorRowId = top.key
                }
            }
            .onChange(of: chat.contentVersion) { _, _ in
                if atBottom {
                    newSinceScrollUp = 0
                    lastSeenEntryCount = chat.entryCount
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    // Frozen: no auto-scroll. Just count what arrived.
                    newSinceScrollUp = max(0, chat.entryCount - lastSeenEntryCount)
                }
            }
            .onChange(of: chat.rows.count) { _, _ in
                // A structural change (a tool group expanding, new cards) can
                // move the content while scrolled up. Anchor the first visible
                // row again after layout.
                guard !atBottom, let anchorRowId else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorRowId, anchor: .top)
                }
            }
            .onChange(of: scrollTargetId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                // v10 §13: the item gets an accent outline fading over 1.5 s.
                highlightRowId = id
                highlightOpacity = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 1.5)) { highlightOpacity = 0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if highlightRowId == id { highlightRowId = nil }
                }
                scrollTargetId = nil
            }
            .onAppear {
                guard !didInitialScroll else { return }
                didInitialScroll = true
                // v10 §12: coming back to a chat restores where it was left
                // (per chat, in memory); otherwise follow the bottom.
                if let anchor = chat.scrollAnchorId, !chat.scrollAtBottom {
                    atBottom = false
                    lastSeenEntryCount = chat.entryCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                } else {
                    atBottom = true
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onDisappear {
                chat.scrollAnchorId = atBottom ? nil : anchorRowId
                chat.scrollAtBottom = atBottom
                chat.scrollLastSeenCount = lastSeenEntryCount
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        atBottom = true
                        newSinceScrollUp = 0
                        lastSeenEntryCount = chat.entryCount
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                            if newSinceScrollUp > 0 {
                                Text("\(newSinceScrollUp) new")
                                    .font(.caption2.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .glassCard(cornerRadius: 18)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .accessibilityLabel(
                        newSinceScrollUp > 0 ? "Jump to latest, \(newSinceScrollUp) new" : "Jump to latest"
                    )
                }
            }
        }
    }

    /// v10 §13: close the pins sheet, expand a collapsed group if needed and
    /// scroll to the pinned row. The chat already holds the full history on
    /// iOS, so there is no older page to load.
    private func selectPin(_ pin: Pin) {
        guard let row = chat.row(for: pin) else { return }
        if !row.groupId.isEmpty && !row.groupExpanded {
            chat.expandGroup(containingRowId: row.id)
        }
        let target = row.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollTargetId = target
        }
    }

    /// The transcript row that shows a sub-agent's tool card, for tapping an
    /// agent in the sheet.
    private func rowId(for task: TaskData) -> String? {
        chat.rows.last { row in
            if row.task?.taskId == task.taskId { return true }
            if let toolUseId = task.toolUseId, !toolUseId.isEmpty, row.toolId == toolUseId {
                return true
            }
            return false
        }?.id
    }

    private struct ModeOption: Identifiable {
        let id: String
        let label: String
    }

    private static let modeOptions: [ModeOption] = [
        ModeOption(id: "default", label: "Ask"),
        ModeOption(id: "acceptEdits", label: "Accept edits"),
        ModeOption(id: "plan", label: "Plan"),
        ModeOption(id: "auto", label: "Auto"),
    ]
}

private struct BottomVisibleKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

/// v10 §12: row id → frame in the transcript viewport. The topmost row that is
/// at least partly visible is the scroll anchor while the user is scrolled up.
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct EmptyChatHero: View {
    let paletteKey: String

    var body: some View {
        VStack(spacing: 14) {
            PaletteMark(selection: paletteKey)
                .frame(width: 96, height: 96)
                .opacity(0.9)
            Text("Ask anything")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }
}

// MARK: - Rows

struct ChatRowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.paletteAccent) private var accent

    let row: ChatRow
    let chat: ChatSessionModel

    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        Group {
            switch row.kind {
            case .user:
                userRow

            case .assistant:
                VStack(alignment: .leading, spacing: 3) {
                    MarkdownText(text: row.text)
                    // v10 §3/§13: the assistant's time once per turn, with a
                    // filled pin whenever this row is pinned.
                    let pinned = app.pin(for: row, chatId: chat.id) != nil
                    if pinned || !row.timestamp.isEmpty {
                        HStack(spacing: 6) {
                            if pinned { PinnedBadge() }
                            if !row.timestamp.isEmpty {
                                Text(row.timestamp)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    PinMenuButton(row: row, chatId: chat.id)
                }

            case .thinking:
                ThinkingRow(text: row.text)

            case .tool:
                ToolCardView(row: row, chat: chat)

            case .toolgroup:
                ToolGroupRowView(row: row, chat: chat)

            case .error:
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.text)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !row.timestamp.isEmpty {
                        Text(row.timestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(ChatColors.errorFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            case .notice:
                NoticeRowView(row: row)
            }
        }
        .padding(.leading, row.nested ? 18 : (row.groupId.isEmpty ? 0 : 14))
    }

    @ViewBuilder
    private var userRow: some View {
        if editing {
            VStack(alignment: .trailing, spacing: 6) {
                TextField("Message", text: $editText, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .onKeyPress(.escape) {
                        editing = false
                        return .handled
                    }
                    .onSubmit(sendEdit)
                if row.images > 0 {
                    Text("Attached images are not re-sent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Send", action: sendEdit)
                        .fontWeight(.semibold)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(row.text)
                        .textSelection(.enabled)
                    if row.images > 0 {
                        Label("\(row.images) image\(row.images == 1 ? "" : "s")", systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        // v10 §13: a pinned row keeps a small filled pin.
                        if app.pin(for: row, chatId: chat.id) != nil {
                            PinnedBadge()
                        }
                        // v10 §11: the original stays in place, marked as edited.
                        if row.edited {
                            Text("edited ↓")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !row.timestamp.isEmpty {
                            Text(row.timestamp)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .contextMenu {
                PinMenuButton(row: row, chatId: chat.id)
                Divider()
                Button {
                    editText = row.text
                    editing = true
                } label: {
                    Label("Edit and resend", systemImage: "pencil")
                }
                .disabled(!app.hasFeature("resend"))
                .accessibilityHint(app.hasFeature("resend") ? "" : "Needs a newer hub")
            }
        }
    }

    private func sendEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // v10 §11: a new prompt replaces the turn; the original keeps its place.
        app.resend(chatId: chat.id, text: text)
        chat.markEdited(rowId: row.id)
        editing = false
    }
}

/// v10 §13: the Pin / Unpin action shared by every pinnable row's menu.
struct PinMenuButton: View {
    @EnvironmentObject private var app: AppModel
    let row: ChatRow
    let chatId: String

    private var pinned: Pin? {
        app.pin(for: row, chatId: chatId)
    }

    var body: some View {
        if row.pinKind != nil {
            Button {
                app.togglePin(row: row, chatId: chatId)
            } label: {
                Label(pinned == nil ? "Pin" : "Unpin", systemImage: pinned == nil ? "pin" : "pin.slash")
            }
            .disabled(!app.hasFeature("pins"))
            .accessibilityHint(app.hasFeature("pins") ? "" : "Needs a newer hub")
        }
    }
}

/// v10 §13: a small filled pin on a pinned row.
struct PinnedBadge: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Pinned")
    }
}

/// v10 §2: one flat row for a run of tool cards. Tap to expand the cards.
struct ToolGroupRowView: View {
    @EnvironmentObject private var app: AppModel
    let row: ChatRow
    let chat: ChatSessionModel

    var body: some View {
        Button {
            chat.toggleGroup(row.groupId)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    Text("\(row.groupCount) \(row.groupLabel)")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    if app.pin(for: row, chatId: chat.id) != nil {
                        PinnedBadge()
                    }
                    if !row.groupSpan.isEmpty {
                        Text(row.groupSpan)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: row.groupExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(row.groupSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if row.groupRunning {
                        Text("running")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if row.groupStopped {
                        // v10 §16: stopped, not failed.
                        Text("stopped")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if row.groupFailed > 0 {
                        Text("\(row.groupFailed) failed")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if !row.groupLatest.isEmpty {
                    Text(row.groupLatest)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(ChatColors.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(row.groupCount) \(row.groupLabel), \(row.groupExpanded ? "expanded" : "collapsed")"
        )
        .accessibilityHint("Double tap to \(row.groupExpanded ? "collapse" : "expand")")
        .contextMenu {
            PinMenuButton(row: row, chatId: chat.id)
        }
    }

    private var statusIcon: String {
        if row.groupRunning { return "ellipsis.circle" }
        if row.groupStopped { return "stop.circle" }
        if row.groupFailed > 0 { return "exclamationmark.circle" }
        return "checkmark.circle"
    }

    private var statusColor: Color {
        if row.groupRunning { return .orange }
        if row.groupStopped { return .secondary }
        if row.groupFailed > 0 { return .red }
        return .secondary
    }
}

/// v10 §8: a centred, muted notice line. Agent reports expand in place.
struct NoticeRowView: View {
    let row: ChatRow
    @State private var expanded = false

    private var isExpandable: Bool {
        row.noticeKind == "agent" && !(row.noticeReport ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 5) {
            Button {
                guard isExpandable else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(row.text)
                        .multilineTextAlignment(.center)
                    if !row.timestamp.isEmpty {
                        Text("· \(row.timestamp)")
                            .monospacedDigit()
                    }
                    if isExpandable {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!isExpandable)
            .accessibilityHint(isExpandable ? "Double tap to show the report" : "")

            if expanded, let report = row.noticeReport, !report.isEmpty {
                Text(report)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ChatColors.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - Markdown

struct MarkdownSegment: Identifiable {
    let id: Int
    let text: String
    let isCode: Bool
    let language: String?
}

func parseMarkdownSegments(_ text: String) -> [MarkdownSegment] {
    var segments: [(text: String, isCode: Bool, language: String?)] = []
    var current: [String] = []
    var inCode = false
    var language: String?

    func flush() {
        guard !current.isEmpty else { return }
        let joined = current.joined(separator: "\n")
        if !joined.isEmpty {
            segments.append((joined, inCode, language))
        }
        current = []
    }

    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flush()
            if inCode {
                inCode = false
                language = nil
            } else {
                inCode = true
                let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = tag.isEmpty ? nil : tag
            }
        } else {
            current.append(line)
        }
    }
    flush()

    return segments.enumerated().map { index, segment in
        MarkdownSegment(id: index, text: segment.text, isCode: segment.isCode, language: segment.language)
    }
}

struct MarkdownText: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    private var segments: [MarkdownSegment] {
        parseMarkdownSegments(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { segment in
                if segment.isCode {
                    CodeBlock(text: segment.text, language: segment.language, isDark: colorScheme == .dark)
                } else {
                    Text(attributed(segment.text))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func attributed(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}

private struct CodeBlock: View {
    let text: String
    let language: String?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(
            Color.black.opacity(isDark ? 0.35 : 0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct ThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(ChatColors.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Tool cards

struct ToolCardView: View {
    @EnvironmentObject private var app: AppModel
    @State private var expanded = false
    let row: ChatRow
    let chat: ChatSessionModel

    private var isDone: Bool {
        row.task?.isRunning == false || row.toolDone
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let input = row.toolInput, !input.isEmpty {
                    sectionLabel("Input")
                    Text(input)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = row.toolResult, !result.isEmpty {
                    sectionLabel("Result")
                    Text(Formatting.truncate(result, 4000))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if row.toolStopped {
                    // v10 §16: cut off by Stop, not an error.
                    Text("stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isDone {
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(iconColor)
                    Text(row.toolName?.isEmpty == false ? row.toolName! : "Tool")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    if app.pin(for: row, chatId: chat.id) != nil {
                        PinnedBadge()
                    }
                    // v10 §3: tool cards carry their start time.
                    if !row.timestamp.isEmpty {
                        Text(row.timestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if row.toolStopped {
                        Text("stopped")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if row.toolDone {
                        Image(systemName: row.toolError ? "xmark.circle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(row.toolError ? .red : .secondary)
                    }
                }
                if let summary = row.toolSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let task = row.task {
                    TaskLiveLine(
                        task: task,
                        modelLabel: task.model.map { app.modelLabel(for: $0) }
                    )
                }
            }
        }
        .padding(10)
        .background(ChatColors.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            PinMenuButton(row: row, chatId: chat.id)
        }
    }

    private var icon: String {
        if row.toolStopped { return "stop.circle" }
        if let task = row.task {
            switch task.statusKind {
            case .running: return "ellipsis.circle"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.circle"
            case .stopped: return "stop.circle"
            }
        }
        if row.toolDone {
            return row.toolError ? "exclamationmark.circle" : "checkmark.circle"
        }
        return "hammer"
    }

    private var iconColor: Color {
        if row.toolStopped { return .secondary }
        if let task = row.task {
            switch task.statusKind {
            case .running: return .orange
            case .completed: return .green
            case .failed: return .red
            case .stopped: return .secondary
            }
        }
        return .secondary
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

struct TaskLiveLine: View {
    let task: TaskData
    let modelLabel: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                if let modelLabel, !modelLabel.isEmpty, modelLabel != "—" {
                    Text(modelLabel)
                        .lineLimit(1)
                }
                // v10 §3: "started 09:12" while running, else the span.
                if let time = timeText(now: context.date) {
                    Text(time)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(Formatting.tokens(task.tokens))
                    .monospacedDigit()
                    .lineLimit(1)
                if let tools = task.toolUses {
                    Text("\(tools) tools")
                }
                if let last = task.lastTool, !last.isEmpty, task.isRunning {
                    Text(last)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func timeText(now: Date) -> String? {
        if task.isRunning {
            // v10 §3 says "started 09:12": the clock alone. The full
            // timestamp ("Mon, Nov 9, 10:28 AM") is too wide for a phone row
            // and wrapped into the tokens and tools beside it.
            guard let start = clockText(task.startedAt) else { return nil }
            if let seconds = Formatting.elapsedSeconds(sinceISO: task.startedAt, now: now) {
                return "started \(start) · \(Formatting.duration(seconds: seconds))"
            }
            return "started \(start)"
        }
        if let endedAt = task.endedAt {
            let span = Formatting.timeRange(task.startedAt, endedAt)
            if !span.isEmpty { return span }
        }
        let started = Formatting.timestamp(task.startedAt)
        return started.isEmpty ? nil : "started \(started)"
    }

    /// Locale's short time for an ISO date, no day: `10:28 AM`.
    private func clockText(_ iso: String) -> String? {
        guard let date = Formatting.parseISO(iso) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var statusIcon: String {
        switch task.statusKind {
        case .running: return "ellipsis.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .stopped: return "stop.circle"
        }
    }
}

// MARK: - Permission card

struct PermissionCard: View {
    @EnvironmentObject private var app: AppModel
    let request: PermissionRequest

    private var title: String {
        if let title = request.title, !title.isEmpty { return title }
        return "\(request.tool) permission"
    }

    private var detail: String {
        if request.tool == "Bash",
           let command = request.input["command"]?.stringValue,
           !command.isEmpty {
            return command
        }
        if let description = request.description, !description.isEmpty {
            return description
        }
        return request.input.compactJSONString()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(request.tool)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(Formatting.truncate(detail, 500))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Deny", role: .destructive) {
                    app.replyPermission(request, allow: false, always: false)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Always allow") {
                    app.replyPermission(request, allow: true, always: true)
                }
                .buttonStyle(.bordered)

                Button("Allow") {
                    app.replyPermission(request, allow: true, always: false)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }
}
