import SwiftUI
import ProteusKit

/// The v15/v16 design tokens, ported to the phone (docs/design/v18-ios.md §1).
///
/// The desktop's sheet is the source of truth for colours, layers and roles.
/// Sizes are *not* copied one-to-one: a 34 pt desktop row is a 56 pt touch
/// target here, and 13.5 pt desktop text becomes the system body size. What
/// carries over is the layer model, the status language, the radii family and
/// the type roles.
///
/// Injected once by `ProteusRootView` and read with
/// `@Environment(\.proteusTheme)`.
struct ProteusTheme: Equatable {
    var isDark: Bool
    var accent: Color

    // MARK: Layers (back to front)

    /// L1. Messages and lists. Translucent enough that the wave reads through,
    /// never blurred.
    var readingSurface: Color
    /// L2. Navigation bar, tab bar, composer, the project rail.
    var chrome: Color
    /// L3. Menus and popovers held inside a screen.
    var popover: Color
    /// L4. Sheets.
    var sheet: Color
    /// v19 §5: the terminal is the one opaque surface in the app — glyphs over
    /// a moving dither are unreadable. Everything around it is the panel model.
    var terminalSurface: Color

    // MARK: Lines and fills

    var rim: Color
    var hairline: Color
    /// v19: the tile and card fill inside a panel.
    var cardFill: Color
    var fieldFill: Color
    var pressedRow: Color
    var selectedRow: Color
    var hoverRow: Color

    // MARK: Text

    var textPrimary: Color
    var textBody: Color
    var textSecondary: Color
    var textMeta: Color

    // MARK: Status

    var statusWorking: Color
    var statusNeedsYou: Color
    var statusError: Color
    var statusIdleRim: Color

    init(isDark: Bool, accent: Color) {
        self.isDark = isDark
        self.accent = accent

        if isDark {
            // v19 §1: 0.94. The dither no longer runs under the text — that was
            // what made every list hard to read even with good contrast. The
            // wave now lives in the 10 pt gutter and behind the chrome bands.
            readingSurface = Color(hex: "#13151C").opacity(0.94)
            chrome = Color(hex: "#171A21").opacity(0.80)
            popover = Color(hex: "#1D2333").opacity(0.92)
            sheet = Color(hex: "#181C27").opacity(0.94)
            terminalSurface = Color(hex: "#0E1016")
            rim = Color.white.opacity(0.09)
            hairline = Color.white.opacity(0.055)
            cardFill = Color.white.opacity(0.035)
            fieldFill = Color.white.opacity(0.05)
            pressedRow = Color.white.opacity(0.10)
            selectedRow = accent.opacity(0.20)
            hoverRow = Color.white.opacity(0.06)
            textPrimary = Color(hex: "#F2F4FA")
            textBody = Color(hex: "#E3E7F0")
            textSecondary = Color(hex: "#B3BBD0")
            textMeta = Color(hex: "#98A1B8")
            statusWorking = accent
            statusNeedsYou = Color(hex: "#E8B061")
            statusError = Color(hex: "#E5675C")
            statusIdleRim = Color.white.opacity(0.22)
        } else {
            // Light mode from the design-language board: the reading surface is
            // white at 86 % (72 % failed the 4.5:1 contrast check).
            readingSurface = Color.white.opacity(0.86)
            chrome = Color.white.opacity(0.72)
            popover = Color.white.opacity(0.96)
            sheet = Color.white.opacity(0.96)
            terminalSurface = Color(hex: "#F6F7FB")
            rim = Color.black.opacity(0.10)
            hairline = Color.black.opacity(0.08)
            cardFill = Color.black.opacity(0.04)
            fieldFill = Color.black.opacity(0.04)
            pressedRow = Color.black.opacity(0.08)
            selectedRow = accent.opacity(0.16)
            hoverRow = Color.black.opacity(0.05)
            textPrimary = Color(hex: "#14171F")
            textBody = Color(hex: "#1B1F29")
            textSecondary = Color(hex: "#4A5265")
            textMeta = Color(hex: "#6B748A")
            statusWorking = accent
            statusNeedsYou = Color(hex: "#B7791F")
            statusError = Color(hex: "#B53333")
            statusIdleRim = Color.black.opacity(0.22)
        }
    }

    // MARK: Radii

    enum Radius {
        static let chip: CGFloat = 8
        static let row: CGFloat = 9
        static let card: CGFloat = 12
        static let bubble: CGFloat = 14
        static let panel: CGFloat = 16
        static let composer: CGFloat = 18
        static let popover: CGFloat = 12
    }

    // MARK: Spacing

    enum Space {
        static let grid: CGFloat = 8
        static let gutter: CGFloat = 12
        static let screen: CGFloat = 16
        /// Every tappable row is at least this tall.
        static let touch: CGFloat = 44
    }

    /// The unread title weight and the dot state that belong to one session.
    func status(for status: SessionStatus, isUnread: Bool) -> StatusDot.Kind {
        switch status {
        case .running: return .working
        case .waiting: return .needsYou
        case .error: return .error
        case .idle, .stopped:
            return isUnread ? .unread : .idle
        }
    }
}

private struct ProteusThemeKey: EnvironmentKey {
    static let defaultValue = ProteusTheme(
        isDark: true,
        accent: Color(hex: "#5782D9")
    )
}

extension EnvironmentValues {
    var proteusTheme: ProteusTheme {
        get { self[ProteusThemeKey.self] }
        set { self[ProteusThemeKey.self] = newValue }
    }
}
