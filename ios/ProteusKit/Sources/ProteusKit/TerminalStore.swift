import Foundation

// MARK: - Input encoding

/// One key the terminal accessory bar (or a test) can send. Text is sent as
/// UTF-8; functional keys are encoded the way xterm expects them.
public enum TerminalKey: Equatable, Sendable {
    case escape
    case tab
    case enter
    case backspace
    case delete
    case insert
    case up
    case down
    case right
    case left
    case home
    case end
    case pageUp
    case pageDown
    case function(Int)
    case text(String)
}

/// Pure key encoding for `term.input`. `ctrl`/`alt` model the one-shot
/// modifiers of the iOS accessory bar; SwiftTerm's hardware and software
/// keyboard path encodes its own keys, so this is used for bar presses and is
/// covered by Linux tests.
public enum TerminalInputEncoder {
    /// Ctrl maps ASCII to its C0 control byte (^A = 0x01, ^@ = NUL, ...).
    public static func controlByte(_ character: Character) -> UInt8? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.value < 128 else { return nil }
        switch character {
        case "a"..."z":
            return UInt8(scalar.value - 96)
        case "A"..."Z":
            return UInt8(scalar.value - 64)
        case "@":
            return 0
        case "[":
            return 27
        case "\\":
            return 28
        case "]":
            return 29
        case "^":
            return 30
        case "_":
            return 31
        case "?":
            return 127
        case " ":
            return 0
        default:
            return nil
        }
    }

    /// The xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    private static func modifierParameter(ctrl: Bool, alt: Bool) -> Int {
        1 + (alt ? 2 : 0) + (ctrl ? 4 : 0)
    }

    private static func csi(_ body: String) -> [UInt8] {
        [0x1b, 0x5b] + Array(body.utf8)
    }

    private static func sequence(for key: TerminalKey, ctrl: Bool, alt: Bool) -> [UInt8]? {
        let modifier = modifierParameter(ctrl: ctrl, alt: alt)
        let modified = ctrl || alt
        switch key {
        case .escape:
            return [0x1b]
        case .tab:
            return [0x09]
        case .enter:
            return [0x0d]
        case .backspace:
            return [0x7f]
        case .delete:
            return csi(modified ? "3;\(modifier)~" : "3~")
        case .insert:
            return csi(modified ? "2;\(modifier)~" : "2~")
        case .up, .down, .right, .left:
            let final: String
            switch key {
            case .up: final = "A"
            case .down: final = "B"
            case .right: final = "C"
            default: final = "D"
            }
            return csi(modified ? "1;\(modifier)\(final)" : final)
        case .home:
            return csi(modified ? "1;\(modifier)H" : "H")
        case .end:
            return csi(modified ? "1;\(modifier)F" : "F")
        case .pageUp:
            return csi(modified ? "5;\(modifier)~" : "5~")
        case .pageDown:
            return csi(modified ? "6;\(modifier)~" : "6~")
        case .function(let number):
            return functionKey(number, modifier: modifier, modified: modified)
        case .text(let text):
            return nil // handled by bytes(forText:)
        }
    }

    private static func functionKey(_ number: Int, modifier: Int, modified: Bool) -> [UInt8] {
        switch number {
        case 1...4:
            let final = ["P", "Q", "R", "S"][number - 1]
            if modified { return csi("1;\(modifier)\(final)") }
            // xterm sends F1–F4 as SS3 (ESC O P) with no modifier.
            return [0x1b, 0x4f] + Array(final.utf8)
        case 5: return csi(modified ? "15;\(modifier)~" : "15~")
        case 6: return csi(modified ? "17;\(modifier)~" : "17~")
        case 7: return csi(modified ? "18;\(modifier)~" : "18~")
        case 8: return csi(modified ? "19;\(modifier)~" : "19~")
        case 9: return csi(modified ? "20;\(modifier)~" : "20~")
        case 10: return csi(modified ? "21;\(modifier)~" : "21~")
        case 11: return csi(modified ? "23;\(modifier)~" : "23~")
        case 12: return csi(modified ? "24;\(modifier)~" : "24~")
        default: return []
        }
    }

    /// Encode a key press. Alt prefixes ESC for text; for CSI sequences the
    /// modifier is part of the sequence instead.
    public static func bytes(for key: TerminalKey, ctrl: Bool = false, alt: Bool = false) -> Data {
        if case .text(let text) = key {
            return bytes(forText: text, ctrl: ctrl, alt: alt)
        }
        var bytes = sequence(for: key, ctrl: ctrl, alt: alt) ?? []
        if alt, key == .escape || key == .tab || key == .enter || key == .backspace {
            bytes.insert(0x1b, at: 0)
        }
        return Data(bytes)
    }

    /// Encode typed text (accessory-bar characters, not paste). Ctrl applies to
    /// each ASCII character; a character with no Ctrl mapping passes through.
    public static func bytes(forText text: String, ctrl: Bool = false, alt: Bool = false) -> Data {
        var bytes: [UInt8] = []
        if alt { bytes.append(0x1b) }
        for character in text {
            if ctrl, let control = controlByte(character) {
                // Ctrl+Space (NUL) included: controlByte covers it.
                bytes.append(control)
            } else {
                bytes.append(contentsOf: String(character).utf8)
            }
        }
        return Data(bytes)
    }
}

