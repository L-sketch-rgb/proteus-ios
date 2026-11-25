import SwiftUI
import UIKit
import SwiftTerm
import ProteusKit

/// What a terminal screen is showing: a terminal opened elsewhere, or a new
/// one to open at the first measured size.
enum TerminalTarget: Hashable {
    case existing(String)
    case new(cwd: String)

    var existingId: String? {
        if case .existing(let id) = self { return id }
        return nil
    }

    var initialTitle: String {
        switch self {
        case .existing: return "Terminal"
        case .new(let cwd): return cwd.isEmpty ? "Terminal" : (cwd as NSString).lastPathComponent
        }
    }
}

// MARK: - Controller

/// Owns the SwiftTerm view and the open/attach/input flow for one screen.
/// Kept out of the SwiftUI view so layout callbacks, the open reply, and
/// terminal output can be correlated without capturing stale state.
final class TerminalController: ObservableObject {
    let terminal: TerminalView

    @Published private(set) var termId: String?
    @Published private(set) var title: String
    @Published private(set) var ctrlActive = false
    @Published private(set) var altActive = false

    private weak var app: AppModel?
    private var target: TerminalTarget = .new(cwd: "")
    private var showGreeting = false
    private var opening = false
    private var pendingRid: String?
    private var latestSize = (cols: 0, rows: 0)
    /// The last replay chunk reset the screen; the next live chunk ends it.
    private var inReplay = false

    private(set) var fontSize: CGFloat
    private var displayScale: CGFloat = 1
    private var pinchBase: CGFloat = 0

