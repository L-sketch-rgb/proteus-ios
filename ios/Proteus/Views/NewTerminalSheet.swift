import SwiftUI
import ProteusKit

/// "+" in the Terminals section: pick a starting folder, then push a
/// terminal screen that opens at its first measured size.
struct NewTerminalSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let onOpen: (String) -> Void

    @State private var folder: String
    @State private var folderPickerShown = false

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
        _folder = State(initialValue: "")
    }

    private var suggestions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for candidate in app.recentFolders where !candidate.isEmpty {
            if seen.insert(candidate).inserted { out.append(candidate) }
        }
        return Array(out.prefix(6))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Folder (default: home)", text: $folder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            folderPickerShown = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("The shell starts in this folder. It uses the same login shell as the desktop.")
                }

                if !suggestions.isEmpty {
                    Section("Recent folders") {
                        ForEach(suggestions, id: \.self) { path in
                            Button {
                                folder = path
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((path as NSString).lastPathComponent)
                                        .foregroundStyle(.primary)
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Toggle("Show shell greeting", isOn: $app.showShellGreeting)
                        .onChange(of: app.showShellGreeting) { _, value in
                            UserDefaults.standard.set(value, forKey: "proteus.terminal.showGreeting")
                        }
                }
            }
            .navigationTitle("New Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
                        onOpen(path)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $folderPickerShown) {
                FolderPickerSheet(
                    title: "Terminal folder",
                    initialPath: folder.isEmpty ? app.defaultFolder : folder
                ) { path in
                    folder = path
                }
            }
        }
    }
}