/// Sticky, one-shot Ctrl/Alt state for the accessory bar. `consume()` clears
/// both; SwiftTerm's own keyboard modifiers post reset notifications that the
/// UI forwards here.
public final class TerminalInputState {
    public private(set) var ctrl = false
    public private(set) var alt = false

    public init() {}

    public func toggleControl() { ctrl.toggle() }
    public func toggleAlt() { alt.toggle() }
    public func setControl(_ value: Bool) { ctrl = value }
    public func setAlt(_ value: Bool) { alt = value }
    public func clear() { ctrl = false; alt = false }

    /// Read and clear the one-shot modifiers.
    public func consume() -> (ctrl: Bool, alt: Bool) {
        let result = (ctrl, alt)
        clear()
        return result
    }
}

// MARK: - Resize debounce

/// Trailing debounce for `term.resize` (100 ms, as on the desktop). The
/// scheduler is injectable so Linux tests are deterministic.
public final class TerminalResizeDebouncer {
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    public static let mainScheduler: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public var interval: TimeInterval
    public var onResize: ((String, Int, Int) -> Void)?

    private let scheduler: Scheduler
    private var generation = 0
    private var pendingId: String?
    private var pendingCols = 0
    private var pendingRows = 0

    public init(interval: TimeInterval = 0.1, scheduler: @escaping Scheduler = TerminalResizeDebouncer.mainScheduler) {
        self.interval = interval
        self.scheduler = scheduler
    }

    /// Record the latest size. Only the size current when the timer fires is
    /// sent, so a rotation or a live keyboard animation produces one resize.
    public func request(id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        generation += 1
        let expected = generation
        pendingId = id
        pendingCols = cols
        pendingRows = rows
        scheduler(interval) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.fire()
        }
    }

    /// Send now (tests, and before leaving the screen).
    public func flush() {
        generation += 1
        fire()
    }

    public func cancel() {
        generation += 1
        pendingId = nil
    }

    private func fire() {
        guard let id = pendingId else { return }
        pendingId = nil
        onResize?(id, pendingCols, pendingRows)
    }
}

// MARK: - Terminal store

/// All terminals reported by the hub, plus this app's attach/subscription
/// state and the terminal input/resize flows. Pure Foundation, so it is
/// exercised by the Linux tests with a fake socket.
public final class TerminalStore {
    public private(set) var terms: [TermInfo] = []
    /// Terminals this app is currently subscribed to (cleared on disconnect).
    public private(set) var attached: Set<String> = []
    /// Terminals a mounted view wants; survives a socket drop so they can be
    /// re-attached after the welcome frame.
    public private(set) var wanted: Set<String> = []
    public private(set) var currentId: String?
    /// Exit codes for terminals that disappeared. Kept for the pane's banner.
    public private(set) var exitCodes: [String: Int] = [:]

    public var onChange: (() -> Void)?

    public let inputState: TerminalInputState
    public let resizeDebouncer: TerminalResizeDebouncer

    public init(
        inputState: TerminalInputState = TerminalInputState(),
        resizeDebouncer: TerminalResizeDebouncer = TerminalResizeDebouncer()
    ) {
        self.inputState = inputState
        self.resizeDebouncer = resizeDebouncer
        resizeDebouncer.onResize = { [weak self] id, cols, rows in
            self?.sendResize(id: id, cols: cols, rows: rows)
        }
    }

    /// Called by the store when a debounced resize is ready. The app wires this
    /// to the socket; tests capture the frames directly.
    public var onResizeFrame: ((ClientFrame) -> Void)?
    public var onFrame: ((ClientFrame) -> Void)?

    // MARK: Lists

    public func apply(terms: [TermInfo]) {
        self.terms = terms
        let alive = Set(terms.filter(\.alive).map(\.id))
        attached.formIntersection(alive)
        wanted.formIntersection(alive)
        if let currentId, !alive.contains(currentId) {
            self.currentId = nil
        }
        onChange?()
    }

    public func apply(opened: TermInfo) {
        if let index = terms.firstIndex(where: { $0.id == opened.id }) {
            terms[index] = opened
        } else {
            terms.append(opened)
        }
        exitCodes.removeValue(forKey: opened.id)
        onChange?()
    }

    public func apply(exit id: String, code: Int) {
        terms.removeAll { $0.id == id }
        attached.remove(id)
        wanted.remove(id)
        if currentId == id { currentId = nil }
        exitCodes[id] = code
        onChange?()
    }

