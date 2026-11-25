import SwiftUI

/// Shared pieces of the v15 design language, sized for fingers
/// (docs/design/v18-ios.md §2). Everything here reads `\.proteusTheme`.

// MARK: - Status

/// The five states of the desktop's `StatusDot.qml`, with the same meaning:
/// working pulses, amber needs you, filled unread, red error, hollow idle.
struct StatusDot: View {
    enum Kind: Equatable {
        case working
        case needsYou
        case unread
        case error
        case idle
    }

    let state: Kind
    var size: CGFloat

    @Environment(\.proteusTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    init(state: Kind, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    private var fill: Color {
        switch state {
        case .working: return theme.statusWorking
        case .needsYou: return theme.statusNeedsYou
        case .unread: return theme.textPrimary
        case .error: return theme.statusError
        case .idle: return .clear
        }
    }

    var body: some View {
        Circle()
            .fill(fill)
            .overlay {
                if state == .idle {
                    Circle().strokeBorder(theme.statusIdleRim, lineWidth: 1)
                }
            }
            .frame(width: size, height: size)
            .opacity(state == .working && pulsing ? 1 : (state == .working ? 0.55 : 1))
            .animation(pulseAnimation, value: pulsing)
            .onAppear { pulsing = state == .working && !reduceMotion }
            .onChange(of: state) { _, newValue in
                pulsing = newValue == .working && !reduceMotion
            }
            .accessibilityHidden(true)
    }

    private var pulseAnimation: Animation? {
        guard state == .working, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
    }
}

// MARK: - Labels

/// 11.5 pt, semibold, caps, 6 % tracking — the desktop's section label.
struct SectionLabel: View {
    let text: String
    var count: Int?
    var trailing: String?

    @Environment(\.proteusTheme) private var theme

    init(text: String, count: Int? = nil, trailing: String? = nil) {
        self.text = text
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textMeta)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.textMeta.opacity(0.7))
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textMeta)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One chip in the rail or under the composer. 36 pt tall, capsule, 1 px rim.
struct Chip: View {
    let title: String
    var selected: Bool
    var dot: StatusDot.Kind?
    var icon: String?

    @Environment(\.proteusTheme) private var theme

    init(title: String, selected: Bool = false, dot: StatusDot.Kind? = nil, icon: String? = nil) {
        self.title = title
        self.selected = selected
        self.dot = dot
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                StatusDot(state: dot, size: 6)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
        .background(
            selected ? theme.selectedRow : theme.fieldFill,
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(selected ? theme.accent.opacity(0.55) : theme.rim, lineWidth: 1)
        }
    }
}

/// 36 pt visual, 44 pt touch target.
struct IconButton: View {
    let systemName: String
    let label: String
    var tint: Color?
    var badge: Int
    let action: () -> Void

    @Environment(\.proteusTheme) private var theme

    init(systemName: String, label: String, tint: Color? = nil, badge: Int = 0, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tint = tint
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(tint ?? theme.textSecondary)
                    .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.rim, lineWidth: 1)
                    }
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(theme.accent, in: Capsule())
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: 44, height: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Surfaces

/// L1: the calm layer messages and lists sit on, over the wave.
struct ReadingSurface: ViewModifier {
    let theme: ProteusTheme

    func body(content: Content) -> some View {
        content.background(theme.readingSurface)
    }
}

/// L2: translucent chrome with a hairline on one edge.
struct ChromeBar: ViewModifier {
    let theme: ProteusTheme
    var edge: Edge.Set = .bottom

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(theme.chrome)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 1)
            }
    }
}

/// The only bordered thing inside a chat: permission, question, plan and
/// change cards.
struct CardFrame: ViewModifier {
    let role: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                role.opacity(0.07),
                in: RoundedRectangle(cornerRadius: ProteusTheme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ProteusTheme.Radius.card, style: .continuous)
                    .strokeBorder(role.opacity(0.38), lineWidth: 1)
            }
    }
}

/// A settings page group: a card of rows with hairlines between them.
struct CardGroup<Content: View>: View {
    @Environment(\.proteusTheme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            theme.fieldFill,
            in: RoundedRectangle(cornerRadius: ProteusTheme.Radius.panel, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ProteusTheme.Radius.panel, style: .continuous)
                .strokeBorder(theme.rim, lineWidth: 1)
        }
    }
}

struct Hairline: View {
    @Environment(\.proteusTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
    }
}

// MARK: - Buttons

/// One primary action per screen: full-width, 50 pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: ProteusTheme.Radius.card, style: .continuous)
            )
    }
}

/// Everything else: bordered, quiet, 44 pt tall.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle(cornerRadius: ProteusTheme.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ProteusTheme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

/// Row highlight for a tappable list row.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear)
    }
}

// MARK: - Helpers

extension View {
    func readingSurface(_ theme: ProteusTheme) -> some View { modifier(ReadingSurface(theme: theme)) }
    func chromeBar(_ theme: ProteusTheme, edge: Edge.Set = .bottom) -> some View {
        modifier(ChromeBar(theme: theme, edge: edge))
    }
    func cardFrame(_ role: Color) -> some View { modifier(CardFrame(role: role)) }
}
