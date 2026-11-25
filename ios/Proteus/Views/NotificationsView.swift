import SwiftUI
import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ProteusKit

/// Settings → Notifications (v8 §3). Shows the hub's ntfy server and topic
/// state, the ntfy app deep link and QR, and a test button. The topic is a
/// secret: it is never logged and only ever leaves this screen as the
/// `ntfy://` link or the QR code.
struct NotificationsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var server = ""
    @State private var loaded = false

    private var settings: NotificationSettings { app.notificationSettings }

    private var trimmedServer: String {
        server.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveServer: Bool {
        !trimmedServer.isEmpty && trimmedServer != settings.server
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Push notifications",
                    isOn: Binding(
                        get: { settings.enabled },
                        set: { app.setNotificationsEnabled($0) }
                    )
                )
            } footer: {
                Text("The hub posts to your ntfy topic when a turn finishes or needs attention. This stays on your hub; nothing is sent to Proteus.")
            }

            Section {
                TextField("https://ntfy.sh", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save server") {
                    app.setNotificationServer(trimmedServer)
                }
                .disabled(!canSaveServer)
            } header: {
                Text("Server")
            } footer: {
                Text("Use ntfy.sh or your own ntfy server. The topic is posted to this server, so a self-hosted server keeps notifications private.")
            }

            Section {
                LabeledContent("State") {
                    Text(settings.hasTopic ? "Configured" : "Not generated")
                }
                if settings.hasTopic {
                    LabeledContent("Subscription") {
                        Text(settings.enabled ? "Active" : "Paused")
                    }
                }
                Button("Generate new topic") {
                    app.regenerateNotificationTopic()
                }
            } header: {
                Text("Topic")
            } footer: {
                Text("Generating a new topic immediately invalidates the old subscription; re-subscribe below afterwards.")
            }

            if let url = app.notificationSubscribeURL {
                Section("Subscribe") {
                    Link(destination: url) {
                        Label("Subscribe in ntfy", systemImage: "bell.badge")
                    }

                    VStack(spacing: 6) {
                        QRCodeView(text: url.absoluteString)
                        Text("Scan with the ntfy app on your phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button("Send test") {
                    app.sendTestNotification()
                }
                .disabled(!settings.enabled || !settings.hasTopic)
            } footer: {
                Text("Sends one notification through the hub so you can check the subscription end to end.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            server = settings.server
            loaded = true
        }
        .onChange(of: settings.server) { _, value in
            // The hub is the source of truth after a save or another device.
            server = value
        }
    }
}

/// CoreImage QR code for the `ntfy://` subscribe link.
private struct QRCodeView: View {
    let text: String

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Subscription QR code")
        }
    }
}