    public func term(id: String) -> TermInfo? {
        terms.first { $0.id == id }
    }

    public var aliveTerms: [TermInfo] {
        terms.filter(\.alive)
    }

    // MARK: Open / attach / close

    /// `term.open`. Returns nil for an invalid size, so a view that has not
    /// laid out yet can never open the shell at a made-up 80×24.
    public func openFrame(cwd: String?, cols: Int, rows: Int, plain: Bool, rid: String? = nil) -> ClientFrame? {
        guard cols > 0, rows > 0 else { return nil }
        let folder = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .termOpen(cwd: (folder?.isEmpty ?? true) ? nil : folder, cols: cols, rows: rows, plain: plain, rid: rid)
    }

    /// `term.attach` for a live terminal. Re-attaching the same id is a no-op.
    @discardableResult
    public func attach(_ id: String) -> ClientFrame? {
        guard let term = term(id: id), term.alive else { return nil }
        wanted.insert(id)
        currentId = id
        guard !attached.contains(id) else { return nil }
        attached.insert(id)
        return .termAttach(id: id)
    }

    /// The view disappeared: stop wanting the terminal (a later reconnect must
    /// not re-attach it). Use `connectionLost()` for a socket drop instead.
    public func viewClosed(_ id: String) {
        wanted.remove(id)
        attached.remove(id)
        if currentId == id { currentId = nil }
    }

    public func closeFrame(_ id: String) -> ClientFrame? {
        guard term(id: id) != nil else { return nil }
        return .termClose(id: id)
    }

    /// The socket dropped. Subscriptions are gone, but the mounted views still
    /// want their terminals, so they are re-attached after the next welcome.
    public func connectionLost() {
        attached.removeAll()
    }

    /// Attach every still-wanted live terminal. Called after `welcome`; the
    /// hub replays the buffer, which redraws each terminal view.
    public func reattachFrames() -> [ClientFrame] {
        let alive = Set(aliveTerms.map(\.id))
        let ids = wanted.intersection(alive).sorted()
        attached.formUnion(ids)
        return ids.map { ClientFrame.termAttach(id: $0) }
    }

    // MARK: Input / resize

    public func inputFrame(_ data: Data) -> ClientFrame? {
        guard let id = currentId, attached.contains(id) else { return nil }
        return .termInput(id: id, dataBase64: data.base64EncodedString())
    }

    /// Encode a key press with the one-shot modifiers and send it to the
    /// current terminal. The modifiers are cleared afterwards.
    public func inputFrame(key: TerminalKey) -> ClientFrame? {
        let modifiers = inputState.consume()
        return inputFrame(TerminalInputEncoder.bytes(for: key, ctrl: modifiers.ctrl, alt: modifiers.alt))
    }

    public func inputFrame(text: String) -> ClientFrame? {
        let modifiers = inputState.consume()
        return inputFrame(TerminalInputEncoder.bytes(forText: text, ctrl: modifiers.ctrl, alt: modifiers.alt))
    }

    public func requestResize(id: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0, term(id: id)?.alive == true else { return }
        resizeDebouncer.request(id: id, cols: cols, rows: rows)
    }

    public func flushResize() {
        resizeDebouncer.flush()
    }

    private func sendResize(id: String, cols: Int, rows: Int) {
        guard term(id: id)?.alive == true else { return }
        let frame = ClientFrame.termResize(id: id, cols: cols, rows: rows)
        onResizeFrame?(frame)
        onFrame?(frame)
    }

    // MARK: Output

    /// Decode a `term.output` frame's base64 payload to raw bytes. `replay`
    /// frames and live frames use the same path.
    public static func decodeOutput(_ frame: TermOutputFrame) -> Data? {
        Data(base64Encoded: frame.data)
    }

    public static func decodeOutput(_ frame: TermOutputFrame, handler: (Data) -> Void) {
        if let data = decodeOutput(frame) { handler(data) }
    }
}

// MARK: - Style

/// The fixed readable ANSI palettes from docs/design/linux.md §v6/§9. The
/// app converts these to `UIColor` and passes them to SwiftTerm's
/// `installColors`.
public enum TerminalPalette {
    public static let dark: [String] = [
        "#1F1E1D", "#E06C6C", "#9ECE6A", "#E0B04F",
        "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0C0B8",
        "#77756E", "#F7768E", "#B9F27C", "#FFD479",
        "#9AB8FF", "#D0A9FF", "#A4E8FF", "#F5F4EF",
    ]

    public static let light: [String] = [
        "#1F1E1D", "#B53333", "#3D7A2A", "#9A6A12",
        "#2F5EA8", "#7A3E9D", "#1C7285", "#5C5A54",
        "#77756E", "#C14444", "#4C8A36", "#B07C1C",
        "#3C6FBE", "#8A4DAE", "#247F94", "#1F1E1D",
    ]

    public static func hex(isDark: Bool) -> [String] {
        isDark ? dark : light
    }
}
