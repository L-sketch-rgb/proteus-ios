import SwiftUI
import UIKit
import ProteusKit

/// Accounts & providers: one card per provider, one row per account.
///
/// v19 §4.2 replaced the per-account wall (two full-width usage bars, a status
/// line, a toggle, sign-in, an API-key field, Save, Clear, Rename, Remove and a
/// provider tag, all stacked in a `Form`) with: a row you can read, a compact
/// usage line, and everything that acts on the account behind its `…` menu.
struct AccountsProvidersView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @State private var showAddProvider = false
    @State private var addAccountTarget: AccountTarget?
    @State private var keyTarget: Account?
    @State private var renameTarget: Account?
    @State private var removeAccountTarget: Account?
    @State private var deleteProviderTarget: String?

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if app.providers.isEmpty {
                    PanelCard("Providers") {
                        PanelRow(showsChevron: false) {
                            Text("Nothing reported by the hub yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }

                ForEach(app.providers, id: \.self) { provider in
                    providerCard(provider)
                }

                PanelCard("Add") {
                    Button {
                        showAddProvider = true
                    } label: {
                        PanelRow(showsChevron: false) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Add provider")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(theme.accent)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
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
        .navigationTitle("Accounts & providers")
        .navigationBarTitleDisplayMode(.inline)
        .chromeToolbar(theme)
        .themedSheet(isPresented: $showAddProvider) {
            AddProviderSheet()
        }
        .themedSheet(item: $addAccountTarget) { target in
            AddAccountSheet(
                provider: target.provider,
                providerLabel: app.prettyProvider(target.provider),
                preset: ProviderPresets.all.first { $0.provider?.id == target.provider }
            )
        }
        .themedSheet(item: $keyTarget) { account in
            APIKeySheet(account: account)
        }
        .themedSheet(item: $renameTarget) { account in
            AccountRenameSheet(account: account) { label in
                app.renameAccount(account, label: label)
            }
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { removeAccountTarget != nil },
                set: { if !$0 { removeAccountTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeAccountTarget
        ) { account in
            Button("Remove \(account.label)", role: .destructive) {
                app.removeAccount(account)
                removeAccountTarget = nil
            }
            Button("Cancel", role: .cancel) { removeAccountTarget = nil }
        } message: { _ in
            Text("Its saved key is deleted from the workstation. Running chats fall back to the active account.")
        }
        .confirmationDialog(
            "Delete this provider?",
            isPresented: Binding(
                get: { deleteProviderTarget != nil },
                set: { if !$0 { deleteProviderTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteProviderTarget
        ) { provider in
            Button("Delete \(app.prettyProvider(provider))", role: .destructive) {
                app.deleteProvider(provider)
                deleteProviderTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteProviderTarget = nil }
        } message: { _ in
            Text("Its accounts and saved keys are removed from the workstation. Chats keep their transcripts.")
        }
    }

    // MARK: - One provider

    private func providerCard(_ provider: String) -> some View {
        let accounts = app.accounts(for: provider)
        return PanelCard(app.prettyProvider(provider)) {
            ForEach(accounts) { account in
                accountRow(account)

                Hairline().padding(.leading, 16)
            }

            Button {
                addAccountTarget = AccountTarget(provider: provider)
            } label: {
                PanelRow(showsChevron: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add account")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(theme.accent)
                }
            }
            .buttonStyle(RowButtonStyle())

            Hairline().padding(.leading, 16)

            Button {
                deleteProviderTarget = provider
            } label: {
                PanelRow(showsChevron: false) {
                    Text("Remove \(app.prettyProvider(provider))…")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.statusError)
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let isActive = app.isActiveAccount(account)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if !isActive { app.makeActive(account, now: false) }
            } label: {
                PanelRow(showsChevron: false) {
                    HStack(spacing: 10) {
                        StatusDot(state: isActive ? .working : .idle, size: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(subtitle(account))
                                .font(.system(size: 12.5))
                                .foregroundStyle(theme.textMeta)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let usage = usageLine(account) {
                            Text(usage)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.textMeta)
                                .lineLimit(1)
                        }
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.statusWorking)
                        }
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
            .contextMenu {
                accountMenu(account, isActive: isActive)
            }

            if let update = loginUpdate(for: account) {
                HStack(spacing: 6) {
                    Text(update.message ?? update.status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.statusNeedsYou)
                    if let raw = update.url, let url = URL(string: raw) {
                        Link("Open", destination: url)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func accountMenu(_ account: Account, isActive: Bool) -> some View {
        if !isActive {
            Button {
                app.makeActive(account, now: false)
            } label: {
                Label("Use this account", systemImage: "bolt")
            }
            if (account.provider ?? "claude") == "claude" {
                Button {
                    app.makeActive(account, now: true)
                } label: {
                    Label("Use and move running chats", systemImage: "arrow.left.arrow.right")
                }
            }
        }
        if account.isSubscription {
            Button {
                app.login(account)
            } label: {
                Label("Sign in", systemImage: "person.crop.circle.badge.checkmark")
            }
        } else {
            Button {
                keyTarget = account
            } label: {
                Label("API key…", systemImage: "key")
            }
        }
        Button {
            renameTarget = account
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            removeAccountTarget = account
        } label: {
            Label("Remove…", systemImage: "trash")
        }
    }

    // MARK: - Bits

    private func subtitle(_ account: Account) -> String {
        if let email = account.email, !email.isEmpty { return email }
        if let hint = app.keyHint(for: account) { return "Key stored \(hint)" }
        return "No key yet"
    }

    /// "5h 1% · 7d 95%" — one line instead of two full-width bars.
    private func usageLine(_ account: Account) -> String? {
        guard let usage = account.usage else { return nil }
        var parts: [String] = []
        if let window = usage.fiveHour { parts.append("5h \(Formatting.percent(window))") }
        if let window = usage.sevenDay { parts.append("7d \(Formatting.percent(window))") }
        if parts.isEmpty, let status = usage.status, !status.isEmpty { return status }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loginUpdate(for account: Account) -> LoginUpdate? {
        guard let update = app.loginUpdate, update.name == account.name else { return nil }
        return update
    }

    // MARK: - Sheets

    private struct AccountTarget: Identifiable {
        let provider: String
        var id: String { provider }
    }
}

// MARK: - Rename

private struct AccountRenameSheet: View {
    let account: Account
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $label)
            }
            .navigationTitle("Rename account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(label)
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if label.isEmpty { label = account.label } }
        }
        .presentationDetents([.height(200)])
    }
}

// MARK: - API key

/// The key field lives in its own sheet: it is not something to scroll past on
/// every account.
private struct APIKeySheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let account: Account

    @State private var key = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(account.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                if let hint = app.keyHint(for: account) {
                    Text("A key is already stored (\(hint)). Saving replaces it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textMeta)
                }

                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.rim, lineWidth: 1)
                    }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(theme.readingSurface)
            .navigationTitle("API key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.setKey(account, key: key)
                        dismiss()
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(280)])
    }
}
