import Foundation
import Combine
import ProteusKit

/// One open chat: transcript rows, live task state and pending permission
/// requests. Instances are cached by AppModel so navigating away and back
/// does not rebuild the transcript (the hub only replays events after the
/// last seq held by HubClient).
final class ChatSessionModel: ObservableObject, Identifiable {
    /// A new-chat draft is created with a `draft-` id and takes the hub's real
    /// id in place (`adopt`) when its first message creates the session, so the
    /// view showing it is never swapped for another one.
    @Published private(set) var id: String

    /// The choices a draft carries until its first message is sent.
    @Published var draftProject = ""
    @Published var draftFolder = ""
    @Published var draftModel = ""
    @Published var draftMode = "default"

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

    static let draftPrefix = "draft-"

    /// True until the first message has created the session on the hub.
    var isDraft: Bool { id.hasPrefix(Self.draftPrefix) }

    /// False until the first history frame (or the first live row) arrives, so
    /// the chat can show its shell and a skeleton instead of an empty page.
    @Published private(set) var historyLoaded = false

    init(id: String) {
        self.id = id
        historyLoaded = id.hasPrefix(Self.draftPrefix)
        chat.reset(sessionId: id)
        chat.onChange = { [weak self] in self?.scheduleRefresh() }
        chat.onTask = { [weak self] task in self?.tasks.replace(task) }
        tasks.onChange = { [weak self] in self?.refreshTasks() }
    }

    var title: String {
        let title = session?.title ?? ""
        if title.isEmpty { return isDraft ? "New chat" : "Chat" }
        return title
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
        // A history is being folded off the main thread: hold live events
        // until it lands so they apply on top of it, in order.
        if isFolding {
            bufferedEvents.append(event)
            return
        }
        chat.apply(event)
    }

    // MARK: - History (folded off the main thread)

    private static let foldQueue = DispatchQueue(label: "proteus.history.fold", qos: .userInitiated)
    private var isFolding = false
    private var foldGeneration = 0
    private var bufferedEvents: [HubEvent] = []
    /// Older items an old hub sent in full. Held here, paged in locally.
    private var backlog: [HistoryItem] = []
    var hasBacklog: Bool { !backlog.isEmpty }
    /// Told after every history chunk lands (first page or older chunk); the
    /// app uses it to schedule the next background backfill chunk.
    var onHistoryLanded: (() -> Void)?

    /// Pages the next 40 backlog items in front of the rows. Main thread, but
    /// only 40 items.
    func prependFromBacklog() {
        guard !backlog.isEmpty else { return }
        let take = min(AppModel.historyChunkSize, backlog.count)
        let page = Array(backlog.suffix(take))
        backlog.removeLast(take)
        chat.prependHistory(page, offset: backlog.count)
        loadingOlder = false
        refreshRows()
        onHistoryLanded?()
    }

    /// The draft's first message created session `newId` on the hub: this model
    /// becomes that chat, keeping its identity in the view tree.
    func adopt(id newId: String, firstText: String) {
        id = newId
        chat.reset(sessionId: newId)
        if !firstText.isEmpty { chat.appendLocalUser(firstText) }
        historyLoaded = true
    }

    func applyHistory(_ frame: HistoryFrame) {
        loadingOlder = false
        if frame.older {
            chat.prependHistory(frame.items, offset: frame.offset ?? 0)
            refreshRows()
            onHistoryLanded?()
            return
        }
        tasks.reset()
        permissions = []
        // Everything heavy happens on `foldQueue`: splitting off the backlog
        // (an old hub sends the whole history), folding the newest rows into a
        // private ChatStore, and warming the markdown cache for the rows that
        // show first. The main thread only swaps the result in and publishes
        // once.
        foldGeneration += 1
        let generation = foldGeneration
        isFolding = true
        bufferedEvents = []
        let sessionId = id
        let lastSeq = frame.lastSeq
        let offset = frame.offset
        let items = frame.items
        Self.foldQueue.async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let (held, tail) = HistoryTail.split(items, offset: offset)
            let store = ChatStore()
            store.reset(sessionId: sessionId)
            store.applyHistory(tail, lastSeq: lastSeq, offset: offset ?? held.count)
            let foldMs = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let warmStart = DispatchTime.now().uptimeNanoseconds
            // Newest assistant rows first; bounded so a freak history cannot
            // delay the first paint.
            var warmed = 0
            for row in store.visibleRows.reversed() where row.kind == .assistant {
                MarkdownCache.prewarm(row.text.utf8.count > 4000 ? String(row.text.prefix(2500)) : row.text)
                warmed += 1
                if warmed >= 12 || DispatchTime.now().uptimeNanoseconds - warmStart > 400_000_000 { break }
            }
            let warmMs = Int((DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000)
            DispatchQueue.main.async {
                guard let self, self.foldGeneration == generation else { return }
                self.finishFold(store, held: held, foldMs: foldMs, warmMs: warmMs, items: items.count)
            }
        }
    }

    private func finishFold(_ store: ChatStore, held: [HistoryItem], foldMs: Int, warmMs: Int, items: Int) {
        chat.replaceState(from: store)
        backlog = held
        for task in store.tasks.values { tasks.replace(task) }
        isFolding = false
        historyLoaded = true
        let pending = bufferedEvents
        bufferedEvents = []
        for event in pending { chat.apply(event) }
        refreshRows()
        refreshTasks()
        StallWatchdog.shared.mark("first page landed")
        onHistoryLanded?()
        NSLog("PERF history items=\(items) fold_ms=\(foldMs) warm_ms=\(warmMs) backlog=\(held.count)")
    }

    func addPermission(_ request: PermissionRequest) {
        guard !permissions.contains(where: { $0.reqId == request.reqId }) else { return }
        permissions.append(request)
    }

    func removePermission(reqId: String) {
        permissions.removeAll { $0.reqId == reqId }
    }

    func reset() {
        foldGeneration += 1
        isFolding = false
        bufferedEvents = []
        backlog = []
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
