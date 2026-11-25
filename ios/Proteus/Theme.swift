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

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

extension View {
    /// Frosted card. Uses Liquid Glass on iOS 26 and ultra-thin material before it.
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Translucent navigation-bar surface (material on every OS).
    func glassToolbar() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// v10 §15.1: one dismissible banner per connection when the hub predates
/// some of this app's optional features.
struct OldHubBanner: View {
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct ConnectionBanner: View {
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
        .background(.ultraThinMaterial)
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
            Text(title)
                .lineLimit(1)
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
