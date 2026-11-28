import SwiftUI
import ProteusKit

/// The desktop's Inspector drawer, adapted to a sheet (docs/design/v18-ios.md §5.2).
///
/// One sheet, one control row, three tabs: Agents, Pins, Terminal. Files keeps
/// its own full-screen sheet for now; it becomes the fourth tab with the v17
/// place browser.
enum InspectorTab: String, CaseIterable, Identifiable {
    case agents
    case pins
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .pins: return "Pins"
        case .terminal: return "Terminal"
        }
    }

    var icon: String {
        switch self {
        case .agents: return "gearshape.2.fill"
        case .pins: return "pin.fill"
        case .terminal: return "terminal"
        }
    }
}

struct InspectorSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.proteusTheme) private var theme

    @ObservedObject var chat: ChatSessionModel
    @Binding var tab: InspectorTab
    var onAgent: ((TaskData) -> Void)?
    var onPin: ((Pin) -> Void)?

    /// The terminal keeps its PTY while the other tabs are shown; it is only
    /// built once the tab is first used, so opening the inspector never starts
    /// a shell.
    @State private var terminalVisited = false

    init(
        chat: ChatSessionModel,
        tab: Binding<InspectorTab>,
        onAgent: ((TaskData) -> Void)? = nil,
        onPin: ((Pin) -> Void)? = nil
    ) {
        self.chat = chat
        self._tab = tab
        self.onAgent = onAgent
        self.onPin = onPin
    }

    private var pinCount: Int {
        app.pins(for: chat.id).count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                content
            }
            .background(theme.readingSurface)
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .onChange(of: tab) { _, value in
            if value == .terminal { terminalVisited = true }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(InspectorTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Chip(
                        title: chipTitle(item),
                        selected: tab == item,
                        dot: dot(item),
                        icon: item.icon
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ProteusTheme.Space.gutter)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private func chipTitle(_ item: InspectorTab) -> String {
        switch item {
        case .agents:
            let running = chat.runningTasks
            return running > 0 ? "Agents \(running)" : "Agents"
        case .pins:
            return pinCount > 0 ? "Pins \(pinCount)" : "Pins"
        case .terminal:
            return "Terminal"
        }
    }

    private func dot(_ item: InspectorTab) -> StatusDot.Kind? {
        if item == .agents, chat.runningTasks > 0 { return .working }
        return nil
    }

    /// All tabs stay mounted so switching never loses a running terminal or a
    /// scroll position.
    private var content: some View {
        ZStack {
            AgentsSheet(chat: chat, onSelect: onAgent, embedded: true)
                .opacity(tab == .agents ? 1 : 0)
                .allowsHitTesting(tab == .agents)

            PinsSheet(chat: chat, onSelect: onPin, embedded: true)
                .opacity(tab == .pins ? 1 : 0)
                .allowsHitTesting(tab == .pins)

            if terminalVisited {
                TerminalScreen(target: .new(cwd: chat.session?.cwd ?? ""))
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
            }
        }
    }
}
