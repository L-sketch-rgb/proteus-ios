import Foundation
import Combine
import UIKit
import ProteusKit

struct Workstation: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
}

struct TerminalChunk {
    let id: String
    let data: Data
    /// True for the buffer replay after `term.attach`; the terminal screen
    /// clears itself before the first chunk of a replay.
    let replay: Bool
}

private struct PendingNewChat {
    var rid: String
    var cwd: String
    var model: String
    var text: String
    var project: String?
    var permissionMode: String?
}

/// App-wide state: the hub connection, the stores mirrored into @Published
/// properties for SwiftUI, and the cached chat models.
final class AppModel: ObservableObject {
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var listing = SessionListing()
    @Published private(set) var projects: [ProjectDef] = []
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var defaultModel: String = ""
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeAccount: String = ""
    @Published private(set) var hubVersion: String?
    /// v10 §15.1: optional features the hub advertised in `welcome.features`.
    /// Empty means an older hub, so the optional controls are disabled.
    @Published private(set) var hubFeatures: Set<String> = []
    /// One dismissible "old hub" banner per connection.
    @Published private(set) var oldHubNotice = false
    /// v10 §15.4: user-made presets, synced from the hub.
    @Published private(set) var presets: [ProjectPreset] = []
    /// v10 §13: each chat's pins, from `welcome.pins` and the `pins` push.
    @Published private(set) var pinsByChat: [String: [Pin]] = [:]
    @Published var errorText: String?
    @Published private(set) var loginUpdate: LoginUpdate?
    @Published private(set) var activeChat: ChatSessionModel?
    /// Set when an `ok` for session.new arrives; the list navigates to it.
    @Published var pendingOpenChatId: String?
    /// Set when the hub removes the session the user is reading.
    @Published var removedChatId: String?

    /// v5 project dialog: agent types discovered on the hub.
    @Published private(set) var agentTypes: [AgentType] = []
    /// Set when `session.send` fails with `model_unavailable`. The chat shows
    /// an inline notice with a "Use <default>" action.
    @Published private(set) var modelUnavailableChatId: String?

    // MARK: - Terminals (v8)

    let terminalStore = TerminalStore()
    @Published private(set) var terminals: [TermInfo] = []
    @Published private(set) var terminalExits: [String: Int] = [:]
    /// Last `term.opened` reply, so a screen that sent `term.open` can find
    /// the id the hub assigned to it.
    @Published private(set) var lastTerminalOpenId: String?
    @Published private(set) var lastTerminalOpenRid: String?
    /// Raw output routed to the terminal views (base64 already decoded).
    let terminalOutput = PassthroughSubject<TerminalChunk, Never>()
    /// Folder picker state (`fs.dirs`).
    @Published private(set) var dirsPath = ""
    @Published private(set) var dirsEntries: [String] = []
    @Published private(set) var dirsRequestedPath = ""
    /// "Show shell greeting" in Settings → Terminals. Off means `term.open`
    /// carries `plain: true` so the shell starts without the rc greeting.
    @Published var showShellGreeting = UserDefaults.standard.bool(forKey: "proteus.terminal.showGreeting")

    @Published private(set) var workstations: [Workstation] = []
    @Published private(set) var activeWorkstationId: UUID?

    /// v7 custom-colour slots, mirrored from the hub.
    @Published private(set) var appearanceSlots: [AppearanceSlot?] = Array(repeating: nil, count: AppearanceStore.slotCount)

    // MARK: - v9 drafts, queue and notifications

    let drafts = DraftStore()
    let queues = QueueStore()
    let notifications = NotificationStore()
    /// Mirrors of the ProteusKit stores for SwiftUI.
    @Published private(set) var draftTexts: [String: String] = [:]
    @Published private(set) var queueItems: [String: [QueueItem]] = [:]
    @Published private(set) var notificationSettings = NotificationSettings()
    /// A `proteus://chat/<id>` link that arrived before the welcome frame.
    private var deferredLinkChatId: String?

    // MARK: - v10 §7 files panel

    /// Loaded `fs.listing` replies, keyed by the resolved real path.
    @Published private(set) var fsListings: [String: FsListingFrame] = [:]
    /// Loaded `fs.file` replies, keyed by path.
    @Published private(set) var fsFiles: [String: FsFileFrame] = [:]
    /// Last files error, e.g. "forbidden" for a path outside the chat's folder.
    @Published var fsErrorText: String?
    /// rid -> requested path, so an `err` can name the file or folder.
    private var fsPending: [String: String] = [:]

    /// v8 offline demo (`-ProteusDemo`, optionally `-ProteusDemoScreen=<name>`).
    let isDemo: Bool
    let demoScreen: String

    private let sessionStore = SessionStore()
    private let accountStore = AccountStore()
    private let catalog = ModelCatalog()
    private let tokenStore = TokenStore()
    let appearance = AppearanceStore()
    private let defaults = UserDefaults.standard
    private var markCache: [String: UIImage] = [:]
    /// Most-recently-used order for `markCache`; a live picker preview would
    /// otherwise add one entry per colour change while dragging.
    private var markCacheOrder: [String] = []
    private let markCacheLimit = 12
    /// The canonical blue mark decoded once into premultiplied RGBA bytes.
    private var blueMarkSource: (bytes: [UInt8], width: Int, height: Int, space: CGColorSpace)?

    private var chats: [String: ChatSessionModel] = [:]
    private var hubClient: HubClient?
    private var pendingNew: PendingNewChat?
    private var pendingTermOpenRid: String?
    /// The text and images of the last send, so "Use <default>" can resend it.
    private var lastSend: (chatId: String, text: String, images: [ImageIn])?
    private var started = false

    /// v10 §15.1: every feature this build can use. A hub missing any of
    /// them is older than the app.
    static let knownFeatures: Set<String> = ["fs", "pins", "resend", "notices", "presets", "questions"]

    private let workstationsKey = "proteus.workstations"
    private let activeWorkstationKey = "proteus.activeWorkstation"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        isDemo = arguments.contains("-ProteusDemo")
        demoScreen = Self.argumentValue("-ProteusDemoScreen", in: arguments) ?? ""

