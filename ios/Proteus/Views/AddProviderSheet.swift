import SwiftUI
import ProteusKit

/// "Add provider" from Accounts & providers. Offers the same presets as the
/// desktop; Anthropic and DeepSeek are one tap, custom is the
/// Anthropic-compatible form, OpenAI is greyed out until the Codex engine.
struct AddProviderSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: ProviderPreset?
    @State private var accountName = ""
    @State private var accountLabel = ""
    @State private var key = ""

    @State private var customID = ""
    @State private var customLabel = ""
    @State private var customBaseURL = ""
    @State private var customSanitize = ""
    @State private var customModelKey = "flash"
    @State private var customEngineModel = ""
    @State private var customModelLabel = ""
    @State private var customTier = "fast"

    private var isCustom: Bool { selected?.isCustom == true }

    private var canSave: Bool {
        guard let selected else { return false }
        guard !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !selected.isCustom { return true }
        return !customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !customEngineModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    ForEach(ProviderPresets.all) { preset in
                        Button {
                            select(preset)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected?.id == preset.id
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                    .foregroundStyle(selected?.id == preset.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.label)
                                        .foregroundStyle(preset.isDisabled ? .secondary : .primary)
                                    Text(preset.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(preset.isDisabled)
                    }
                }

                if let selected {
                    if selected.isCustom {
                        Section("Custom provider") {
                            TextField("Provider id (e.g. mylab)", text: $customID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Label", text: $customLabel)
                            TextField("Base URL", text: $customBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            TextField("Key sanitize pattern (optional)", text: $customSanitize)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Section("Model") {
                            TextField("Menu key (e.g. flash)", text: $customModelKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Engine model id", text: $customEngineModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Label", text: $customModelLabel)
                            Picker("Tier", selection: $customTier) {
                                Text("Strongest").tag("top")
                                Text("Balanced").tag("mid")
                                Text("Fastest").tag("fast")
                            }
                        }
                    }

                    Section("Account") {
                        TextField("Account name", text: $accountName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Label", text: $accountLabel)
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section {
                    } footer: {
                        Text("The key goes to the workstation and is never stored on this phone.")
                    }
                }
            }
            .navigationTitle("Add Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func select(_ preset: ProviderPreset) {
        selected = preset
        accountName = preset.provider?.id ?? ""
        accountLabel = preset.accountLabel ?? preset.label
        key = ""
        if preset.isCustom {
            customID = ""
            customLabel = ""
            customBaseURL = ""
            customSanitize = ""
            customModelKey = "flash"
            customEngineModel = ""
            customModelLabel = ""
            customTier = "fast"
        }
    }

    private func save() {
        guard let selected else { return }
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: ProviderConfig
        if let preset = selected.provider {
            provider = preset
        } else {
            let id = customID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitize = customSanitize.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelKey = customModelKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let engine = customEngineModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelLabel = customModelLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            provider = ProviderConfig(
                id: id,
                kind: "anthropic-compatible",
                label: customLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                baseUrl: base.isEmpty ? nil : base,
                sanitize: sanitize.isEmpty ? nil : sanitize,
                models: [
                    ProviderModelConfig(
                        key: modelKey.isEmpty ? "default" : modelKey,
                        engineModel: engine,
                        label: modelLabel.isEmpty ? engine : modelLabel,
                        tier: customTier
                    ),
                ]
            )
        }
        app.saveProvider(
            provider,
            accountName: name,
            accountLabel: label.isEmpty ? name : label,
            key: key
        )
        dismiss()
    }
}

/// Adds another account under an existing provider (no provider.save).
struct AddAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let provider: String
    let providerLabel: String
    let preset: ProviderPreset?

    @State private var name = ""
    @State private var label = ""
    @State private var key = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(providerLabel) account") {
                    TextField("Account name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Label", text: $label)
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        app.addAccount(provider: provider, name: name, label: label.isEmpty ? name : label)
                        if !key.isEmpty {
                            app.setKey(accountName: name, key: key)
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
