import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The small surface HubClient needs from a WebSocket. Tests inject a fake;
/// the app (and the Linux probe) use `URLSessionWebSocketConnection`.
public protocol WebSocketConnection: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onMessage: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }

    func resume()
    func send(_ data: Data, completion: ((Error?) -> Void)?)
    func cancel()
}

/// URLSessionWebSocketTask implementation, including swift-corelibs-foundation
/// on Linux. Only Data frames are produced: `.string` messages are converted.
public final class URLSessionWebSocketConnection: WebSocketConnection {
    public var onOpen: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var closed = false
    private let lock = NSLock()

    public init(url: URL, session: URLSession = URLSession(configuration: .default)) {
        self.session = session
        self.task = session.webSocketTask(with: url)
    }

    public func resume() {
        task.resume()
        receiveNext()
        // URLSessionWebSocketTask has no portable open callback on Linux; the
        // initial send is queued and flushed once the handshake completes.
        onOpen?()
    }

    public func send(_ data: Data, completion: ((Error?) -> Void)?) {
        task.send(.data(data)) { error in completion?(error) }
    }

    public func cancel() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onMessage?(data)
                case .string(let text):
                    self.onMessage?(Data(text.utf8))
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        onClose?(error)
    }
}
