import XCTest
@testable import ProteusKit

final class TerminalStoreTests: XCTestCase {

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    private func term(_ id: String, alive: Bool = true) -> TermInfo {
        TermInfo(id: id, title: "Terminal \(id)", cwd: "/tmp", alive: alive)
    }

    // MARK: - Input encoding

    func testControlBytes() {
        XCTAssertEqual(TerminalInputEncoder.controlByte("a"), 0x01)
        XCTAssertEqual(TerminalInputEncoder.controlByte("z"), 0x1a)
        XCTAssertEqual(TerminalInputEncoder.controlByte("A"), 0x01)
        XCTAssertEqual(TerminalInputEncoder.controlByte("@"), 0x00)
        XCTAssertEqual(TerminalInputEncoder.controlByte("["), 0x1b)
        XCTAssertEqual(TerminalInputEncoder.controlByte("\\"), 0x1c)
        XCTAssertEqual(TerminalInputEncoder.controlByte("]"), 0x1d)
        XCTAssertEqual(TerminalInputEncoder.controlByte("^"), 0x1e)
        XCTAssertEqual(TerminalInputEncoder.controlByte("_"), 0x1f)
        XCTAssertEqual(TerminalInputEncoder.controlByte("?"), 0x7f)
        XCTAssertEqual(TerminalInputEncoder.controlByte(" "), 0x00)
        XCTAssertNil(TerminalInputEncoder.controlByte("1"))
        XCTAssertNil(TerminalInputEncoder.controlByte("é"))
    }

