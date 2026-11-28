import SwiftUI
import Foundation
import ProteusKit

/// Settings: a card stack on the panel (docs/design/v19-ios-shell.md §4).
///
/// Not a `Form`. On iOS a `Form` paints `systemGroupedBackground` — white on
/// white in light mode, an opaque sheet in dark — so the v18 tokens never
/// reached this screen and the wave never showed around it. Cards on the
/// reading surface do, and the section label lives inside its card.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// v18: Settings is a tab on the phone, so there is nothing to dismiss.
    /// It stays `true` when the screen is presented as a sheet.
    var showsDoneButton = true

    @AppStorage("proteus.theme") private var themeRaw = AppTheme.dark.rawValue
    @AppStorage("proteus.palette") private var paletteKey = "blue"
    @AppStorage("proteus.animatedBackground") private var animatedBackground = true
    @AppStorage("proteus.backgroundIntensity") private var backgroundIntensity = 0.8
    @AppStorage(TextScale.key) private var textScale = TextScale.default
    @AppStorage("proteus.terminal.fontSize") private var terminalFontSize = 12.0

    @State private var slotEditor: CustomSlotTarget?
    @State private var demoRoute: DemoSettingsRoute?

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var currentPalette: Palette {
        app.resolvedPalette(for: paletteKey).palette
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    workstationsCard
                    notificationsCard
                    accountsCard
                    modelCard
                    appearanceCard
                    terminalsCard
                    aboutCard
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                // 76 pt clears the floating tab bar (§0.3, §4).
                .padding(.bottom, 76)
            }
            .scrollIndicators(.hidden)
            .background(theme.readingSurface)
            .clipShape(panelShape)
            .overlay { panelShape.strokeBorder(theme.rim, lineWidth: 1) }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .screenWave()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .chromeToolbar(theme)
            .navigationDestination(item: $demoRoute) { route in
                switch route {
                case .workstations: WorkstationsView()
                case .accounts: AccountsProvidersView()
                }
            }
            .onAppear { routeDemoIfNeeded() }            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .themedSheet(item: $slotEditor) { target in
            CustomColorPickerSheet(initialIndex: target.index, initialSlot: target.slot)
        }
    }

    // MARK: - Cards

    private var workstationsCard: some View {
        PanelCard("Workstations") {
            NavigationLink {
                WorkstationsView()
            } label: {
                PanelRow {
                    HStack(spacing: 10) {
                        StatusDot(state: app.hasWorkstation ? .working : .idle, size: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.activeWorkstation?.name ?? "No workstation")
                                .foregroundStyle(theme.textPrimary)
                            Text(workstationDetail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textMeta)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(app.connection.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var notificationsCard: some View {
        PanelCard("Notifications") {
            NavigationLink {
                NotificationsView()
            } label: {
                PanelRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Push notifications")
                            .foregroundStyle(theme.textPrimary)
                        Text(notificationDetail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textMeta)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var accountsCard: some View {
        PanelCard("Accounts & providers") {
            NavigationLink {
                AccountsProvidersView()
            } label: {
                PanelRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountsTitle)
                            .foregroundStyle(theme.textPrimary)
                        if !app.providers.isEmpty {
                            Text(app.providers.map { app.prettyProvider($0) }.joined(separator: " · "))
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textMeta)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var modelCard: some View {
        PanelCard("Default model") {
            PanelRow(showsChevron: false) {
                ModelMenuButton(
                    title: app.modelLabel(for: app.defaultModel),
                    menu: app.modelMenu,
                    selected: app.defaultModel,
                    onSelect: { app.setDefaultModel($0) }
                )
            }
        }
    }

    private var appearanceCard: some View {
        PanelCard("Appearance") {
            field {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Hairline().padding(.leading, 16)

            field {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Palette")
                    paletteGrid
                }
            }

            Hairline().padding(.leading, 16)

            field { customPaletteRow }

            Hairline().padding(.leading, 16)

            field {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Background intensity")
                            .foregroundStyle(theme.textBody)
                        Spacer(minLength: 8)
                        Text("\(Int((backgroundIntensity * 100).rounded()))%")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.textMeta)
                    }
                    DitherSwatch(palette: currentPalette, intensity: backgroundIntensity)
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.rim, lineWidth: 1)
                        }
                        .accessibilityHidden(true)
                    Slider(value: $backgroundIntensity, in: 0...1, step: 0.05)
                        .disabled(!animatedBackground)
                        .accessibilityLabel("Background intensity")
                }
            }

            Hairline().padding(.leading, 16)

            row {
                Toggle("Animated background", isOn: $animatedBackground)
                    .foregroundStyle(theme.textBody)
            }

            Hairline().padding(.leading, 16)

            field {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text size")
                            .foregroundStyle(theme.textBody)
                        Spacer(minLength: 8)
                        Text("\(textScale)%")
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.textMeta)
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
            }
        }
    }

    private var terminalsCard: some View {
        PanelCard("Terminals") {
            row {
                Toggle("Show shell greeting", isOn: $app.showShellGreeting)
                    .foregroundStyle(theme.textBody)
                    .onChange(of: app.showShellGreeting) { _, value in
                        UserDefaults.standard.set(value, forKey: "proteus.terminal.showGreeting")
                    }
            }

            Hairline().padding(.leading, 16)

            row {
                HStack(spacing: 10) {
                    Text("Terminal text size")
                        .foregroundStyle(theme.textBody)
                    Spacer(minLength: 8)
                    Stepper(
                        value: $terminalFontSize,
                        in: Double(TerminalController.minFontSize)...Double(TerminalController.maxFontSize),
                        step: 1
                    ) {
                        Text("\(Int(terminalFontSize)) pt")
                            .font(.system(size: 15))
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                    }
                    .labelsHidden()
                    Text("\(Int(terminalFontSize)) pt")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }

            Text("Off hides your shell's startup greeting in new terminals. Terminals already open keep their setting.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMeta)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutCard: some View {
        PanelCard("About") {
            PanelRow(showsChevron: false) {
                Text("Version")
                    .foregroundStyle(theme.textBody)
                Spacer(minLength: 8)
                Text(appVersion)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }

            Hairline().padding(.leading, 16)

            PanelRow(showsChevron: false) {
                Text("Hub")
                    .foregroundStyle(theme.textBody)
                Spacer(minLength: 8)
                Text(app.hubVersion ?? "—")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }

            Hairline().padding(.leading, 16)

            Button {
                app.reconnect()
            } label: {
                PanelRow(showsChevron: false) {
                    Text("Reconnect")
                        .foregroundStyle(app.hasWorkstation ? theme.accent : theme.textMeta)
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(!app.hasWorkstation)

            Hairline().padding(.leading, 16)

            Text("MIT licensed. Built from the same protocol the desktop speaks.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMeta)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rows

    /// A row with no chevron: a toggle, a slider, a menu.
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        PanelRow(showsChevron: false, content: content)
    }

    /// A row that is a block of controls: padded on both axes, no 52 pt floor.
    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Details

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

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Palette

    private var paletteGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            ForEach(PaletteCatalog.palettes) { palette in
                paletteSwatch(palette)
            }
        }
    }

    /// 48 pt of the palette's own dither, not four dots: the thumbnail is the
    /// thing being chosen (v19 §4).
    private func paletteSwatch(_ palette: Palette) -> some View {
        let selected = palette.key == paletteKey
        return Button {
            paletteKey = palette.key
        } label: {
            VStack(spacing: 6) {
                DitherSwatch(palette: palette, intensity: 0.85)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(selected ? theme.accent : theme.rim, lineWidth: selected ? 1.5 : 1)
                    }
                Text(palette.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Custom slots (v7)

    private var customPaletteRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Custom")
                Spacer(minLength: 8)
                Text("Synced across your devices")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textMeta)
            }
            HStack(spacing: 12) {
                ForEach(0..<AppearanceStore.slotCount, id: \.self) { index in
                    customSlot(index)
                }
                Spacer(minLength: 0)
            }
        }
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
                            .strokeBorder(selected ? theme.accent : theme.rim, lineWidth: 2)
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
                            theme.textMeta,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textMeta)
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add custom slot \(index + 1)")
        }
    }

    // MARK: - Demo routing

    /// `-ProteusDemoScreen=workstations|accounts` — the two screens 1.3 rewrote,
    /// so CI captures them instead of taking my word for it.
    private enum DemoSettingsRoute: String, Identifiable {
        case workstations
        case accounts

        var id: String { rawValue }
    }

    private func routeDemoIfNeeded() {
        guard app.isDemo else { return }
        switch app.demoScreen {
        case "workstations":
            DispatchQueue.main.async { demoRoute = .workstations }
        case "accounts":
            DispatchQueue.main.async { demoRoute = .accounts }
        default:
            break
        }
    }
}

// MARK: - Sheet target

private struct CustomSlotTarget: Identifiable {
    let index: Int
    let slot: AppearanceSlot?
    var id: Int { index }
}
