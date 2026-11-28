import SwiftUI
import UIKit
import ProteusKit

/// Workstations: the phone's list of machines, and one button to add another.
///
/// v19 §4.2: it used to be a `Form` with a list, a four-field add-form, a
/// paragraph about the Keychain and a second "Connection" card — four things to
/// read before the one thing it does. Adding lives behind `＋` now, the token
/// note is one line under the list, and the connection state is the dot on the
/// active machine.
struct WorkstationsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @State private var showAdd = false
    @State private var removeTarget: Workstation?

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                machineCard

                if app.activeWorkstationId == nil, !app.workstations.isEmpty {
                    PanelCard("Connection") {
                        PanelRow(showsChevron: false) {
                            Text("Tap a machine to connect.")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }

                Text("The token is kept in the iOS Keychain and sent only to the machine you enter.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textMeta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
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
        .navigationTitle("Workstations")
        .navigationBarTitleDisplayMode(.inline)
        .chromeToolbar(theme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add workstation")
            }
        }
        .themedSheet(isPresented: $showAdd) {
            AddWorkstationSheet()
        }
        .confirmationDialog(
            "Remove this workstation?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { machine in
            Button("Remove \(machine.name)", role: .destructive) {
                app.removeWorkstation(machine)
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { _ in
            Text("Its token is deleted from the Keychain on this phone. Chats already open stay on the machine.")
        }
    }

    private var machineCard: some View {
        PanelCard("Workstations") {
            if app.workstations.isEmpty {
                PanelRow(showsChevron: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No machine yet")
                            .foregroundStyle(theme.textPrimary)
                        Text("Add the address and token your hub prints on first run.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textMeta)
                    }
                }
            }

            ForEach(Array(app.workstations.enumerated()), id: \.element.id) { index, machine in
                Button {
                    app.activate(machine)
                } label: {
                    PanelRow(showsChevron: false) {
                        HStack(spacing: 10) {
                            StatusDot(state: dot(for: machine), size: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                    .foregroundStyle(theme.textPrimary)
                                Text("\(machine.host):\(machine.port)")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(theme.textMeta)
                            }
                            Spacer(minLength: 8)
                            if app.activeWorkstationId == machine.id {
                                Text(app.connection.label)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .contextMenu {
                    Button {
                        app.activate(machine)
                    } label: {
                        Label("Connect", systemImage: "bolt")
                    }
                    Button(role: .destructive) {
                        removeTarget = machine
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        removeTarget = machine
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }

                if index < app.workstations.count - 1 {
                    Hairline().padding(.leading, 16)
                }
            }

            Hairline().padding(.leading, 16)

            Button {
                showAdd = true
            } label: {
                PanelRow(showsChevron: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add workstation")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    /// The dot means what it means everywhere else: live, or nothing yet.
    private func dot(for machine: Workstation) -> StatusDot.Kind {
        guard app.activeWorkstationId == machine.id else { return .idle }
        switch app.connection {
        case .connected: return .working
        case .connecting, .reconnecting: return .working
        default: return .error
        }
    }
}

// MARK: - Add

/// Three fields, one button, in a sheet — the add-form is not something to read
/// on the way past.
private struct AddWorkstationSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "7878"
    @State private var token = ""

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    PanelCard("Machine") {
                        field("Name", text: $name, hint: "Workstation")
                        Hairline().padding(.leading, 16)
                        field("Host or IP", text: $host, hint: "192.0.2.10", keyboard: .URL)
                        Hairline().padding(.leading, 16)
                        field("Port", text: $port, hint: "7878", keyboard: .numberPad)
                        Hairline().padding(.leading, 16)
                        field("Token", text: $token, hint: "from the hub's first run", secure: true)
                    }

                    if let error = app.errorText {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.statusError)
                            Text(error)
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }

                    Text("The token is kept in the iOS Keychain and sent only to this machine.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textMeta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(theme.readingSurface)
            .navigationTitle("Add workstation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if app.addWorkstation(name: name, host: host, portText: port, token: token) {
                            dismiss()
                        }
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        hint: String,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        PanelRow(showsChevron: false) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textMeta)
                if secure {
                    SecureField(hint, text: text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField(hint, text: text)
                        .keyboardType(keyboard)
                }
            }
        }
    }
}