    static let fontSizeKey = "proteus.terminal.fontSize"
    static let defaultFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 24

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.fontSizeKey) as? Double
        let size = CGFloat(stored ?? Double(Self.defaultFontSize))
        fontSize = min(Self.maxFontSize, max(Self.minFontSize, size))
        let percent = UserDefaults.standard.object(forKey: "proteus.textScale") as? Int ?? 100
        displayScale = CGFloat(min(1.5, max(0.8, Double(percent) / 100)))
        terminal = TerminalView(
            frame: .zero,
            font: Self.font(size: fontSize * displayScale)
        )
        title = "Terminal"
        // The SwiftUI accessory bar replaces SwiftTerm's built-in one.
        terminal.inputAccessoryView = nil
        terminal.nativeBackgroundColor = .clear
        terminal.layer.backgroundColor = UIColor.clear.cgColor
        terminal.isOpaque = false
        terminal.installColors(Self.ansiColors(isDark: true))
        terminal.nativeForegroundColor = UIColor(white: 0.96, alpha: 1)
    }

    private static func font(size: CGFloat) -> UIFont {
        UIFont(name: "Menlo", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Wiring

    func bind(app: AppModel, target: TerminalTarget, showGreeting: Bool) {
        self.app = app
        self.target = target
        self.showGreeting = showGreeting
        title = target.initialTitle
        if latestSize.cols > 0 {
            handleSize(cols: latestSize.cols, rows: latestSize.rows)
        }
    }

    /// The view went away: stop wanting the terminal so a reconnect does not
    /// re-attach it.
    func unbind() {
        if let id = termId {
            app?.detachTerminalView(id)
        }
        termId = nil
        app = nil
    }

    // MARK: Layout / open

    func handleSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        latestSize = (cols, rows)
        guard let app else { return }

        if app.isDemo {
            if termId == nil {
                termId = "demo-term"
                title = "demo — zsh"
                terminal.feed(byteArray: [UInt8](app.demoTerminalBytes())[...])
            }
            return
        }

        switch target {
        case .existing(let id):
            if termId == nil {
                termId = id
                title = app.terminalStore.term(id: id)?.title ?? target.initialTitle
                app.attachTerminal(id)
            } else if termId == id {
                app.resizeTerminal(id: id, cols: cols, rows: rows)
            }
        case .new(let cwd):
            if let id = termId {
                app.resizeTerminal(id: id, cols: cols, rows: rows)
            } else if !opening {
                opening = true
                pendingRid = app.openTerminal(
                    cwd: cwd,
                    cols: cols,
                    rows: rows,
                    plain: !showGreeting
                )
                if pendingRid == nil { opening = false }
            }
        }
    }

    /// `term.opened` may arrive after a later layout pass; resize to the latest
    /// measured size then, because the open used the size at press time.
    func handleOpened(_ id: String) {
        guard termId == nil, opening, case .new = target else { return }
        guard let app else { return }
        opening = false
        pendingRid = nil
        termId = id
        title = app.terminalStore.term(id: id)?.title ?? target.initialTitle
        if latestSize.cols > 0 {
            app.resizeTerminal(id: id, cols: latestSize.cols, rows: latestSize.rows)
        }
    }

    // MARK: Output

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        terminal.feed(byteArray: [UInt8](data)[...])
    }

    func feedReplayAware(_ chunk: TerminalChunk) {
        if chunk.replay && !inReplay {
            // A fresh replay after a socket drop starts from an empty screen,
            // so the same buffer is not appended twice.
            terminal.feed(text: "\u{1B}c")
        }
        inReplay = chunk.replay
        feed(chunk.data)
    }

    // MARK: Input

    func toggleControl() {
        terminal.controlModifier.toggle()
        refreshModifiers()
    }

    func toggleAlt() {
        terminal.metaModifier.toggle()
        refreshModifiers()
    }

    func refreshModifiers() {
        ctrlActive = terminal.controlModifier
        altActive = terminal.metaModifier
    }

    private func clearModifiers() {
        terminal.controlModifier = false
        terminal.metaModifier = false
        refreshModifiers()
    }

    func sendKey(_ key: TerminalKey) {
        let bytes = TerminalInputEncoder.bytes(
            for: key,
            ctrl: terminal.controlModifier,
            alt: terminal.metaModifier
        )
        clearModifiers()
        let raw = [UInt8](bytes)
        terminal.send(data: raw[...])
    }

    func sendText(_ text: String) {
        let bytes = TerminalInputEncoder.bytes(
            forText: text,
            ctrl: terminal.controlModifier,
            alt: terminal.metaModifier
        )
        clearModifiers()
        let raw = [UInt8](bytes)
        terminal.send(data: raw[...])
    }

    func hideKeyboard() {
        terminal.resignFirstResponder()
    }

    func publishTitle(_ value: String) {
        title = value
    }

    func input(_ data: Data) {
        app?.terminalInput(data)
    }

    // MARK: Font

    func beginPinch() {
        pinchBase = fontSize
    }

    func updatePinch(scale: CGFloat) {
        setFontSize(pinchBase * scale, persist: false)
    }

    func endPinch() {
        UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
    }

    func setFontSize(_ size: CGFloat, persist: Bool) {
        let clamped = min(Self.maxFontSize, max(Self.minFontSize, size.rounded()))
        guard clamped != fontSize else {
            if persist { endPinch() }
            return
        }
        fontSize = clamped
        terminal.font = Self.font(size: clamped * displayScale)
        if persist { endPinch() }
    }

    /// Settings → Appearance → interface size scales the terminal too.
    func applyTextScale(percent: Double) {
        displayScale = CGFloat(min(1.5, max(0.8, percent / 100)))
        terminal.font = Self.font(size: fontSize * displayScale)
    }

    // MARK: Colours

    func applyColors(isDark: Bool) {
        terminal.installColors(Self.ansiColors(isDark: isDark))
        let hex = isDark ? "#F5F4EF" : "#1F1E1D"
        terminal.nativeForegroundColor = UIColor(hexString: hex) ?? (isDark ? .white : .black)
        terminal.nativeBackgroundColor = .clear
        terminal.layer.backgroundColor = UIColor.clear.cgColor
        terminal.isOpaque = false
    }

    private static func ansiColors(isDark: Bool) -> [SwiftTerm.Color] {
        let hexes = TerminalPalette.hex(isDark: isDark)
        return hexes.map { hex in
            let rgb = Self.rgb(from: hex)
            return SwiftTerm.Color(red8: rgb.0, green8: rgb.1, blue8: rgb.2)
        }
    }

    private static func rgb(from hex: String) -> (UInt16, UInt16, UInt16) {
        var value: UInt64 = 0
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        Scanner(string: digits).scanHexInt64(&value)
        return (
            UInt16((value >> 16) & 0xFF),
            UInt16((value >> 8) & 0xFF),
            UInt16(value & 0xFF)
        )
    }
}

