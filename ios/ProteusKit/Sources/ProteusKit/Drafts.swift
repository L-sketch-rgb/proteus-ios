import Foundation

// MARK: - Wire shapes (v9 §1)

/// One entry of `welcome.drafts` / the stored KV form after `draft.set`.
public struct DraftWire: Codable, Equatable, Sendable {
    public var text: String
    public var updatedAt: String

    public init(text: String, updatedAt: String = "") {
        self.text = text
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case text, updatedAt }
}

/// The unsolicited `{t:"draft", id, text, updatedAt, by}` broadcast.
public struct DraftFrame: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var updatedAt: String
    /// The client instance id that made the edit; `""` when the hub cleared it
    /// after a successful send.
    public var by: String

    public init(id: String, text: String, updatedAt: String = "", by: String = "") {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
        self.by = by
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        by = try c.decodeIfPresent(String.self, forKey: .by) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, text, updatedAt, by }
}

// MARK: - Draft store

/// Per-chat synced composer drafts (docs/design/v9-commands-drafts-perf.md §1).
///
/// The store owns the text of every chat this device has touched. A local edit
/// schedules one `draft.set` 600 ms after the last keystroke; `flush` sends the
/// pending text now (chat switch, app background). A remote broadcast replaces
/// the local text only when this device has not typed in that chat in the last
/// three seconds; an own echo is ignored by `by == clientId`.
///
/// The clock, timer and client id are injectable so the Linux tests are
/// deterministic.
public final class DraftStore {
    public typealias Clock = () -> Date
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    public static let debounceInterval: TimeInterval = 0.6
    public static let remoteApplyWindow: TimeInterval = 3.0
    public static let maximumCharacters = 100_000

    public static let mainScheduler: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// This app instance's id, sent as `client`/echoed as `by`.
    public let clientId: String

    /// The current text per session id ("" when empty).
    public private(set) var texts: [String: String] = [:]

    /// Called after any local or remote text change.
    public var onChange: (() -> Void)?
    /// Called with a ready `draft.set` frame.
    public var onFrame: ((ClientFrame) -> Void)?

    private let clock: Clock
    private let scheduler: Scheduler
    private let interval: TimeInterval
    private let remoteWindow: TimeInterval

    /// Last local keystroke per chat, for the 3 s remote-apply rule.
    private var lastLocalWrite: [String: Date] = [:]
    /// Per-chat generation: a stale timer is ignored.
    private var generations: [String: Int] = [:]
    /// Chats with a scheduled (not yet sent) frame.
    private var pending: Set<String> = []

    public init(
        clientId: String = UUID().uuidString,
        interval: TimeInterval = DraftStore.debounceInterval,
        remoteWindow: TimeInterval = DraftStore.remoteApplyWindow,
        clock: @escaping Clock = Date.init,
        scheduler: @escaping Scheduler = DraftStore.mainScheduler
    ) {
        self.clientId = clientId
        self.interval = interval
        self.remoteWindow = remoteWindow
        self.clock = clock
        self.scheduler = scheduler
    }

    // MARK: Reading

    public func text(for id: String) -> String {
        texts[id] ?? ""
    }

    public var pendingChatIds: Set<String> { pending }

    // MARK: Local edits

    /// Record a composer edit and schedule the debounced `draft.set`. The text
    /// is not truncated here: the hub rejects anything over 100 000 characters.
    public func setText(_ text: String, for id: String) {
        if texts[id] == text { return }
        texts[id] = text
        lastLocalWrite[id] = clock()
        onChange?()
        schedule(id)
    }

    /// Send the pending text for `id` immediately (chat switch, background).
    public func flush(_ id: String) {
        guard pending.contains(id) else { return }
        send(id)
    }

    public func flushAll() {
        for id in pending.sorted() { send(id) }
    }

    /// The hub cleared the draft after a successful send: drop the local text
    /// and any pending frame so stale text is never re-sent.
    public func discard(_ id: String) {
        generations[id, default: 0] += 1
        pending.remove(id)
        lastLocalWrite.removeValue(forKey: id)
        texts[id] = ""
        onChange?()
    }

    /// Forget every chat's draft (switching workstation).
    public func clearAll() {
        generations.removeAll()
        pending.removeAll()
        lastLocalWrite.removeAll()
        texts.removeAll()
        onChange?()
    }

    // MARK: Remote edits

    /// Apply `welcome.drafts`. The hub cannot say who wrote these, so they are
    /// treated like a remote broadcast (`by: ""`).
    public func apply(welcome drafts: [String: DraftWire]) {
        for (id, wire) in drafts.sorted(by: { $0.key < $1.key }) {
            applyRemote(id: id, text: wire.text, by: "")
        }
    }

    /// Apply a `draft` broadcast. Own echoes and a chat with recent local
    /// typing are ignored.
    public func apply(_ frame: DraftFrame) {
        guard frame.by != clientId else { return }
        applyRemote(id: frame.id, text: frame.text, by: frame.by)
    }

    private func applyRemote(id: String, text: String, by: String) {
        // `by` is kept in the signature for readability of the call sites; the
        // own-echo check already happened in `apply`.
        _ = by
        if let typedAt = lastLocalWrite[id], clock().timeIntervalSince(typedAt) < remoteWindow {
            return
        }
        if pending.contains(id) { return }
        if (texts[id] ?? "") == text { return }
        texts[id] = text
        onChange?()
    }

    // MARK: Debounce

    private func schedule(_ id: String) {
        generations[id, default: 0] += 1
        let generation = generations[id] ?? 0
        pending.insert(id)
        scheduler(interval) { [weak self] in
            guard let self, self.generations[id] == generation else { return }
            self.send(id)
        }
    }

    private func send(_ id: String) {
        guard pending.contains(id) else { return }
        pending.remove(id)
        let frame = ClientFrame.draftSet(id: id, text: texts[id] ?? "", client: clientId)
        onFrame?(frame)
    }
}
