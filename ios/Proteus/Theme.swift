import SwiftUI
import ProteusKit

// MARK: - Palette colors

extension RGB {
    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension Color {
    /// Parse `#RRGGBB`; falls back to grey for an invalid string.
    init(hex: String) {
        if let rgb = RGB(hex: hex) {
            self = rgb.color
        } else {
            self = .gray
        }
    }
}

private struct PaletteAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var paletteAccent: Color {
        get { self[PaletteAccentKey.self] }
        set { self[PaletteAccentKey.self] = newValue }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Status

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: return .green
        case .waiting: return .orange
        case .error: return .red
        case .idle, .stopped: return .secondary
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .error: return "Error"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        }
    }
}

// MARK: - Glass

private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.proteusTheme) private var theme

    /// The app's own card surface (the `popover` token with the `rim` line),
    /// not the system glass/material, which renders a plain grey.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(theme.popover, in: shape)
            .overlay { shape.strokeBorder(theme.rim, lineWidth: 1) }
    }
}

extension View {
    /// Frosted card. Uses Liquid Glass on iOS 26 and ultra-thin material before it.
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// The v19 chrome band (docs/design/v19-ios-shell.md §1): the palette's
    /// chrome colour, not a material, so the wave still reads behind the bar.
    /// A material would blur the dither into a grey smear.
    func chromeToolbar(_ theme: ProteusTheme) -> some View {
        self
            .toolbarBackground(theme.chrome, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Sheets

private struct ThemedSheetStyle: ViewModifier {
    @Environment(\.proteusTheme) private var theme

    /// A sheet in the app's colours: the `sheet` token behind it (not the
    /// system grey or a material), lists and forms without their grouped grey
    /// page, and the app's chrome band on its navigation bar.
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .toolbarBackground(theme.chrome, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .presentationBackground(theme.sheet)
    }
}

extension View {
    func themedSheetStyle() -> some View { modifier(ThemedSheetStyle()) }

    /// `.sheet` whose content gets `themedSheetStyle`.
    func themedSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().themedSheetStyle() }
    }

    func themedSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).themedSheetStyle() }
    }
}

// MARK: - Shared bits

enum ChatColors {
    static let cardFill = Color.primary.opacity(0.055)
    static let assistantFill = Color.primary.opacity(0.045)
    static let userFill = Color.accentColor.opacity(0.22)
    static let errorFill = Color.red.opacity(0.12)
}

struct ErrorBanner: View {
    @Environment(\.proteusTheme) private var theme
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(theme.popover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// v10 §15.1: one dismissible banner per connection when the hub predates
/// some of this app's optional features.
struct OldHubBanner: View {
    @Environment(\.proteusTheme) private var theme
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Your hub is older than this app. Some features are off until you update it.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(theme.popover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ConnectionBanner: View {
    @Environment(\.proteusTheme) private var theme
    let state: ConnectionState
    let hasWorkstation: Bool
    let onRetry: () -> Void

    private var text: String {
        switch state {
        case .idle:
            return hasWorkstation ? "Not connected" : "No workstation — add one in Settings"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .reconnecting(let attempt, let delay):
            return "Reconnecting (try \(attempt), in \(Int(delay))s)"
        case .disconnected(let reason):
            return reason
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if hasWorkstation, state != .connected {
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(theme.chrome)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .red
        case .idle: return .secondary
        }
    }
}

// MARK: - Model menus

struct ModelMenuButton: View {
    let title: String
    let menu: ModelMenu
    let selected: String
    /// v19 §2.4: the new-chat screen wants this as one chip in a row, not a
    /// full-width menu row.
    var chip: Bool = false
    let onSelect: (String) -> Void

    private func display(_ model: ModelInfo, in section: ModelSection, includeProvider: Bool) -> String {
        let check = model.id == selected ? "✓ " : ""
        if includeProvider {
            return "\(check)\(section.title) · \(model.label)"
        }
        return "\(check)\(model.label)"
    }

    var body: some View {
        Menu {
            let includeProvider = menu.sections.count > 1
            ForEach(menu.sections) { section in
                ForEach(section.models) { model in
                    Button {
                        onSelect(model.id)
                    } label: {
                        Text(display(model, in: section, includeProvider: includeProvider))
                    }
                }
            }
            if !menu.more.isEmpty {
                Divider()
                Menu("More models") {
                    ForEach(menu.more) { section in
                        ForEach(section.models) { model in
                            Button {
                                onSelect(model.id)
                            } label: {
                                Text(moreLabel(model, in: section))
                            }
                            .disabled(!model.available)
                        }
                    }
                }
            }
        } label: {
            if chip {
                Chip(title: title, icon: "cpu")
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
    }

    private func moreLabel(_ model: ModelInfo, in section: ModelSection) -> String {
        let check = model.id == selected ? "✓ " : ""
        let base = "\(check)\(section.title) · \(model.label)"
        if !model.available {
            return base + " — " + unavailableNote(model)
        }
        return base
    }

    private func unavailableNote(_ model: ModelInfo) -> String {
        switch model.unavailableReason {
        case "credits": return "Needs usage credits"
        default: return "Unavailable"
        }
    }
}
