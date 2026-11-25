import XCTest
@testable import ProteusKit

private final class FakeSocket: WebSocketConnection {
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    var sent: [Data] = []
    var cancelled = false
    var resumed = false

    func resume() {
        resumed = true
        onOpen?()
    }

    func send(_ data: Data, completion: ((Error?) -> Void)?) {
        sent.append(data)
        completion?(nil)
    }

    func cancel() {
        cancelled = true
    }

    func deliver(_ json: String) {
        onMessage?(Data(json.utf8))
    }

    func deliverClose(_ error: Error? = nil) {
        onClose?(error)
    }

    var frames: [JSONValue] {
        sent.compactMap { try? JSONDecoder.proteus.decode(JSONValue.self, from: $0) }
    }

    var frameTypes: [String] {
        frames.compactMap { $0["t"]?.stringValue }
    }

    func frame(type: String) -> JSONValue? {
        frames.last { $0["t"]?.stringValue == type }
    }
}

private final class SocketBox {
    var sockets: [FakeSocket] = []
}

final class HubClientTests: XCTestCase {
    private let welcomeJSON = #"{"t":"welcome","hubVersion":"0.6.0","accounts":[],"active":"","sessions":[],"projectDefs":[{"name":"P","subagents":[]}],"models":[],"defaultModel":"claude/opus","terms":[]}"#

    private func makeClient(box: SocketBox) -> HubClient {
        let configuration = HubConfiguration(host: "100.64.0.1", port: 7878, token: "tok", client: "ios", version: 1)
        return HubClient(
            configuration: configuration,
            socketFactory: { _ in
                let socket = FakeSocket()
                box.sockets.append(socket)
                return socket
            },
            queue: nil,
            callbackQueue: nil,
            pingInterval: 3600,
            backoff: [0]
        )
    }

    func testHandshakeSendsHelloAndConnects() {
        let box = SocketBox()
        let client = makeClient(box: box)
        var states: [ConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect()
        XCTAssertEqual(box.sockets.count, 1)
        let socket = box.sockets[0]
        XCTAssertTrue(socket.resumed)
        XCTAssertEqual(socket.frameTypes, ["hello"])
        let hello = socket.frame(type: "hello")!
        XCTAssertEqual(hello["token"]?.stringValue, "tok")
        XCTAssertEqual(hello["client"]?.stringValue, "ios")
        XCTAssertEqual(hello["version"]?.intValue, 1)

        socket.deliver(welcomeJSON)
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.welcome?.defaultModel, "claude/opus")
        XCTAssertEqual(states.last, .connected)
    }

    func testOpenSessionTracksSeqAndReconnectReplaysFromIt() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let first = box.sockets[0]
        first.deliver(welcomeJSON)

        client.openSession("s1")
        let open = first.frame(type: "session.open")!
        XCTAssertEqual(open["id"]?.stringValue, "s1")
        XCTAssertNil(open["since"])
        XCTAssertEqual(client.subscriptions, ["s1"])

        first.deliver(#"{"t":"event","event":{"id":"s1","seq":4,"ts":"","kind":"text_delta","data":{"text":"a"}}}"#)
        first.deliver(#"{"t":"event","event":{"id":"s1","seq":5,"ts":"","kind":"text_delta","data":{"text":"b"}}}"#)
        XCTAssertEqual(client.lastSeq["s1"], 5)

        client.disconnect()
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(client.state, .idle)

        client.connect()
        XCTAssertEqual(box.sockets.count, 2)
        let second = box.sockets[1]
        second.deliver(welcomeJSON)

        let replay = second.frame(type: "session.open")!
        XCTAssertEqual(replay["id"]?.stringValue, "s1")
        XCTAssertEqual(replay["since"]?.intValue, 5)
    }

    func testHistorySetsLastSeqForReplay() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(welcomeJSON)
        client.openSession("s1")
        socket.deliver(#"{"t":"history","id":"s1","items":[],"lastSeq":9}"#)
        XCTAssertEqual(client.lastSeq["s1"], 9)

        client.reconnectNow()
        let second = box.sockets[1]
        second.deliver(welcomeJSON)
        XCTAssertEqual(second.frame(type: "session.open")?["since"]?.intValue, 9)
    }

    func testNoteSeqSeedsReplay() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(welcomeJSON)
        client.noteSeq(12, for: "s1")
        client.openSession("s1")
        XCTAssertEqual(socket.frame(type: "session.open")?["since"]?.intValue, 12)
    }

    func testForgetSessionStopsResubscribe() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(welcomeJSON)
        client.openSession("s1")
        socket.deliver(#"{"t":"event","event":{"id":"s1","seq":2,"ts":"","kind":"user","data":{}}}"#)
        client.forgetSession("s1")
        XCTAssertTrue(client.subscriptions.isEmpty)
        XCTAssertNil(client.lastSeq["s1"])

        client.reconnectNow()
        box.sockets[1].deliver(welcomeJSON)
        XCTAssertNil(box.sockets[1].frame(type: "session.open"))
    }

    func testAuthErrorDoesNotReconnect() {
        let box = SocketBox()
        let client = makeClient(box: box)
        var errors: [String] = []
        client.onError = { errors.append($0) }
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(#"{"t":"err","code":"auth"}"#)

        XCTAssertEqual(client.state, .disconnected("The workstation rejected this token."))
        XCTAssertTrue(socket.cancelled)
        XCTAssertTrue(errors.contains("The workstation rejected this token."))
        XCTAssertEqual(box.sockets.count, 1)
    }

    func testCloseSchedulesReconnectState() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(welcomeJSON)
        XCTAssertEqual(client.state, .connected)

        socket.deliverClose()
        XCTAssertEqual(client.state, .reconnecting(attempt: 1, delay: 0))
        XCTAssertTrue(socket.cancelled)
    }

    func testDecodeErrorIsReportedAndConnectionSurvives() {
        let box = SocketBox()
        let client = makeClient(box: box)
        var errors: [String] = []
        client.onError = { errors.append($0) }
        client.connect()
        let socket = box.sockets[0]
        socket.deliver(welcomeJSON)
        socket.deliver("not json")
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(errors.count, 1)
    }

    func testSendRequiresConnection() {
        let box = SocketBox()
        let client = makeClient(box: box)
        client.connect()
        let socket = box.sockets[0]
        // Not connected yet: the request must not be written.
        client.send(.sessionsList())
        XCTAssertNil(socket.frame(type: "sessions.list"))

        socket.deliver(welcomeJSON)
        client.send(.sessionsList(rid: "r1"))
        XCTAssertEqual(socket.frame(type: "sessions.list")?["rid"]?.stringValue, "r1")
    }

    func testHubConfigurationURL() {
        let ipv4 = HubConfiguration(host: "100.64.0.1", port: 7878, token: "t")
        XCTAssertEqual(ipv4.url?.absoluteString, "ws://100.64.0.1:7878/v1")

        let ipv6 = HubConfiguration(host: "fd7a::1", port: 9000, token: "t")
        XCTAssertEqual(ipv6.url?.absoluteString, "ws://[fd7a::1]:9000/v1")
    }
}
