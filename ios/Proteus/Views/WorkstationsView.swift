import SwiftUI

struct WorkstationsView: View {
    @EnvironmentObject private var app: AppModel

    @State private var name = ""
    @State private var host = ""
    @State private var port = "7878"
    @State private var token = ""

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if let error = app.errorText {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Workstations") {
                if app.workstations.isEmpty {
                    Text("No workstations yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.workstations) { workstation in
                    Button {
                        app.activate(workstation)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workstation.name)
                                    .foregroundStyle(.primary)
                                Text("\(workstation.host):\(workstation.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.activeWorkstationId == workstation.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            app.removeWorkstation(workstation)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            app.removeWorkstation(workstation)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }

            Section("Add workstation") {
                TextField("Name", text: $name)
                TextField("Host or IP", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                SecureField("Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Add and connect") {
                    let added = app.addWorkstation(name: name, host: host, portText: port, token: token)
                    if added {
                        name = ""
                        host = ""
                        port = "7878"
                        token = ""
                    }
                }
                .disabled(!canAdd)
            }

            Section {
                Text("The token is stored in the iOS Keychain. It is sent only to the workstation you enter here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent("Status") { Text(app.connection.label) }
                Button("Reconnect") { app.reconnect() }
                    .disabled(app.activeWorkstationId == nil)
            }
        }
        .navigationTitle("Workstations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
