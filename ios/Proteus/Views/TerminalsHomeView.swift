import SwiftUI
import ProteusKit

/// Terminals as their own destination (v18 §4).
///
/// The desktop folded terminals into the Inspector drawer. On a phone a tab is
/// cheaper to reach than a drawer, and shells started on the workstation stay
/// visible even when there are no chats.
struct TerminalsHomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.proteusTheme) private var theme

    @State private var path = NavigationPath()
    @State private var showNew = false
    @State private var didRouteDemo = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if app.terminals.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(app.terminals) { term in
                            NavigationLink(value: TerminalTarget.existing(term.id)) {
                                TerminalRowView(term: term)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.hairline)
                            .listRowInsets(EdgeInsets(top: 0, leading: ProteusTheme.Space.screen, bottom: 0, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    app.closeTerminal(term.id)
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                        }
                    } header: {
                        SectionLabel(text: "Open on your workstation", count: app.terminals.count)
                            .frame(minHeight: 32)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.readingSurface)
            .navigationTitle("Terminals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New terminal")
                }
            }
            .navigationDestination(for: TerminalTarget.self) { target in
                TerminalScreen(target: target)
            }
            .onAppear {
                DispatchQueue.main.async { routeDemoIfNeeded() }
            }
        }
        .sheet(isPresented: $showNew) {
            NewTerminalSheet { cwd in
                showNew = false
                DispatchQueue.main.async {
                    path.append(TerminalTarget.new(cwd: cwd))
                }
            }
        }
    }

    // MARK: - Demo routing

    /// `-ProteusDemoScreen=terminal` opens the demo shell itself, so the CI
    /// screenshot shows output and the accessory bar, not the list (§4).
    private func routeDemoIfNeeded() {
        guard app.isDemo, app.demoScreen == "terminal", !didRouteDemo else { return }
        didRouteDemo = true
        if let first = app.terminals.first {
            path.append(TerminalTarget.existing(first.id))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("No shells open")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Start one here, or open a terminal in any chat's ⋯ menu. Shells keep running on the workstation when you close this app.")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            Button {
                showNew = true
            } label: {
                Text("New terminal")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
        .padding(.horizontal, ProteusTheme.Space.screen)
        .padding(.vertical, 40)
    }
}

private struct TerminalRowView: View {
    @Environment(\.proteusTheme) private var theme
    let term: TermInfo

    init(term: TermInfo) {
        self.term = term
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: term.alive ? .working : .idle, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(term.title.isEmpty ? "Terminal" : term.title)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(term.cwd)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.textMeta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if term.pid > 0 {
                Text("pid \(term.pid)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.textMeta)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