extension UIColor {
    convenience init?(hexString: String) {
        var digits = hexString
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - UIViewRepresentable

private struct TerminalViewRepresentable: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalView {
        let view = controller.terminal
        view.terminalDelegate = context.coordinator
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        private weak var controller: TerminalController?

        init(controller: TerminalController) {
            self.controller = controller
        }

        func installGestures(on view: TerminalView) {
            guard !(view.gestureRecognizers ?? []).contains(where: { $0 is UIPinchGestureRecognizer }) else {
                return
            }
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller else { return }
            switch gesture.state {
            case .began:
                controller.beginPinch()
            case .changed:
                let scale = gesture.scale
                controller.updatePinch(scale: scale)
            case .ended, .cancelled, .failed:
                controller.endPinch()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller?.handleSize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            guard let controller, !title.isEmpty else { return }
            controller.publishTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller?.input(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

// MARK: - Screen

struct TerminalScreen: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.proteusTheme) private var theme

    @StateObject private var controller = TerminalController()
    @State private var didBind = false
    @AppStorage("proteus.textScale") private var textScale = TextScale.default

    let target: TerminalTarget

    private var exitCode: Int? {
        guard let id = controller.termId else { return nil }
        return app.terminalExits[id]
    }

    var body: some View {
        screen
            .onAppear {
                guard !didBind else { return }
                didBind = true
                controller.bind(
                    app: app,
                    target: target,
                    showGreeting: app.showShellGreeting
                )
                controller.applyColors(isDark: colorScheme == .dark)
                controller.applyTextScale(percent: Double(textScale))
            }
            .onDisappear {
                controller.unbind()
            }
            .onChange(of: colorScheme) { _, newValue in
                controller.applyColors(isDark: newValue == .dark)
            }
            .onChange(of: textScale) { _, newValue in
                controller.applyTextScale(percent: Double(newValue))
            }
            .onReceive(app.terminalOutput) { chunk in
                guard let id = controller.termId, id == chunk.id else { return }
                controller.feedReplayAware(chunk)
            }
            .onReceive(app.$lastTerminalOpenId) { id in
                guard let id else { return }
                controller.handleOpened(id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { _ in
                controller.refreshModifiers()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalViewMetaModifierReset)) { _ in
                controller.refreshModifiers()
            }
    }

    /// The view tree on its own. Release whole-module optimisation gave up on
    /// `body` while the ZStack, the accessory inset, the toolbar menu and eight
    /// lifecycle modifiers were one expression: "the compiler is unable to
    /// type-check this expression in reasonable time" (TerminalScreen:491).
    private var screen: some View {
        ZStack(alignment: .top) {
            TerminalViewRepresentable(controller: controller)
                .background(theme.terminalSurface)
                // Text must not start under the panel's rounded corner.
                .padding(.horizontal, 10)
                .padding(.top, 8)

            if let code = exitCode {
                HStack(spacing: 8) {
                    Image(systemName: "termination")
                        .foregroundStyle(theme.statusNeedsYou)
                    Text("Shell exited (code \(code)).")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Close") {
                        if let id = controller.termId {
                            app.closeTerminal(id)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(10)
                .background(theme.popover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .background(theme.terminalSurface)
        .clipShape(panelShape)
        .overlay { panelShape.strokeBorder(theme.rim, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .screenWave()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalAccessoryBar(
                controller: controller,
                onKey: { controller.sendKey($0) },
                onText: { controller.sendText($0) },
                onHideKeyboard: { controller.hideKeyboard() }
            )
        }
        .navigationTitle(controller.title)
        .navigationBarTitleDisplayMode(.inline)
        .chromeToolbar(theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                controller.sendKey(.escape)
            } label: {
                Label("Send Esc", systemImage: "escape")
            }
            Button {
                controller.sendKey(.tab)
            } label: {
                Label("Send Tab", systemImage: "arrow.right.to.line")
            }
            Divider()
            Button {
                controller.setFontSize(controller.fontSize - 1, persist: true)
            } label: {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            Button {
                controller.setFontSize(controller.fontSize + 1, persist: true)
            } label: {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            Divider()
            Button(role: .destructive) {
                if let id = controller.termId {
                    app.closeTerminal(id)
                }
            } label: {
                Label("Close terminal", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

// MARK: - Accessory bar

private struct TerminalAccessoryBar: View {
    @ObservedObject var controller: TerminalController
    @Environment(\.proteusTheme) private var theme
    let onKey: (TerminalKey) -> Void
    let onText: (String) -> Void
    let onHideKeyboard: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                barButton("esc") { onKey(.escape) }
                barButton("tab") { onKey(.tab) }
                toggleButton("ctrl", active: controller.ctrlActive) {
                    controller.toggleControl()
                }
                toggleButton("alt", active: controller.altActive) {
                    controller.toggleAlt()
                }
                Divider().frame(height: 20)
                repeatButton("arrow.up") { onKey(.up) }
                repeatButton("arrow.down") { onKey(.down) }
                repeatButton("arrow.left") { onKey(.left) }
                repeatButton("arrow.right") { onKey(.right) }
                Divider().frame(height: 20)
                ForEach(["|", "~", "/", "-"], id: \.self) { character in
                    barButton(character) { onText(character) }
                }
                Divider().frame(height: 20)
                repeatButton("delete.left") { onKey(.backspace) }
                IconBarButton(systemName: "keyboard.chevron.compact.down") {
                    onHideKeyboard()
                }
                .accessibilityLabel("Hide keyboard")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
        }
        .chromeBar(theme, edge: .top)
    }

    private func barButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(minWidth: 30, minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func toggleButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(
                    (active ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func repeatButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        RepeatingIconButton(systemName: systemName, action: action)
    }
}

private struct IconBarButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(minWidth: 30, minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A key that repeats while held, like a hardware key: one press immediately,
/// then repeats after a short delay while the finger stays down.
private struct RepeatingIconButton: View {
    let systemName: String
    let action: () -> Void

    @State private var task: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .frame(minWidth: 32, minHeight: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard task == nil else { return }
                        action()
                        task = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 380_000_000)
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(nanoseconds: 80_000_000)
                            }
                        }
                    }
                    .onEnded { _ in
                        task?.cancel()
                        task = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
    }
}