        appearance.onSlotsChanged = { [weak self] in
            guard let self else { return }
            self.appearanceSlots = self.appearance.slots
        }
        terminalStore.onChange = { [weak self] in
            guard let self else { return }
            self.terminals = self.terminalStore.terms
            self.terminalExits = self.terminalStore.exitCodes
        }
        terminalStore.onResizeFrame = { [weak self] frame in
            self?.hubClient?.send(frame)
        }
        drafts.onChange = { [weak self] in
            guard let self else { return }
            self.draftTexts = self.drafts.texts
        }
        drafts.onFrame = { [weak self] frame in
            self?.hubClient?.send(frame)
        }
        queues.onChange = { [weak self] in
            guard let self else { return }
            self.queueItems = self.queues.queues
        }
        notifications.onChange = { [weak self] in
            guard let self else { return }
            self.notificationSettings = self.notifications.settings
        }
    }

    // MARK: - Lifecycle

    var hub: HubClient? { hubClient }

    var hasWorkstation: Bool { !workstations.isEmpty }

    /// v10 §15.1: false when the hub predates the feature (or never said).
    func hasFeature(_ name: String) -> Bool {
        hubFeatures.contains(name)
    }

    func dismissOldHubNotice() {
        oldHubNotice = false
    }

    var activeWorkstation: Workstation? {
        workstations.first { $0.id == activeWorkstationId }
    }

    func start() {
        guard !started else { return }
        started = true
        if isDemo {
            loadDemoData()
            return
        }
        loadWorkstations()
        if let workstation = activeWorkstation,
           let token = tokenStore.token(for: workstation.id.uuidString),
           !token.isEmpty {
            connect(to: workstation, token: token)
        }
    }

    func reconnect() {
        guard !isDemo else { return }
        if hubClient != nil {
            hubClient?.reconnectNow()
        } else if let workstation = activeWorkstation,
                  let token = tokenStore.token(for: workstation.id.uuidString),
                  !token.isEmpty {
            connect(to: workstation, token: token)
        }
    }

    private func connect(to workstation: Workstation, token: String) {
        hubClient?.disconnect()
        let configuration = HubConfiguration(
            host: workstation.host,
            port: workstation.port,
            token: token,
            name: workstation.name,
            client: "ios",
            version: 1
        )
        let client = HubClient(configuration: configuration)
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connection = state
            if !state.isConnected {
                // Subscriptions died with the socket, but the mounted terminal
                // views still want their terminals; `welcome` re-attaches them.
                self.terminalStore.connectionLost()
            }
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            // A dropped socket is already shown by the connection banner; do
            // not stack network errors on top of it while backing off.
            if case .reconnecting = self.connection { return }
            self.errorText = message
        }
        client.onMessage = { [weak self] message in
            self?.handle(message)
        }
        hubClient = client
        client.connect()
    }

    // MARK: - Workstations

    private func loadWorkstations() {
        if let data = defaults.data(forKey: workstationsKey),
           let list = try? JSONDecoder().decode([Workstation].self, from: data) {
            workstations = list
        }
        if let raw = defaults.string(forKey: activeWorkstationKey),
           let id = UUID(uuidString: raw) {
            activeWorkstationId = id
        }
    }

    private func saveWorkstations() {
        if let data = try? JSONEncoder().encode(workstations) {
            defaults.set(data, forKey: workstationsKey)
        }
        if let id = activeWorkstationId {
            defaults.set(id.uuidString, forKey: activeWorkstationKey)
        } else {
            defaults.removeObject(forKey: activeWorkstationKey)
        }
    }

    @discardableResult
    func addWorkstation(name: String, host: String, portText: String, token: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 7878
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty, (1...65535).contains(port) else {
            errorText = "Host, port and token are required."
            return false
        }
        let workstation = Workstation(
            id: UUID(),
            name: trimmedName.isEmpty ? trimmedHost : trimmedName,
            host: trimmedHost,
            port: port
        )
        // Re-adding the same address updates that entry instead of leaving two
        // rows that point at one machine with one working token (D58).
        if let existing = workstations.firstIndex(where: {
            $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame && $0.port == port
        }) {
            let previous = workstations[existing]
            workstations[existing] = Workstation(
                id: previous.id,
                name: workstation.name,
                host: workstation.host,
                port: workstation.port
            )
            tokenStore.setToken(trimmedToken, for: previous.id.uuidString)
            saveWorkstations()
            activate(workstations[existing])
            return true
        }
        workstations.append(workstation)
        tokenStore.setToken(trimmedToken, for: workstation.id.uuidString)
        saveWorkstations()
        activate(workstation)
        return true
    }

    func activate(_ workstation: Workstation) {
        guard let token = tokenStore.token(for: workstation.id.uuidString), !token.isEmpty else {
            errorText = "That workstation has no token. Remove it and add it again."
            return
        }
        let switching = activeWorkstationId != workstation.id
        activeWorkstationId = workstation.id
        saveWorkstations()
        if switching {
            clearRemoteState()
        }
        connect(to: workstation, token: token)
    }

    func removeWorkstation(_ workstation: Workstation) {
        if activeWorkstationId == workstation.id {
            hubClient?.disconnect()
            hubClient = nil
            connection = .idle
            activeWorkstationId = nil
            clearRemoteState()
        }
        tokenStore.setToken(nil, for: workstation.id.uuidString)
        workstations.removeAll { $0.id == workstation.id }
        saveWorkstations()
    }

    private func clearRemoteState() {
        sessionStore.replace(sessions: [], projects: [])
        accountStore.replace(accounts: [], active: "")
        catalog.replace(models: [], defaultModel: "")
        chats.removeAll()
        activeChat = nil
        removedChatId = nil
        modelUnavailableChatId = nil
        lastSend = nil
        refreshSessions()
        accounts = []
        activeAccount = ""
        models = []
        defaultModel = ""
        agentTypes = []
        hubVersion = nil
        hubFeatures = []
        oldHubNotice = false
        presets = []
        pinsByChat = [:]
        terminalStore.apply(terms: [])
        terminalStore.connectionLost()
        terminals = []
        terminalExits = [:]
        lastTerminalOpenId = nil
        lastTerminalOpenRid = nil
        appearance.apply(slots: Array(repeating: nil, count: AppearanceStore.slotCount))
        applyAppearanceFallback()
        drafts.clearAll()
        queues.clearAll()
        notifications.reset()
        deferredLinkChatId = nil
    }

    // MARK: - Incoming frames

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let welcome):
            hubVersion = welcome.hubVersion
            // v10 §15.1: an absent `features` key means an older hub. One
            // banner per connection; the user can dismiss it.
            let features = Set(welcome.features ?? [])
            hubFeatures = features
            oldHubNotice = !Self.knownFeatures.isSubset(of: features)
            // v10 §13/§15.4: the welcome carries every non-empty pin list and
            // the saved presets.
            pinsByChat = welcome.pins.filter { !$0.value.isEmpty }
            presets = welcome.presets
            sessionStore.replace(sessions: welcome.sessions, projects: welcome.projectDefs)
            accountStore.replace(accounts: welcome.accounts, active: welcome.active)
            catalog.replace(models: welcome.models, defaultModel: welcome.defaultModel)
            defaultModel = welcome.defaultModel
            accounts = welcome.accounts
            activeAccount = welcome.active
            models = welcome.models
            refreshSessions()
            if let appearanceInfo = welcome.appearance {
                appearance.apply(info: appearanceInfo)
                applyAppearanceFallback()
            }
            drafts.apply(welcome: welcome.drafts)
            queues.apply(welcome: welcome.queues)
            notifications.apply(welcome)
            flushDeferredLink()
            if let chat = activeChat,
               let session = sessionStore.session(id: chat.id) {
                chat.updateSession(session)
            }
            // v8: the socket is new, so re-subscribe every terminal a mounted
            // view still wants. The hub replays each buffer and redraws it.
            terminalStore.apply(terms: welcome.terms)
            terminals = terminalStore.terms
            for frame in terminalStore.reattachFrames() {
                hubClient?.send(frame)
            }

        case .sessions(let frame):
            if frame.projectDefs.isEmpty {
                sessionStore.replace(sessions: frame.sessions)
            } else {
                sessionStore.replace(sessions: frame.sessions, projects: frame.projectDefs)
            }
            refreshSessions()
            flushDeferredLink()

        case .history(let frame):
            chats[frame.id]?.applyHistory(frame)

        case .event(let frame):
            chats[frame.event.id]?.apply(frame.event)

        case .sessionUpdated(let frame):
            sessionStore.upsert(frame.session)
            refreshSessions()
            chats[frame.session.id]?.updateSession(frame.session)
            if activeChat?.id == frame.session.id {
                activeChat = chats[frame.session.id]
            }

        case .sessionRemoved(let frame):
            sessionStore.remove(id: frame.id)
            refreshSessions()
            chats.removeValue(forKey: frame.id)
            hubClient?.forgetSession(frame.id)
            queues.removeChat(frame.id)
            drafts.discard(frame.id)
            pinsByChat.removeValue(forKey: frame.id)
            if activeChat?.id == frame.id {
                activeChat = nil
            }
            removedChatId = frame.id

        case .permissionRequest(let frame):
            let request = PermissionRequest(
                id: frame.id,
                reqId: frame.reqId,
                tool: frame.tool,
                input: frame.input,
                title: frame.title,
                description: frame.description
            )
            chats[frame.id]?.addPermission(request)

        case .permissionResolved(let frame):
            chats[frame.id]?.removePermission(reqId: frame.reqId)

        case .accounts(let frame):
            accountStore.replace(accounts: frame.accounts, active: frame.active)
            accounts = frame.accounts
            activeAccount = frame.active

        case .appearance(let frame):
            appearance.apply(frame: frame)
            applyAppearanceFallback()

        case .draft(let frame):
            drafts.apply(frame)

        case .queue(let frame):
            queues.apply(frame)

        case .notifications(let frame):
            notifications.apply(frame)

        case .pins(let frame):
            let pins = frame.pins.filter { $0.pinId.isEmpty == false }
            if pins.isEmpty {
                pinsByChat.removeValue(forKey: frame.id)
            } else {
                pinsByChat[frame.id] = pins
            }

        case .presets(let frame):
            presets = frame.presets

        case .models(let frame):
            catalog.replace(models: frame.models)
            models = frame.models
            defaultModel = catalog.defaultModel

        case .projects(let frame):
            sessionStore.setProjects(frame.projectDefs)
            refreshSessions()

        case .agents(let frame):
            agentTypes = frame.agents

        case .terms(let frame):
            terminalStore.apply(terms: frame.terms)

        case .termOpened(let frame):
            terminalStore.apply(opened: frame.term)
            if let rid = frame.rid, rid == pendingTermOpenRid {
                pendingTermOpenRid = nil
                lastTerminalOpenRid = rid
                lastTerminalOpenId = frame.term.id
                attachTerminal(frame.term.id)
            }

        case .termOutput(let frame):
            if let data = TerminalStore.decodeOutput(frame) {
                terminalOutput.send(TerminalChunk(
                    id: frame.id,
                    data: data,
                    replay: frame.replay ?? false
                ))
            }

        case .termExit(let frame):
            terminalStore.apply(exit: frame.id, code: frame.code)

        case .dirs(let frame):
            dirsPath = frame.path
            dirsEntries = frame.dirs

        case .fsListing(let frame):
            if let rid = frame.rid { fsPending.removeValue(forKey: rid) }
            fsListings[frame.path] = frame

        case .fsFile(let frame):
            if let rid = frame.rid { fsPending.removeValue(forKey: rid) }
            fsFiles[frame.path] = frame

        case .login(let frame):
            loginUpdate = LoginUpdate(
                name: frame.name,
                url: frame.url,
                status: frame.status,
                message: frame.message
            )

        case .ok(let frame):
            finishNewChat(frame)

        case .err(let frame):
            // A rejected *new* chat has no chat screen of its own, so its error
            // must not be swallowed the way a live chat's model swap is: the
            // screen that asked for it is still up and waiting (D57).
            let newChatRid = pendingNew?.rid
            let rejectedNewChat = newChatRid != nil && (frame.rid == nil || frame.rid == newChatRid)
            if let pending = pendingNew, frame.rid == pending.rid {
                pendingNew = nil
            }
            if let rid = frame.rid, let path = fsPending.removeValue(forKey: rid) {
                let message = frame.message ?? "Request failed (\(frame.code))."
                fsErrorText = path.isEmpty ? message : "\(path): \(message)"
                return
            }
            let message = frame.message ?? "Request failed (\(frame.code))."
            if rejectedNewChat {
                pendingNew = nil
                errorText = Self.newChatError(code: frame.code, message: message)
            } else if frame.code == "model_unavailable" {
                modelUnavailableChatId = lastSend?.chatId ?? activeChat?.id
                errorText = nil
            } else if Self.isRawProtocolError(message) {
                // v10 §15.1: an old hub's raw protocol error is logged, never
                // shown to the user.
                NSLog("Proteus: hub rejected a frame: %@", message)
            } else {
                errorText = message
            }

        case .pong, .unknown:
            break
        }
    }

    private func finishNewChat(_ frame: OkFrame) {
        guard let pending = pendingNew else { return }
        if let rid = frame.rid, rid != pending.rid { return }
        guard let id = frame.id else { return }
        pendingNew = nil
        errorText = nil

        let trimmedText = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmedText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let title = firstLine.isEmpty ? "New chat" : String(firstLine.prefix(80))
        let info = SessionInfo(
            id: id,
            title: title,
            cwd: pending.cwd,
            project: pending.project ?? "",
            model: pending.model,
            account: activeAccount,
            status: "running",
            mode: "default",
            updatedAt: Self.nowISO(),
            live: true,
            agentsRunning: 0
        )
        sessionStore.upsert(info)
        refreshSessions()
        let chat = chatModel(for: id)
        chat.updateSession(info)
        activeChat = chat
        pendingOpenChatId = id
    }

    private func refreshSessions() {
        sessions = sessionStore.sessions
        projects = sessionStore.projectDefs
        listing = sessionStore.listing()
        seen.prune(keeping: Set(sessions.map(\.id)))
    }

    // MARK: - Unread (v18 §3.5a)

    /// Which chats this device has shown. The hub has no unread state.
    let seen = SeenStore()

    func isUnread(_ session: SessionInfo) -> Bool {
        seen.isUnread(session)
    }

    func lastSeenAt(_ id: String) -> Date? {
        seen.lastSeen(id)
    }

    /// Called while a chat is on screen and when it is left.
    func markSeen(_ id: String) {
        guard !id.isEmpty else { return }
        seen.markSeen(id)
        objectWillChange.send()
    }

    // MARK: - Chats

    func chatModel(for id: String) -> ChatSessionModel {
        if let existing = chats[id] { return existing }
        let chat = ChatSessionModel(id: id)
        if let session = sessionStore.session(id: id) {
            chat.updateSession(session)
        }
        chats[id] = chat
        return chat
    }

    func cachedChat(for id: String) -> ChatSessionModel? {
        chats[id]
    }

    func attach(_ chat: ChatSessionModel) {
        activeChat = chat
        if let session = sessionStore.session(id: chat.id) {
            chat.updateSession(session)
        }
    }

    func detach(_ chat: ChatSessionModel) {
        if activeChat === chat {
            activeChat = nil
        }
    }

    func openSession(_ id: String) {
        hubClient?.openSession(id)
    }

    func closeSession(_ id: String) {
        hubClient?.closeSession(id)
    }

    func filteredListing(search: String) -> SessionListing {
        sessionStore.listing(search: search)
    }

    func session(id: String) -> SessionInfo? {
        sessionStore.session(id: id)
    }

    var recentFolders: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for session in sessions where !session.cwd.isEmpty {
            if seen.insert(session.cwd).inserted { out.append(session.cwd) }
        }
        return out
    }

    var defaultFolder: String {
        if let first = recentFolders.first { return first }
        return projects.compactMap(\.cwd).first ?? ""
    }

    func defaultModelForNewChat(project: String) -> String {
        let def = projects.first { $0.name == project }
        let id = catalog.newChatModel(project: def)
        return id.isEmpty ? defaultModel : id
    }

    /// The hub rejects a new chat with a code the user can act on, so say what
    /// to change instead of echoing the protocol (D57).
    private static func newChatError(code: String, message: String) -> String {
        switch code {
        case "model_unavailable":
            return "That model isn't available on the hub. Pick another model."
        case "bad_request" where message.contains("unknown project"):
            return "The hub doesn't know that project any more. Pick another project."
        case "bad_request" where message.contains("cwd"):
            return "That folder doesn't exist on the workstation. Pick another folder."
        default:
            return message
        }
    }

    @discardableResult
    func createChat(cwd: String, model: String, text: String, project: String, permissionMode: String? = nil) -> Bool {
        guard hubClient?.state.isConnected == true else {
            errorText = "Not connected to a workstation."
            return false
        }
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else {
            errorText = "Choose a folder for the new chat."
            return false
        }
        guard !model.isEmpty else {
            errorText = "Choose a model for the new chat."
            return false
        }
        let rid = UUID().uuidString
        let projectName = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = PendingNewChat(
            rid: rid,
            cwd: trimmedCwd,
            model: model,
            text: text,
            project: projectName.isEmpty ? nil : projectName,
            permissionMode: permissionMode
        )
        pendingNew = pending
        do {
            let frame = try ClientFrame.sessionNew(
                cwd: trimmedCwd,
                model: model,
                text: text,
                permissionMode: permissionMode,
                project: pending.project,
                rid: rid
            )
            hubClient?.send(frame)
        } catch {
            pendingNew = nil
            errorText = "Could not build the new-chat request."
            return false
        }
        return true
    }

    func sendMessage(text: String, images: [ImageIn]) {
        guard let id = activeChat?.id else { return }
        guard !text.isEmpty || !images.isEmpty else { return }
        lastSend = (id, text, images)
        do {
            let frame = try ClientFrame.sessionSend(
                id: id,
                text: text,
                images: images.isEmpty ? nil : images
            )
            hubClient?.send(frame)
        } catch {
            errorText = "Could not send the message."
        }
    }

    // MARK: - Drafts (v9 §1)

    func setDraftText(_ text: String, for id: String) {
        drafts.setText(text, for: id)
    }

    /// Send the pending draft now (chat switch, app background).
    func flushDraft(for id: String) {
        drafts.flush(id)
    }

    func flushDrafts() {
        drafts.flushAll()
    }

    /// The text was sent: drop the composer text without sending an empty
    /// draft (the hub clears it after a successful `session.send`).
    func discardDraft(for id: String) {
        drafts.discard(id)
    }

    // MARK: - Queue (v9 §2)

    func queuePrompt(_ text: String, at: Date? = nil, chatId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let iso = at.map { SchedulePresets.isoString($0) }
        hubClient?.send(.queueAdd(id: chatId, text: trimmed, at: iso))
    }

    func updateQueueItem(_ item: QueueItem, text: String?, at: QueueTimeUpdate) {
        hubClient?.send(.queueUpdate(qid: item.qid, text: text, at: at))
    }

    func removeQueueItem(_ item: QueueItem) {
        hubClient?.send(.queueRemove(qid: item.qid))
    }

    func sendQueueItemNow(_ item: QueueItem) {
        hubClient?.send(.queueSendNow(qid: item.qid))
    }

    func queueItems(for id: String) -> [QueueItem] {
        queues.items(for: id)
    }

    // MARK: - Files (v10 §7)

    func fsList(chatId: String, path: String) {
        let rid = UUID().uuidString
        fsPending[rid] = path
        fsErrorText = nil
        hubClient?.send(.fsList(id: chatId, path: path, rid: rid))
    }

    func fsRead(chatId: String, path: String) {
        let rid = UUID().uuidString
        fsPending[rid] = path
        fsErrorText = nil
        hubClient?.send(.fsRead(id: chatId, path: path, rid: rid))
    }

    func fsListing(for path: String) -> FsListingFrame? {
        fsListings[path]
    }

    func fsFile(for path: String) -> FsFileFrame? {
        fsFiles[path]
    }

    /// v10 §7 "Add to message". iOS has no composer cursor API across a sheet,
    /// so the reference is appended to the draft (with a separating space).
    func insertIntoDraft(_ text: String, for id: String) {
        var current = drafts.texts[id] ?? ""
        if !current.isEmpty, !current.hasSuffix(" "), !current.hasSuffix("\n") {
            current += " "
        }
        drafts.setText(current + text, for: id)
    }

    // MARK: - Pins (v10 §13)

    /// Newest first: most recently pinned first, as settled in the spec.
    func pins(for chatId: String) -> [Pin] {
        (pinsByChat[chatId] ?? []).sorted { lhs, rhs in
            let l = Formatting.parseISO(lhs.pinnedAt) ?? .distantPast
            let r = Formatting.parseISO(rhs.pinnedAt) ?? .distantPast
            if l != r { return l > r }
            return lhs.pinId > rhs.pinId
        }
    }

    /// The pin matching a row, by seq when live and by kind + excerpt
    /// otherwise. Nil when the row is not pinned.
    func pin(for row: ChatRow, chatId: String) -> Pin? {
        guard let kind = row.pinKind else { return nil }
        let candidates = pins(for: chatId).filter { $0.kind == kind }
        // Trim the hub's 160-character ellipsis so a history row (seq 0) and
        // a long live pin still match after reopening the chat.
        func trimmed(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("…") { text.removeLast() }
            return text
        }
        let text = trimmed(row.pinText)
        func excerptMatches(_ pin: Pin) -> Bool {
            let excerpt = trimmed(pin.excerpt)
            guard !excerpt.isEmpty, !text.isEmpty else { return false }
            return text.hasPrefix(excerpt) || excerpt.hasPrefix(text)
        }
        if row.eventSeq > 0 {
            let sameSeq = candidates.filter { $0.seq == row.eventSeq }
            if let exact = sameSeq.first(where: excerptMatches) { return exact }
            if let first = sameSeq.first { return first }
        }
        return candidates.first(where: excerptMatches)
    }

    /// Pin or unpin one transcript row. Does nothing when the hub is older.
    func togglePin(row: ChatRow, chatId: String) {
        guard hasFeature("pins"), let kind = row.pinKind else { return }
        if let pin = pin(for: row, chatId: chatId) {
            removePin(pin, chatId: chatId)
            return
        }
        let excerpt = Formatting.truncate(row.pinText, 160)
        hubClient?.send(.pinAdd(
            id: chatId,
            seq: row.eventSeq,
            kind: kind,
            excerpt: excerpt,
            ts: row.tsRaw
        ))
    }

    func removePin(_ pin: Pin, chatId: String) {
        guard hasFeature("pins"), !pin.pinId.isEmpty else { return }
        hubClient?.send(.pinRemove(id: chatId, pinId: pin.pinId))
    }

    // MARK: - Presets (v10 §15.4)

    func savePreset(name: String, agentPolicy: String?, subagents: [SubagentDef]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasFeature("presets"), !trimmed.isEmpty else { return }
        do {
            let frame = try ClientFrame.presetSave(
                name: trimmed,
                agentPolicy: agentPolicy,
                subagents: subagents
            )
            hubClient?.send(frame)
        } catch {
            errorText = "Could not save the preset."
        }
    }

    func deletePreset(_ preset: ProjectPreset) {
        guard hasFeature("presets"), !preset.presetId.isEmpty else { return }
        hubClient?.send(.presetDelete(presetId: preset.presetId))
    }

    // MARK: - Edit a sent prompt (v10 §11)

    /// Resend edited text. The hub interrupts a running turn first, then sends
    /// the text exactly as `session.send` would.
    func resend(chatId: String, text: String, images: [ImageIn] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let frame = try ClientFrame.sessionResend(
                id: chatId,
                text: text,
                images: images.isEmpty ? nil : images
            )
            hubClient?.send(frame)
        } catch {
            errorText = "Could not resend the message."
        }
    }

    // MARK: - Notifications (v8 §3)

    func setNotificationsEnabled(_ enabled: Bool) {
        hubClient?.send(NotificationStore.setFrame(enabled: enabled))
    }

    func setNotificationServer(_ server: String) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hubClient?.send(NotificationStore.setFrame(server: trimmed))
    }

    func regenerateNotificationTopic() {
        hubClient?.send(NotificationStore.setFrame(regenerate: true))
    }

    func sendTestNotification() {
        hubClient?.send(NotificationStore.testFrame())
    }

    var notificationSubscribeURL: URL? { notifications.subscribeURL }

    // MARK: - Deep links (v8 §3)

    /// `proteus://chat/<id>` from an ntfy notification. The chat may not be in
    /// the welcome frame yet on a cold start, so it waits for the sessions.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "proteus",
              url.host?.lowercased() == "chat" else { return false }
        let id = url.pathComponents.dropFirst().joined(separator: "/")
        guard !id.isEmpty else { return false }
        if sessionStore.session(id: id) != nil {
            pendingOpenChatId = id
        } else {
            deferredLinkChatId = id
        }
        return true
    }

    private func flushDeferredLink() {
        guard let id = deferredLinkChatId, sessionStore.session(id: id) != nil else { return }
        deferredLinkChatId = nil
        pendingOpenChatId = id
    }

    func interrupt() {
        guard let id = activeChat?.id else { return }
        hubClient?.send(.sessionInterrupt(id: id))
    }

    func stop(_ session: SessionInfo) {
        hubClient?.send(.sessionStop(id: session.id))
    }

    func delete(_ session: SessionInfo) {
        hubClient?.send(.sessionDelete(id: session.id))
    }

    func rename(_ session: SessionInfo, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hubClient?.send(.sessionRename(id: session.id, title: trimmed))
    }

    func move(_ session: SessionInfo, toProject project: String) {
        hubClient?.send(.sessionSetProject(id: session.id, project: project))
    }

    func setModel(_ model: String) {
        guard let id = activeChat?.id else { return }
        hubClient?.send(.sessionSetModel(id: id, model: model))
        if var session = activeChat?.session {
            session.model = model
            activeChat?.updateSession(session)
        }
        if modelUnavailableChatId == id {
            modelUnavailableChatId = nil
        }
    }

    /// v5: a send failed because the chat's model is gone. Switch the chat to
    /// the hub default and resend the same text, as the desktop does.
    func useDefaultModelAndResend() {
        guard let id = modelUnavailableChatId ?? activeChat?.id, !defaultModel.isEmpty else { return }
        let model = defaultModel
        hubClient?.send(.sessionSetModel(id: id, model: model))
        if var session = chats[id]?.session {
            session.model = model
            chats[id]?.updateSession(session)
        }
        modelUnavailableChatId = nil
        guard let last = lastSend, last.chatId == id else { return }
        do {
            let frame = try ClientFrame.sessionSend(
                id: id,
                text: last.text,
                images: last.images.isEmpty ? nil : last.images
            )
            hubClient?.send(frame)
        } catch {
            errorText = "Could not resend the message."
        }
    }

    func setMode(_ mode: String) {
        guard let id = activeChat?.id else { return }
        hubClient?.send(.sessionSetMode(id: id, mode: mode))
        if var session = activeChat?.session {
            session.mode = mode
            activeChat?.updateSession(session)
        }
    }

    func replyPermission(
        _ request: PermissionRequest,
        allow: Bool,
        always: Bool,
        message: String? = nil,
        answers: [String: String]? = nil,
        annotations: [String: [String: String]]? = nil
    ) {
        hubClient?.send(.permissionReply(
            id: request.id,
            reqId: request.reqId,
            allow: allow,
            always: always,
            message: message,
            answers: answers,
            annotations: annotations
        ))
        chats[request.id]?.removePermission(reqId: request.reqId)
    }

    /// v10 §10: ExitPlanMode approve. "and accept edits" switches the chat's
    /// mode through the normal session.setMode path before allowing the tool.
    func approvePlan(_ request: PermissionRequest, acceptEdits: Bool) {
        if acceptEdits {
            hubClient?.send(.sessionSetMode(id: request.id, mode: "acceptEdits"))
            if var session = chats[request.id]?.session {
                session.mode = "acceptEdits"
                chats[request.id]?.updateSession(session)
            }
        }
        replyPermission(request, allow: true, always: false)
    }

    // MARK: - Projects (v4/v5 parity)

    func requestAgents() {
        hubClient?.send(.agentsList())
    }

    @discardableResult
    func saveProject(_ project: ProjectDef, oldName: String?) -> Bool {
        guard hubClient?.state.isConnected == true else {
            errorText = "Not connected to a workstation."
            return false
        }
        do {
            hubClient?.send(try ClientFrame.projectSave(project: project, oldName: oldName))
            return true
        } catch {
            errorText = "Could not save the project."
            return false
        }
    }

    func deleteProject(_ name: String) {
        hubClient?.send(.projectDelete(name: name))
    }

    // MARK: - Terminals (v8)

    func attachTerminal(_ id: String) {
        if let frame = terminalStore.attach(id) {
            hubClient?.send(frame)
        }
    }

    /// The terminal view disappeared. It must not be re-attached after the
    /// next reconnect unless the user opens it again.
    func detachTerminalView(_ id: String) {
        terminalStore.viewClosed(id)
    }

    /// Sends `term.open` only with a measured size. Returns the request id the
    /// hub echoes in `term.opened`.
    @discardableResult
    func openTerminal(cwd: String?, cols: Int, rows: Int, plain: Bool) -> String? {
        guard hubClient?.state.isConnected == true else {
            errorText = "Not connected to a workstation."
            return nil
        }
        let rid = UUID().uuidString
        guard let frame = terminalStore.openFrame(
            cwd: cwd,
            cols: cols,
            rows: rows,
            plain: plain,
            rid: rid
        ) else { return nil }
        pendingTermOpenRid = rid
        hubClient?.send(frame)
        return rid
    }

    func terminalInput(_ data: Data) {
        if let frame = terminalStore.inputFrame(data) {
            hubClient?.send(frame)
        }
    }

    func terminalKey(_ key: TerminalKey) {
        if let frame = terminalStore.inputFrame(key: key) {
            hubClient?.send(frame)
        }
    }

    func terminalText(_ text: String) {
        if let frame = terminalStore.inputFrame(text: text) {
            hubClient?.send(frame)
        }
    }

    func resizeTerminal(id: String, cols: Int, rows: Int) {
        terminalStore.requestResize(id: id, cols: cols, rows: rows)
    }

    func flushTerminalResize() {
        terminalStore.flushResize()
    }

    func closeTerminal(_ id: String) {
        if let frame = terminalStore.closeFrame(id) {
            hubClient?.send(frame)
        }
        terminalStore.viewClosed(id)
    }

    func requestDirs(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? "/" : trimmed
        dirsRequestedPath = target
        hubClient?.send(.fsDirs(path: target))
    }

    // MARK: - Models

    var modelMenu: ModelMenu { catalog.menu() }

    func modelLabel(for id: String) -> String { catalog.label(for: id) }

    func prettyProvider(_ provider: String) -> String {
        catalog.prettyProvider(provider)
    }

    func setDefaultModel(_ id: String) {
        hubClient?.send(.defaultsSet(model: id))
        catalog.setDefaultModel(id)
        defaultModel = id
    }

    // MARK: - Accounts and providers (v5)

    var providers: [String] { accountStore.providers }

    func accounts(for provider: String) -> [Account] {
        accountStore.accounts(forProvider: provider)
    }

    func isActiveAccount(_ account: Account) -> Bool {
        activeAccount == account.name
    }

    func makeActive(_ account: Account, now: Bool = false) {
        let provider = account.provider ?? "claude"
        if provider == "claude" {
            hubClient?.send(.accountSwitch(name: account.name, now: now ? true : nil))
        } else {
            hubClient?.send(.providerSetActive(provider: provider, account: account.name))
        }
    }

    func renameAccount(_ account: Account, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hubClient?.send(.accountRename(name: account.name, label: trimmed))
    }

    func addAccount(provider: String, name: String, label: String) {
        hubClient?.send(.accountAdd(provider: provider, name: name, label: label))
    }

    func removeAccount(_ account: Account) {
        hubClient?.send(.accountRemove(name: account.name))
    }

    /// Saves a provider, its first account, and optionally that account's key.
    /// Frames are ordered, so the hub has the provider and account before the
    /// secret arrives.
    func saveProvider(
        _ provider: ProviderConfig,
        accountName: String,
        accountLabel: String,
        key: String?
    ) {
        guard hubClient?.state.isConnected == true else {
            errorText = "Not connected to a workstation."
            return
        }
        do {
            hubClient?.send(try ClientFrame.providerSave(provider))
            hubClient?.send(.accountAdd(
                provider: provider.id,
                name: accountName,
                label: accountLabel
            ))
            if let key, !key.isEmpty {
                hubClient?.send(.secretSet(account: accountName, key: key))
            }
        } catch {
            errorText = "Could not save the provider."
        }
    }

    func deleteProvider(_ id: String) {
        hubClient?.send(.providerDelete(id: id))
    }

    func setKey(_ account: Account, key: String?) {
        if let key, key.isEmpty { return }
        hubClient?.send(.secretSet(account: account.name, key: key))
    }

    func setKey(accountName: String, key: String) {
        guard !accountName.isEmpty, !key.isEmpty else { return }
        hubClient?.send(.secretSet(account: accountName, key: key))
    }

    func login(_ account: Account) {
        hubClient?.send(.accountLogin(name: account.name))
    }

    func keyHint(for account: Account) -> String? {
        accountStore.keyHint(for: account)
    }

    // MARK: - Appearance (v7)

    /// The selected palette, resolved against the synced slots. An emptied
    /// `custom:<n>` selection falls back to blue.
    func resolvedPalette(for selection: String) -> ResolvedPalette {
        appearance.resolve(selection)
    }

    /// Send `appearance.setSlot`, update locally so the swatch changes at once,
    /// and optionally select the slot on this device.
    func saveAppearanceSlot(_ slot: AppearanceSlot, at index: Int, select: Bool) {
        guard (0..<AppearanceStore.slotCount).contains(index) else { return }
        hubClient?.send(.appearanceSetSlot(index: index, slot: slot))
        appearance.setLocal(index: index, slot: slot)
        if select {
            defaults.set("custom:\(index)", forKey: AppearanceStore.selectionDefaultsKey)
        }
    }

    func clearAppearanceSlot(at index: Int) {
        guard (0..<AppearanceStore.slotCount).contains(index) else { return }
        hubClient?.send(.appearanceSetSlot(index: index, slot: nil))
        appearance.setLocal(index: index, slot: nil)
        let raw = defaults.string(forKey: AppearanceStore.selectionDefaultsKey) ?? PaletteCatalog.defaultKey
        if case .custom(let selected) = PaletteSelection(raw: raw), selected == index {
            defaults.set(PaletteCatalog.defaultKey, forKey: AppearanceStore.selectionDefaultsKey)
        }
    }

    private func applyAppearanceFallback() {
        let raw = defaults.string(forKey: AppearanceStore.selectionDefaultsKey) ?? PaletteCatalog.defaultKey
        let resolved = appearance.resolvedSelection(for: raw)
        if resolved != raw {
            defaults.set(resolved, forKey: AppearanceStore.selectionDefaultsKey)
        }
    }

    /// The hand mark for a custom palette: the canonical blue mark filtered at
    /// runtime, cached per (shift, sat) with a small bounded cache because the
    /// picker previews every colour change while dragging.
    func customMarkImage(shift: Double, sat: Double) -> UIImage? {
        let cacheKey = "\(shift.bitPattern)-\(sat.bitPattern)"
        if let cached = markCache[cacheKey] { return cached }
        guard let source = blueMark() else { return nil }

        let filtered = PaletteEngine.filterRGBA(
            source.bytes,
            dhue8: PaletteEngine.hueDelta8(shift: shift),
            sat: sat
        )
        let data = Data(filtered)
        guard let provider = CGDataProvider(data: data as CFData),
              let output = CGImage(
                width: source.width,
                height: source.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: source.width * 4,
                space: source.space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        let image = UIImage(cgImage: output)
        markCache[cacheKey] = image
        markCacheOrder.append(cacheKey)
        if markCacheOrder.count > markCacheLimit {
            markCache.removeValue(forKey: markCacheOrder.removeFirst())
        }
        return image
    }

    /// Decode the canonical blue mark once; filtering then only touches bytes.
    private func blueMark() -> (bytes: [UInt8], width: Int, height: Int, space: CGColorSpace)? {
        if let source = blueMarkSource { return source }
        guard let image = UIImage(named: "mark-blue"), let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        let source = (bytes: bytes, width: width, height: height, space: colorSpace)
        blueMarkSource = source
        return source
    }

    // MARK: - Demo (v8)

    private func loadDemoData() {
        // v11 §1: generic projects only; no owner machine, paths or presets.
        let projectDefs = [
            ProjectDef(
                name: "Website",
                cwd: "~/projects/website",
                defaultModel: "claude/opus",
                instructions: "Match the design system; keep changes small and tested.",
                agentPolicy: "Delegate searches and mechanical edits; keep design decisions yourself.",
                subagents: [
                    SubagentDef(
                        name: "researcher",
                        when: "Finds the relevant files and reports facts; makes no decisions.",
                        model: "mid",
                        tools: "read-only"
                    ),
                    SubagentDef(
                        name: "coder",
                        when: "Makes a fully specified change; no design decisions.",
                        model: "fast",
                        tools: "all"
                    ),
                ]
            ),
            ProjectDef(name: "Notes", cwd: "~/notes"),
        ]
        let demoSessions = [
            SessionInfo(
                id: "demo-1",
                title: "Fix the sign-up form",
                cwd: "~/projects/website",
                project: "Website",
                model: "claude/opus",
                account: "claude-main",
                status: "running",
                mode: "default",
                updatedAt: "2026-11-09T10:30:00Z",
                live: true,
                agentsRunning: 2,
                queued: 1,
                commands: ["/compact", "/review"]
            ),
            SessionInfo(
                id: "demo-2",
                title: "Add a docs page",
                cwd: "~/projects/website",
                project: "Website",
                model: "claude/sonnet",
                account: "claude-main",
                status: "idle",
                mode: "acceptEdits",
                updatedAt: "2026-11-09T09:12:00Z"
            ),
            SessionInfo(
                id: "demo-3",
                title: "Summarise last week's notes",
                cwd: "~/notes",
                project: "Notes",
                model: "claude/sonnet",
                account: "claude-main",
                status: "idle",
                updatedAt: "2026-11-08T18:45:00Z"
            ),
            SessionInfo(
                id: "demo-4",
                title: "Draft the announcement",
                cwd: "~/notes",
                model: "claude/haiku",
                account: "claude-main",
                status: "error",
                updatedAt: "2026-11-07T12:00:00Z"
            ),
        ]
        let demoModels = [
            ModelInfo(id: "claude/opus", label: "Opus", provider: "claude", engineModel: "claude-opus-4-1", tier: "top", pinned: false),
            ModelInfo(id: "claude/sonnet", label: "Sonnet", provider: "claude", engineModel: "claude-sonnet-4-5", tier: "mid", pinned: false),
            ModelInfo(id: "claude/haiku", label: "Haiku", provider: "claude", engineModel: "claude-haiku-4-5", tier: "fast", pinned: false),
            ModelInfo(id: "claude/opus-4-0", label: "Opus 4.0", provider: "claude", engineModel: "claude-opus-4-0", available: false, unavailableReason: "credits"),
        ]
        let account = Account(
            name: "claude-main",
            label: "Claude",
            email: "you@example.com",
            provider: "claude",
            kind: "claude-subscription",
            loggedIn: true,
            usage: AccountUsage(
                fiveHour: UsageWindow(utilization: 0.32),
                sevenDay: UsageWindow(utilization: 0.61),
                status: "Allowed"
            )
        )

        sessionStore.replace(sessions: demoSessions, projects: projectDefs)
        accountStore.replace(accounts: [account], active: account.name)
        catalog.replace(models: demoModels, defaultModel: "claude/opus")
        refreshSessions()
        accounts = [account]
        activeAccount = account.name
        models = demoModels
        defaultModel = "claude/opus"
        connection = .connected
        hubVersion = "10.0-demo"
        // The demo hub advertises every feature this build knows.
        hubFeatures = Self.knownFeatures
        oldHubNotice = false
        pinsByChat = [:]
        presets = []

        // v9 demo state: a synced draft, one queued prompt and notifications.
        drafts.setText("Can you also explain the validation rules?", for: "demo-1")
        queues.apply(welcome: [
            "demo-1": [
                QueueItem(qid: "demo-q1", text: "Then run the tests", createdAt: "2026-11-09T10:32:00Z"),
            ],
        ])
        notifications.apply(NotificationSettings(
            enabled: true,
            server: "https://ntfy.sh",
            topic: "proteus-demo0topic0not0real0"
        ))

        let terminal = TermInfo(
            id: "demo-term",
            title: "demo — zsh",
            cwd: "~/projects/website",
            pid: 4242,
            createdAt: "2026-11-09T10:00:00Z",
            alive: true
        )
        terminalStore.apply(terms: [terminal])
        terminalStore.attach(terminal.id)
        terminals = terminalStore.terms

        loadDemoChat()
    }

    private func loadDemoChat() {
        let chat = chatModel(for: "demo-1")
        if let session = sessionStore.session(id: "demo-1") {
            chat.updateSession(session)
        }
        let timestamp = "2026-11-09T10:30:00Z"
        func apply(_ seq: Int, _ kind: String, _ data: JSONValue) {
            chat.apply(HubEvent(id: "demo-1", seq: seq, ts: timestamp, kind: kind, data: data))
        }
        func applyTask(_ seq: Int, _ task: TaskData) {
            guard let encoded = try? JSONEncoder.proteus.encode(task),
                  let data = try? JSONDecoder.proteus.decode(JSONValue.self, from: encoded)
            else { return }
            apply(seq, "task", data)
        }

        apply(1, "user", .object([
            "text": .string("The sign-up form rejects valid email addresses. Can you trace it?"),
        ]))
        apply(2, "assistant", .object([
            "blocks": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("I'll trace the validation path first, then check the server response."),
                ]),
                .object([
                    "type": .string("tool_use"),
                    "id": .string("demo-tool-1"),
                    "name": .string("Agent"),
                    "input": .object([
                        "description": .string("Trace form validation"),
                        "subagent_type": .string("researcher"),
                    ]),
                ]),
                .object([
                    "type": .string("tool_use"),
                    "id": .string("demo-tool-2"),
                    "name": .string("Read"),
                    "input": .object([
                        "file_path": .string("src/forms/signup.js"),
                    ]),
                ]),
            ]),
        ]))
        applyTask(3, TaskData(
            taskId: "demo-task-1",
            toolUseId: "demo-tool-1",
            agent: "researcher",
            description: "Trace form validation",
            model: "claude/sonnet",
            status: "running",
            startedAt: "2026-11-09T10:28:00Z",
            tokens: 18_400,
            toolUses: 12,
            lastTool: "Grep"
        ))
        applyTask(4, TaskData(
            taskId: "demo-task-2",
            agent: "coder",
            description: "Fix the validation rule",
            model: "claude/haiku",
            status: "completed",
            startedAt: "2026-11-09T10:20:00Z",
            endedAt: "2026-11-09T10:21:36Z",
            tokens: 42_000,
            toolUses: 26,
            durationMs: 96_000,
            summary: "Patched the validator; tests pass."
        ))
        apply(5, "notice", .object([
            "text": .string("Demo data — no workstation is connected."),
        ]))
    }

    /// Terminal demo transcript, fed straight into SwiftTerm.
    func demoTerminalBytes() -> Data {
        let text = """
        \u{1B}[1;32mproteus demo terminal\u{1B}[0m  (offline)\r
        Last login: Sun Nov  9 10:28:01 on ttys004\r
        \u{1B}[1;34m~/projects/website\u{1B}[0m % ls --color\r
        \u{1B}[1;34mdocs\u{1B}[0m   \u{1B}[1;34msrc\u{1B}[0m   package.json\r
        \u{1B}[1;34m~/projects/website\u{1B}[0m % git status -sb\r
        ## main...origin/main\r
        \u{1B}[1;34m~/projects/website\u{1B}[0m % npm test\r
        All tests passed.\r
        \u{1B}[1;34m~/projects/website\u{1B}[0m % \u{1B}[?25h
        """
        return Data(text.utf8)
    }

    // MARK: - Helpers

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == name, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix(name + "=") {
                return String(argument.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// v10 §15.1: texts such as "unknown frame type: pins" are internal.
    private static func isRawProtocolError(_ message: String) -> Bool {
        message.range(of: "unknown frame", options: .caseInsensitive) != nil
    }

    private static func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
