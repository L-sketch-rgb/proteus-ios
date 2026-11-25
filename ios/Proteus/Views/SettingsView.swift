import SwiftUI
import Foundation
import ProteusKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// v18: Settings is a tab on the phone, so there is nothing to dismiss.
    /// It stays `true` when the screen is presented as a sheet.
    var showsDoneButton = true

    @AppStorage("proteus.theme") private var themeRaw = AppTheme.system.rawValue
    @AppStorage("proteus.palette") private var paletteKey = "blue"
    @AppStorage("proteus.animatedBackground") private var animatedBackground = true
    @AppStorage("proteus.backgroundIntensity") private var backgroundIntensity = 0.8
    @AppStorage(TextScale.key) private var textScale = TextScale.default
    @State private var slotEditor: CustomSlotTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section("Workstations") {
                    NavigationLink {
                        WorkstationsView()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.activeWorkstation?.name ?? "No workstation")
                                Text(workstationDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(app.connection.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Notifications") {
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push notifications")
                            Text(notificationDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Accounts & providers") {
                    NavigationLink {
                        AccountsProvidersView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountsTitle)
                            if !app.providers.isEmpty {
                                Text(app.providers.map { app.prettyProvider($0) }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Default model") {
                    ModelMenuButton(
                        title: app.modelLabel(for: app.defaultModel),
                        menu: app.modelMenu,
                        selected: app.defaultModel,
                        onSelect: { app.setDefaultModel($0) }
                    )
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    paletteGrid

                    customPaletteRow

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(textScale)%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(textScale) },
                                set: { textScale = Int($0.rounded()) }
                            ),
                            in: Double(TextScale.minimum)...Double(TextScale.maximum),
                            step: 5
                        )
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(textScale) percent")
                    }

                    Toggle("Animated background", isOn: $animatedBackground)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Background intensity")
                            Spacer()
                            Text("\(Int((backgroundIntensity * 100).rounded()))%")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $backgroundIntensity, in: 0...1, step: 0.05)
                            .disabled(!animatedBackground)
                            .accessibilityLabel("Background intensity")
                    }
                }

                Section {
                    Toggle("Show shell greeting", isOn: $app.showShellGreeting)
                        .onChange(of: app.showShellGreeting) { _, value in
                            UserDefaults.standard.set(value, forKey: "proteus.terminal.showGreeting")
                        }
                } header: {
                    Text("Terminals")
                } footer: {
                    Text("Off hides your shell's startup greeting in new terminals. Terminals already open keep their setting.")
                }

                Section("Connection") {
                    LabeledContent("Status") { Text(app.connection.label) }
                    LabeledContent("Hub") { Text(app.hubVersion ?? "—") }
                    Button("Reconnect") { app.reconnect() }
                        .disabled(!app.hasWorkstation)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .sheet(item: $slotEditor) { target in
            CustomColorPickerSheet(initialIndex: target.index, initialSlot: target.slot)
        }
    }

    /// "1 account", never "1 accounts".
    private var accountsTitle: String {
        switch app.accounts.count {
        case 0: return "No accounts"
        case 1: return "1 account"
        default: return "\(app.accounts.count) accounts"
        }
    }

    private var workstationDetail: String {
        guard let workstation = app.activeWorkstation else {
            return "Add one to connect"
        }
        return "\(workstation.host):\(workstation.port)"
    }

    private var notificationDetail: String {
        guard app.notificationSettings.enabled else { return "Off" }
        guard let host = URL(string: app.notificationSettings.server)?.host else {
            return "On"
        }
        return "On via \(host)"
    }

    private var paletteGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette")
                .font(.subheadline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(PaletteCatalog.palettes) { palette in
                    paletteSwatch(palette)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func paletteSwatch(_ palette: Palette) -> some View {
        let isSelected = palette.key == paletteKey
        let mode = palette.mode(dark: colorScheme == .dark)
        return Button {
            paletteKey = palette.key
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(mode.waves.indices, id: \.self) { index in
                        Circle()
                            .fill(mode.waves[index].color)
                            .frame(width: 14, height: 14)
                    }
                }
                Text(palette.label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                Color.primary.opacity(isSelected ? 0.12 : 0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom slots (v7)

    private var customPaletteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Custom")
                    .font(.subheadline)
                Spacer()
                Text("Synced across your devices")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(0..<AppearanceStore.slotCount, id: \.self) { index in
                    customSlot(index)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func customSlot(_ index: Int) -> some View {
        let slot = index < app.appearanceSlots.count ? app.appearanceSlots[index] : nil
        if let slot {
            let selected = paletteKey == "custom:\(index)"
            Button {
                paletteKey = "custom:\(index)"
            } label: {
                Circle()
                    .fill(Color(hex: slot.color))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                            .frame(width: 42, height: 42)
                    }
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit…") {
                    slotEditor = CustomSlotTarget(index: index, slot: slot)
                }
                Button("Clear", role: .destructive) {
                    app.clearAppearanceSlot(at: index)
                }
            }
            .accessibilityLabel("Custom slot \(index + 1)")
        } else {
            Button {
                slotEditor = CustomSlotTarget(index: index, slot: nil)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            Color.secondary,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add custom slot \(index + 1)")
        }
    }
}

private struct CustomSlotTarget: Identifiable {
    let index: Int
    let slot: AppearanceSlot?
    var id: Int { index }
}
