import SwiftUI
import ProteusKit

@main
struct ProteusApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("proteus.palette") private var paletteKey = "blue"
    @AppStorage("proteus.theme") private var themeRaw = AppTheme.system.rawValue
    @AppStorage("proteus.animatedBackground") private var animatedBackground = true
    @AppStorage("proteus.backgroundIntensity") private var backgroundIntensity = 0.8
    @AppStorage(TextScale.key) private var textScale = TextScale.default

    private var theme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .system
    }

    private var isDark: Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .system: return systemScheme == .dark
        }
    }

    private var palette: Palette {
        app.resolvedPalette(for: paletteKey).palette
    }

    private var accent: Color {
        palette.mode(dark: isDark).accentColor.color
    }

    var body: some View {
        ZStack {
            WaveBackground(
                palette: palette,
                animated: animatedBackground,
                intensity: backgroundIntensity
            )
            ChatsView()
        }
        .tint(accent)
        .environment(\.paletteAccent, accent)
        .preferredColorScheme(theme.colorScheme)
        .dynamicTypeSize(proteusDynamicTypeSize(percent: textScale))
        .onAppear { app.start() }
        .onOpenURL { url in
            // proteus://chat/<id> from an ntfy notification (v8 §3).
            _ = app.handleOpenURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.reconnect()
            case .background:
                // v9 §1: a draft is flushed when the app leaves the foreground.
                app.flushDrafts()
            default:
                break
            }
        }
    }
}