    func testBasicKeys() {
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .escape)), [0x1b])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .tab)), [0x09])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .enter)), [0x0d])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .backspace)), [0x7f])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .up)), Array("\u{1b}[A".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .down)), Array("\u{1b}[B".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .right)), Array("\u{1b}[C".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .left)), Array("\u{1b}[D".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .home)), Array("\u{1b}[H".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .end)), Array("\u{1b}[F".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .delete)), Array("\u{1b}[3~".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .pageUp)), Array("\u{1b}[5~".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .pageDown)), Array("\u{1b}[6~".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .function(1))), Array("\u{1b}OP".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(for: .function(5))), Array("\u{1b}[15~".utf8))
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(forText: "ls")), Array("ls".utf8))
    }

    func testModifierSequences() {
        // xterm modifier parameter: 1 + alt(2) + ctrl(4).
        XCTAssertEqual(
            Array(TerminalInputEncoder.bytes(for: .up, ctrl: true)),
            Array("\u{1b}[1;5A".utf8)
        )
        XCTAssertEqual(
            Array(TerminalInputEncoder.bytes(for: .right, alt: true)),
            Array("\u{1b}[1;3C".utf8)
        )
        XCTAssertEqual(
            Array(TerminalInputEncoder.bytes(for: .left, ctrl: true, alt: true)),
            Array("\u{1b}[1;7D".utf8)
        )
        XCTAssertEqual(
            Array(TerminalInputEncoder.bytes(for: .function(5), ctrl: true)),
            Array("\u{1b}[15;5~".utf8)
        )
        // Alt prefixes ESC for keys without a CSI form.
        XCTAssertEqual(
            Array(TerminalInputEncoder.bytes(for: .enter, alt: true)),
            [0x1b, 0x0d]
        )
        // Ctrl applies to text; Ctrl+Space is NUL; unmodified text passes through.
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(forText: "c", ctrl: true)), [0x03])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(forText: " ", ctrl: true)), [0x00])
        XCTAssertEqual(Array(TerminalInputEncoder.bytes(forText: "x", alt: true)), [0x1b, 0x78])
    }

    func testInputStateIsOneShot() {
        let state = TerminalInputState()
        XCTAssertFalse(state.ctrl)
        XCTAssertFalse(state.alt)

        state.toggleControl()
        var consumed = state.consume()
        XCTAssertTrue(consumed.ctrl)
        XCTAssertFalse(consumed.alt)
        consumed = state.consume()
        XCTAssertFalse(consumed.ctrl)

        state.toggleAlt()
        state.setControl(true)
        consumed = state.consume()
        XCTAssertTrue(consumed.ctrl)
        XCTAssertTrue(consumed.alt)

        state.setAlt(true)
        state.clear()
        consumed = state.consume()
        XCTAssertFalse(consumed.ctrl)
        XCTAssertFalse(consumed.alt)
    }

    // MARK: - Resize debounce

    func testResizeDebouncerSendsOnlyLatestSize() {
        var scheduled: [() -> Void] = []
        var interval: TimeInterval = 0
        let debouncer = TerminalResizeDebouncer(interval: 0.2) { delay, work in
            interval = delay
            scheduled.append(work)
        }
        var sent: [(String, Int, Int)] = []
        debouncer.onResize = { sent.append(($0, $1, $2)) }

        debouncer.request(id: "a", cols: 80, rows: 24)
        debouncer.request(id: "a", cols: 120, rows: 40)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(interval, 0.2)

        // Both timers may fire; only the newest generation wins.
        scheduled.forEach { $0() }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "a")
        XCTAssertEqual(sent.first?.1, 120)
        XCTAssertEqual(sent.first?.2, 40)
    }

    func testResizeDebouncerIgnoresZeroAndFlushes() {
        var scheduled: [() -> Void] = []
        let debouncer = TerminalResizeDebouncer(interval: 0.1) { _, work in
            scheduled.append(work)
        }
        var sent: [(String, Int, Int)] = []
        debouncer.onResize = { sent.append(($0, $1, $2)) }

        debouncer.request(id: "a", cols: 0, rows: 0)
        XCTAssertTrue(scheduled.isEmpty)

        debouncer.request(id: "a", cols: 90, rows: 20)
        debouncer.flush()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "a")
        XCTAssertEqual(sent.first?.1, 90)
        XCTAssertEqual(sent.first?.2, 20)

        // The stale timer must not send a second frame.
        scheduled.forEach { $0() }
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - Open / attach / close

    func testOpenRequiresMeasuredSizeAndEncodesPlain() throws {
        let store = TerminalStore()
        XCTAssertNil(store.openFrame(cwd: "/tmp", cols: 0, rows: 24, plain: false))
        XCTAssertNil(store.openFrame(cwd: "/tmp", cols: 80, rows: 0, plain: false))

        let frame = try XCTUnwrap(store.openFrame(
            cwd: "  /tmp/project  ", cols: 100, rows: 30, plain: true, rid: "r1"
        ))
        let json = try object(frame)
        XCTAssertEqual(json["t"]?.stringValue, "term.open")
        XCTAssertEqual(json["cwd"]?.stringValue, "/tmp/project")
        XCTAssertEqual(json["cols"]?.intValue, 100)
        XCTAssertEqual(json["rows"]?.intValue, 30)
        XCTAssertEqual(json["plain"]?.boolValue, true)
        XCTAssertEqual(json["rid"]?.stringValue, "r1")

        let plain = try XCTUnwrap(store.openFrame(cwd: "   ", cols: 1, rows: 1, plain: false))
        let plainJSON = try object(plain)
        XCTAssertNil(plainJSON["cwd"])
        XCTAssertNil(plainJSON["plain"])
    }

    func testAttachRequiresLiveTerminal() throws {
        let store = TerminalStore()
        store.apply(terms: [term("t1"), term("dead", alive: false)])

        XCTAssertNil(store.attach("missing"))
        XCTAssertNil(store.attach("dead"))

        let frame = try XCTUnwrap(store.attach("t1"))
        let json = try object(frame)
        XCTAssertEqual(json["t"]?.stringValue, "term.attach")
        XCTAssertEqual(json["id"]?.stringValue, "t1")
        XCTAssertEqual(store.currentId, "t1")
        XCTAssertTrue(store.attached.contains("t1"))
        XCTAssertEqual(store.wanted, ["t1"])

        // Already attached: no duplicate subscription.
        XCTAssertNil(store.attach("t1"))
    }

    func testReconnectReattachesOnlyWantedLiveTerminals() throws {
        let store = TerminalStore()
        store.apply(terms: [term("a"), term("b"), term("dead", alive: false)])

        XCTAssertNotNil(store.attach("a"))
        XCTAssertNotNil(store.attach("b"))
        XCTAssertEqual(store.currentId, "b")

        // A view that disappeared must not be re-attached after a reconnect.
        store.viewClosed("b")
        store.connectionLost()
        XCTAssertTrue(store.attached.isEmpty)
        XCTAssertEqual(store.wanted, ["a"])

        let frames = store.reattachFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try object(frames[0])["t"]?.stringValue, "term.attach")
        XCTAssertEqual(try object(frames[0])["id"]?.stringValue, "a")
        XCTAssertTrue(store.attached.contains("a"))
    }

    func testExitRemovesTerminalAndClearsAttachState() {
        let store = TerminalStore()
        store.apply(terms: [term("a"), term("b")])
        XCTAssertNotNil(store.attach("a"))

        store.apply(exit: "a", code: 143)
        XCTAssertNil(store.term(id: "a"))
        XCTAssertNil(store.currentId)
        XCTAssertFalse(store.attached.contains("a"))
        XCTAssertFalse(store.wanted.contains("a"))
        XCTAssertEqual(store.exitCodes["a"], 143)

        store.apply(opened: term("c"))
        XCTAssertNotNil(store.term(id: "c"))
    }

    // MARK: - Input and resize frames

    func testInputOnlyWithAttachedCurrentTerminal() throws {
        let store = TerminalStore()
        store.apply(terms: [term("a")])

        XCTAssertNil(store.inputFrame(Data("ls".utf8)))
        XCTAssertNotNil(store.attach("a"))

        let frame = try XCTUnwrap(store.inputFrame(Data([0x6c, 0x73, 0x0d])))
        let json = try object(frame)
        XCTAssertEqual(json["t"]?.stringValue, "term.input")
        XCTAssertEqual(json["id"]?.stringValue, "a")
        XCTAssertEqual(json["data"]?.stringValue, Data([0x6c, 0x73, 0x0d]).base64EncodedString())

        // The accessory bar's one-shot Ctrl becomes a C0 byte and is cleared.
        store.inputState.toggleControl()
        let keyFrame = try XCTUnwrap(store.inputFrame(key: .text("c")))
        let keyJSON = try object(keyFrame)
        XCTAssertEqual(keyJSON["data"]?.stringValue, Data([0x03]).base64EncodedString())
        XCTAssertFalse(store.inputState.ctrl)

        let textFrame = try XCTUnwrap(store.inputFrame(text: "hi"))
        XCTAssertEqual(try object(textFrame)["data"]?.stringValue, Data("hi".utf8).base64EncodedString())
    }

    func testResizeFrameGoesToCurrentSocket() throws {
        var scheduled: [() -> Void] = []
        let debouncer = TerminalResizeDebouncer(interval: 0.1) { _, work in
            scheduled.append(work)
        }
        let store = TerminalStore(resizeDebouncer: debouncer)
        var frames: [ClientFrame] = []
        store.onResizeFrame = { frames.append($0) }
        store.apply(terms: [term("a")])

        store.requestResize(id: "dead", cols: 10, rows: 10)
        store.requestResize(id: "a", cols: 0, rows: 10)
        store.requestResize(id: "a", cols: 120, rows: 40)
        XCTAssertTrue(frames.isEmpty)

        scheduled.forEach { $0() }
        XCTAssertEqual(frames.count, 1)
        let json = try object(frames[0])
        XCTAssertEqual(json["t"]?.stringValue, "term.resize")
        XCTAssertEqual(json["id"]?.stringValue, "a")
        XCTAssertEqual(json["cols"]?.intValue, 120)
        XCTAssertEqual(json["rows"]?.intValue, 40)
    }

    func testOutputBase64DecodesToRawBytes() throws {
        let frame = try JSONDecoder.proteus.decode(
            TermOutputFrame.self,
            from: Data(#"{"t":"term.output","id":"a","data":"aGVsbG8=","replay":true}"#.utf8)
        )
        XCTAssertTrue(frame.replay == true)
        let data = try XCTUnwrap(TerminalStore.decodeOutput(frame))
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")

        let invalid = try JSONDecoder.proteus.decode(
            TermOutputFrame.self,
            from: Data(#"{"t":"term.output","id":"a","data":"!!!"}"#.utf8)
        )
        XCTAssertNil(TerminalStore.decodeOutput(invalid))
    }

    // MARK: - Palette and presets

    func testAnsiPalettesMatchDesktop() {
        XCTAssertEqual(TerminalPalette.dark.count, 16)
        XCTAssertEqual(TerminalPalette.light.count, 16)
        XCTAssertEqual(TerminalPalette.dark[0], "#1F1E1D")
        XCTAssertEqual(TerminalPalette.dark[1], "#E06C6C")
        XCTAssertEqual(TerminalPalette.dark[15], "#F5F4EF")
        XCTAssertEqual(TerminalPalette.light[0], "#1F1E1D")
        XCTAssertEqual(TerminalPalette.light[15], "#1F1E1D")
        XCTAssertEqual(TerminalPalette.hex(isDark: true), TerminalPalette.dark)
        XCTAssertEqual(TerminalPalette.hex(isDark: false), TerminalPalette.light)
    }

    func testProviderPresetsMatchDesktop() throws {
        XCTAssertEqual(ProviderPresets.all.map(\.id), ["anthropic-api", "deepseek", "custom", "openai"])

        let anthropic = try XCTUnwrap(ProviderPresets.anthropic.provider)
        XCTAssertEqual(anthropic.id, "anthropic")
        XCTAssertEqual(anthropic.kind, "anthropic-api")

        let deepSeek = try XCTUnwrap(ProviderPresets.deepSeek.provider)
        XCTAssertEqual(deepSeek.id, "deepseek")
        XCTAssertEqual(deepSeek.kind, "anthropic-compatible")
        XCTAssertEqual(deepSeek.baseUrl, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(deepSeek.sanitize, "deepseek")
        XCTAssertEqual(deepSeek.models?.count, 1)
        XCTAssertEqual(deepSeek.models?.first?.key, "flash")
        XCTAssertEqual(deepSeek.models?.first?.engineModel, "deepseek-flash")
        XCTAssertEqual(deepSeek.models?.first?.label, "DeepSeek Flash")
        XCTAssertEqual(deepSeek.models?.first?.tier, "fast")

        XCTAssertTrue(ProviderPresets.custom.isCustom)
        XCTAssertNil(ProviderPresets.custom.provider)
        XCTAssertTrue(ProviderPresets.openAI.isDisabled)
        XCTAssertNil(ProviderPresets.openAI.provider)
    }
}
