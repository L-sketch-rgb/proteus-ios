import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int, delay: Double)
    case disconnected(String)

    public var isConnected: Bool { self == .connected }

    public var label: String {
        switch self {
        case .idle: return "Offline"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .disconnected(let message): return message
        }
    }
}

/// One workstation: host, port and token. Token storage lives in TokenStore.
public struct HubConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var token: String
    public var client: String
    public var version: Int
    public var name: String

    public init(host: String, port: Int = 7878, token: String, name: String = "Workstation", client: String = "ios", version: Int = 1) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
        self.client = client
        self.version = version
    }

    public var url: URL? {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "ws://\(hostPart):\(port)/v1")
    }
}

/// WebSocket client for one hub. It owns the handshake, ping, reconnect
/// backoff and seq catch-up; it does not hold UI state.
public final class HubClient {
    public typealias SocketFactory = (URL) -> WebSocketConnection

    public var onStateChange: ((ConnectionState) -> Void)?
    public var onMessage: ((ServerMessage) -> Void)?
    public var onWelcome: ((WelcomeFrame) -> Void)?
    public var onError: ((String) -> Void)?

    public private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { emit { self.onStateChange?(self.state) } } }
    }
    public private(set) var welcome: WelcomeFrame?

    public let configuration: HubConfiguration

    private let socketFactory: SocketFactory
    private let queue: DispatchQueue?
    private let callbackQueue: DispatchQueue?
    private let pingInterval: TimeInterval
    private let backoff: [TimeInterval]

    private var socket: WebSocketConnection?
    private var manualClose = false
    private var attempt = 0
    private var pingWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?

    /// Sessions this client is subscribed to. Kept across reconnects so the
    /// client can replay from the last held seq (protocol.md §4).
    public private(set) var subscriptions: Set<String> = []
    /// Highest seq held per session (events and history.lastSeq).
    public private(set) var lastSeq: [String: Int] = [:]

    public init(
        configuration: HubConfiguration,
        socketFactory: @escaping SocketFactory = { URLSessionWebSocketConnection(url: $0) },
        queue: DispatchQueue? = DispatchQueue(label: "local.proteus.hubclient"),
        callbackQueue: DispatchQueue? = .main,
        pingInterval: TimeInterval = 20,
        backoff: [TimeInterval] = [1, 2, 5, 10, 30]
    ) {
        self.configuration = configuration
        self.socketFactory = socketFactory
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.pingInterval = pingInterval
        self.backoff = backoff
    }

    deinit {
        pingWork?.cancel()
        reconnectWork?.cancel()
        socket?.cancel()
    }

    // MARK: - Lifecycle

    public func connect() {
        perform {
            guard self.state != .connecting, self.state != .connected else { return }
            self.manualClose = false
            self.attempt = 0
            self.openSocket()
        }
    }

    /// User-initiated disconnect. Stops reconnecting until `connect()` again.
    public func disconnect() {
        perform {
            self.manualClose = true
            self.pingWork?.cancel()
            self.reconnectWork?.cancel()
            self.socket?.onClose = nil
            self.socket?.cancel()
            self.socket = nil
            self.state = .idle
        }
    }

    /// Reconnect immediately (foreground; PLAN R5). Subscriptions and last seq
    /// are preserved, so the hub replays only what was missed.
    public func reconnectNow() {
        perform {
            self.manualClose = false
            self.attempt = 0
            self.pingWork?.cancel()
            self.reconnectWork?.cancel()
            self.socket?.onClose = nil
            self.socket?.cancel()
            self.socket = nil
            self.state = .idle
            self.openSocket()
        }
    }

    // MARK: - Sending

    public func send(_ frame: ClientFrame) {
        perform { self.sendLocked(frame) }
    }

    public func openSession(_ id: String, since: Int? = nil) {
        perform {
            self.subscriptions.insert(id)
            let seq = since ?? self.lastSeq[id]
            self.sendLocked(.sessionOpen(id: id, since: seq, limit: self.historyLimit))
        }
    }

    /// Newest-N paging (protocol v11): when set, `session.open` (and a
    /// reconnect's re-open) asks the hub for only that many history items.
    public var historyLimit: Int?

    /// Asks for the `limit` history items before `offset` (an earlier
    /// reply's `offset`). The reply is a `history` frame with `older: true`.
    public func openOlder(_ id: String, before offset: Int, limit: Int) {
        perform {
            self.sendLocked(.sessionOpen(id: id, limit: limit, before: offset))
        }
    }

    public func closeSession(_ id: String) {
        perform {
            self.subscriptions.remove(id)
            self.sendLocked(.sessionClose(id: id))
        }
    }

    /// Forget a session that no longer exists on the hub.
    public func forgetSession(_ id: String) {
        perform {
            self.subscriptions.remove(id)
            self.lastSeq.removeValue(forKey: id)
        }
    }

    /// The highest seq this client holds for a session. A chat store that
    /// rebuilt from history can seed this so replay starts at the right place.
    public func noteSeq(_ seq: Int, for id: String) {
        perform {
            self.lastSeq[id] = max(self.lastSeq[id] ?? 0, seq)
        }
    }

    // MARK: - Internal lifecycle

    private func openSocket() {
        guard let url = configuration.url else {
            state = .disconnected("Invalid workstation address")
            return
        }
        state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt, delay: 0)
        let socket = socketFactory(url)
        self.socket = socket
        socket.onOpen = { [weak self] in
            guard let self else { return }
            self.perform {
                self.sendLocked(.hello(
                    token: self.configuration.token,
                    client: self.configuration.client,
                    version: self.configuration.version
                ))
            }
        }
        socket.onMessage = { [weak self] data in
            guard let self else { return }
            self.perform { self.handleIncoming(data) }
        }
        socket.onClose = { [weak self] error in
            guard let self else { return }
            self.perform { self.handleClose(error) }
        }
        socket.resume()
    }

    private func handleIncoming(_ data: Data) {
        guard let message = try? ServerMessage.decode(data) else {
            emit { self.onError?("The workstation sent a frame that could not be decoded.") }
            return
        }

        if case .event(let frame) = message {
            lastSeq[frame.event.id] = max(lastSeq[frame.event.id] ?? 0, frame.event.seq)
        }
        if case .history(let frame) = message {
            lastSeq[frame.id] = max(lastSeq[frame.id] ?? 0, frame.lastSeq)
        }
        if case .welcome(let frame) = message {
            welcome = frame
            attempt = 0
            state = .connected
            schedulePing()
            resubscribe()
            emit { self.onWelcome?(frame) }
        }
        if case .err(let frame) = message, frame.code == "auth" {
            manualClose = true
            state = .disconnected("The workstation rejected this token.")
            socket?.onClose = nil
            socket?.cancel()
            socket = nil
            emit { self.onError?("The workstation rejected this token.") }
        }

        emit { self.onMessage?(message) }
    }

    private func handleClose(_ error: Error?) {
        guard !manualClose else { return }
        socket?.onOpen = nil
        socket?.onMessage = nil
        socket?.onClose = nil
        socket?.cancel()
        socket = nil
        pingWork?.cancel()

        let delay = backoff[min(attempt, max(backoff.count - 1, 0))]
        attempt += 1
        state = .reconnecting(attempt: attempt, delay: delay)

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.manualClose else { return }
            self.openSocket()
        }
        reconnectWork?.cancel()
        reconnectWork = work
        if let queue {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            // Tests use a nil queue and drive reconnection with `reconnectNow`
            // or a zero backoff; scheduling still happens to mirror production.
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        }
        emit { self.onError?(error?.localizedDescription ?? "The connection closed.") }
    }

    private func resubscribe() {
        for id in subscriptions.sorted() {
            sendLocked(.sessionOpen(id: id, since: lastSeq[id], limit: historyLimit))
        }
    }

    private func sendLocked(_ frame: ClientFrame) {
        guard let socket, state == .connected || frame.t == "hello" else { return }
        guard let data = try? frame.encoded() else {
            emit { self.onError?("Could not encode a request.") }
            return
        }
        socket.send(data) { [weak self] error in
            guard let self, let error else { return }
            self.perform {
                self.emit { self.onError?(error.localizedDescription) }
            }
        }
    }

    private func schedulePing() {
        pingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connected else { return }
            self.sendLocked(.ping())
            self.schedulePing()
        }
        pingWork = work
        if let queue {
            queue.asyncAfter(deadline: .now() + pingInterval, execute: work)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + pingInterval, execute: work)
        }
    }

    // MARK: - Threading

    private func perform(_ block: @escaping () -> Void) {
        if let queue {
            queue.async(execute: block)
        } else {
            block()
        }
    }

    private func emit(_ block: @escaping () -> Void) {
        if let callbackQueue {
            callbackQueue.async(execute: block)
        } else {
            block()
        }
    }
}
