import Foundation
import Combine
import ProteusKit

/// One open chat: transcript rows, live task state and pending permission
/// requests. Instances are cached by AppModel so navigating away and back
/// does not rebuild the transcript (the hub only replays events after the
/// last seq held by HubClient).
final class ChatSessionModel: ObservableObject, Identifiable {
    let id: String

    let chat = ChatStore()
    let tasks = TaskStore()

    @Published private(set) var rows: [ChatRow] = []
    @Published private(set) var sortedTasks: [TaskData] = []
    @Published private(set) var runningTasks: Int = 0
    @Published private(set) var permissions: [PermissionRequest] = []
    @Published private(set) var session: SessionInfo?
    /// Bumped after every transcript mutation, so the view can pin to bottom
    /// while streaming (row count alone does not change on deltas).
    @Published private(set) var contentVersion: Int = 0

    /// v10 §12: remembered scroll state, per chat, in memory.
    var scrollAnchorId: String?
    var scrollAtBottom = true
    var scrollLastSeenCount = 0

    /// True while an older page is requested from the hub.
    var loadingOlder = false
    /// The hub has older history than the rows held.
    var hasOlderHistory: Bool { chat.hasOlderHistory }
    var historyOffset: Int { chat.historyOffset }

    init(id: String) {
        self.id = id
        chat.reset(sessionId: id)
        chat.onChange = { [weak self] in self?.scheduleRefresh() }
        chat.onTask = { [weak self] task in self?.tasks.replace(task) }
        tasks.onChange = { [weak self] in self?.refreshTasks() }
    }

    var title: String {
        let title = session?.title ?? ""
        return title.isEmpty ? "Chat" : title
    }

    var isRunning: Bool {
        guard let status = session?.statusKind else { return false }
        return status == .running || status == .waiting
    }

    var taskSummary: String { tasks.summaryLine() }

    /// Canonical event rows, group children counted once (v10 §12 pill).
    var entryCount: Int { chat.entryCount }

    /// All display rows, including children of a collapsed tool group.
    var allRows: [ChatRow] { chat.rows }

    /// v10 §2: expand/collapse one tool group.
    func toggleGroup(_ groupId: String) {
        chat.toggleGroup(groupId)
    }

    /// v10 §2: an agent tap scrolls to its card; open its group first.
    func expandGroup(containingRowId rowId: String) {
        guard let row = chat.rows.first(where: { $0.id == rowId }),
              !row.groupId.isEmpty,
              !row.groupExpanded else { return }
        chat.expandGroup(row.groupId)
    }

    /// v10 §11: the original message keeps its place, marked "edited ↓".
    func markEdited(rowId: String) {
        chat.markEdited(id: rowId)
    }

    /// v10 §13: the transcript row a pin points at, for scrolling.
    func row(for pin: Pin) -> ChatRow? {
        chat.row(matching: pin)
    }

    func updateSession(_ session: SessionInfo) {
        self.session = session
    }

    func apply(_ event: HubEvent) {
        chat.apply(event)
    }

    func applyHistory(_ frame: HistoryFrame) {
        loadingOlder = false
        if frame.older {
            chat.prependHistory(frame.items, offset: frame.offset ?? 0)
            refreshRows()
            return
        }
        tasks.reset()
        permissions = []
        chat.applyHistory(frame.items, lastSeq: frame.lastSeq, offset: frame.offset)
        refreshRows()
        refreshTasks()
    }

    func addPermission(_ request: PermissionRequest) {
        guard !permissions.contains(where: { $0.reqId == request.reqId }) else { return }
        permissions.append(request)
    }

    func removePermission(reqId: String) {
        permissions.removeAll { $0.reqId == reqId }
    }

    func reset() {
        tasks.reset()
        permissions = []
        chat.reset(sessionId: id)
        refreshRows()
        refreshTasks()
    }

    // Perf: a fast stream sends dozens of deltas a second and each @Published
    // write re-diffs the transcript. Publish at most every 60 ms (leading edge
    // immediate, trailing edge guaranteed) so the UI sees every final state.
    private var lastPublish = Date.distantPast
    private var refreshPending = false
    private static let publishInterval: TimeInterval = 0.06

    private func scheduleRefresh() {
        let wait = Self.publishInterval - Date().timeIntervalSince(lastPublish)
        if wait <= 0 {
            refreshRows()
        } else if !refreshPending {
            refreshPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.refreshRows()
            }
        }
    }

    private func refreshRows() {
        refreshPending = false
        lastPublish = Date()
        rows = chat.visibleRows
        contentVersion += 1
    }

    private func refreshTasks() {
        sortedTasks = tasks.sorted
        runningTasks = tasks.runningCount
    }
}
