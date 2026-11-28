import SwiftUI
import Foundation
import ProteusKit

struct AccountsProvidersView: View {
    @EnvironmentObject private var app: AppModel

    @State private var showAddProvider = false
    @State private var addAccountTarget: AccountTarget?
    @State private var deleteProviderTarget: String?

    var body: some View {
        Form {
            if app.providers.isEmpty {
                Section {
                    Text("No accounts reported by the hub.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(app.providers, id: \.self) { provider in
                Section {
                    ForEach(app.accounts(for: provider)) { account in
                        AccountRow(account: account, isActive: app.isActiveAccount(account))
                    }
                    Button {
                        addAccountTarget = AccountTarget(provider: provider)
                    } label: {
                        Label("Add account", systemImage: "person.badge.plus")
                    }
                } header: {
                    HStack {
                        Text(app.prettyProvider(provider))
                        Spacer()
                        Menu {
                            Button {
                                addAccountTarget = AccountTarget(provider: provider)
                            } label: {
                                Label("Add account", systemImage: "person.badge.plus")
                            }
                            Button(role: .destructive) {
                                deleteProviderTarget = provider
                            } label: {
                                Label("Delete provider…", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("\(app.prettyProvider(provider)) actions")
                    }
                }
            }
        }
        .navigationTitle("Accounts & providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddProvider = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add provider")
            }
        }
        .sheet(isPresented: $showAddProvider) {
            AddProviderSheet()
        }
        .sheet(item: $addAccountTarget) { target in
            AddAccountSheet(
                provider: target.provider,
                providerLabel: app.prettyProvider(target.provider),
                preset: ProviderPresets.all.first { $0.provider?.id == target.provider }
            )
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
}

private struct AccountTarget: Identifiable {
    let provider: String
    var id: String { provider }
}

private struct AccountRow: View {
    @EnvironmentObject private var app: AppModel

    let account: Account
    let isActive: Bool

    @State private var key = ""
    @State private var showRename = false
    @State private var newLabel = ""
    @State private var moveRunningNow = false
    @State private var confirmRemove = false

    private var loginUpdate: LoginUpdate? {
        guard let update = app.loginUpdate, update.name == account.name else { return nil }
        return update
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                        .font(.body.weight(.medium))
                    if let email = account.email, !email.isEmpty {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let hint = app.keyHint(for: account) {
                        Text("Key stored \(hint)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Use") {
                        app.makeActive(account, now: moveRunningNow)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }

            UsageBar(title: "5 h", window: account.usage?.fiveHour)
            UsageBar(title: "7 d", window: account.usage?.sevenDay)

            if let status = account.usage?.status, !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isActive, (account.provider ?? "claude") == "claude" {
                Toggle("Move running sessions now", isOn: $moveRunningNow)
                    .font(.caption)
                    .accessibilityHint("When on, chats that are running switch to this account immediately.")
            }

            if account.isSubscription {
                Button("Sign in") { app.login(account) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if let update = loginUpdate {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(update.message ?? update.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let raw = update.url, let url = URL(string: raw) {
                            Link("Open sign-in page", destination: url)
                                .font(.caption2)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        app.setKey(account, key: key)
                        key = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if app.keyHint(for: account) != nil {
                        Button("Clear", role: .destructive) {
                            app.setKey(account, key: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Rename") {
                    newLabel = account.label
                    showRename = true
                }
                .font(.caption)
                .buttonStyle(.borderless)

                Button("Remove", role: .destructive) {
                    confirmRemove = true
                }
                .font(.caption)
                .buttonStyle(.borderless)

                Spacer()

                Text(account.provider ?? "claude")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .alert("Rename account", isPresented: $showRename) {
            TextField("Label", text: $newLabel)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                app.renameAccount(account, label: newLabel)
            }
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove \(account.label)", role: .destructive) {
                app.removeAccount(account)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saved key is deleted from the workstation. Running chats fall back to the active account.")
        }
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            ProgressView(value: window?.utilization ?? 0)
                .progressViewStyle(.linear)

            Text(Formatting.percent(window))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .opacity(window == nil ? 0.6 : 1)
    }
}
