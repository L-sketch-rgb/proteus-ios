import SwiftUI
import ProteusKit

/// The three places a phone app needs (v18 §0):
///
///     Chats · Terminals · Files · Settings
///
/// Files is the fourth tab: the Files.app-style place browser (hub `fs.*`). Each
/// tab owns its own `NavigationStack`, so switching tabs never loses a chat.
enum ProteusTab: Hashable {
    case chats
    case terminals
    case files
    case settings
}

struct ProteusRootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @State private var tab: ProteusTab = .chats
    @State private var didRouteDemo = false

    /// Waiting or errored chats, so the tab bar can say something needs you.
    private var needsYou: Int {
        app.sessions.filter { $0.statusKind == .waiting || $0.statusKind == .error }.count
    }

    var body: some View {
        TabView(selection: $tab) {
            WaveTab { ChatsHomeView() }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .badge(needsYou)
                .tag(ProteusTab.chats)

            WaveTab { TerminalsHomeView() }
                .tabItem { Label("Terminals", systemImage: "terminal") }
                .tag(ProteusTab.terminals)

            FilesPanelView(isTab: true)
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(ProteusTab.files)

            WaveTab { SettingsView(showsDoneButton: false) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(ProteusTab.settings)
        }
        .tint(theme.accent)
        .toolbarBackground(theme.chrome, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear { routeDemoTab() }
        .onChange(of: app.pendingOpenChatId) { _, id in
            // A tapped notification always lands on the chat, whichever tab
            // happened to be open.
            if id != nil { tab = .chats }
        }
    }

    /// `-ProteusDemoScreen=<name>` still selects a tab for the CI screenshots;
    /// the chats tab routes its own screens.
    private func routeDemoTab() {
        guard app.isDemo, !didRouteDemo else { return }
        didRouteDemo = true
        switch app.demoScreen {
        case "terminal":
            tab = .terminals
        case "settings", "accounts", "workstations":
            tab = .settings
        default:
            break
        }
    }
}

/// One tab, with the wave underneath it.
///
/// See `screenWave()`: the wave has to be drawn inside the tab's navigation
/// content, not behind the `TabView` and not even here — the tab controller and
/// the navigation container each fill their view with `systemBackground`, which
/// is what hid the dither in every build before 1.1 (docs/DECISIONS.md D55).
private struct WaveTab<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}
