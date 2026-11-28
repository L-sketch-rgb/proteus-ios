import SwiftUI
import PhotosUI
import ImageIO
import UIKit
import ProteusKit

struct ComposerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.paletteAccent) private var accent
    @ObservedObject var chat: ChatSessionModel

    /// Photos picked in the system picker, drained into `attachments`.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [PhotoAttachment] = []
    @State private var isLoadingImage = false

    private static let maxPhotos = 10
    @State private var showSchedule = false
    @State private var scheduledText = ""
    @State private var showModelPicker = false
    @State private var showModeDialog = false
    @State private var showHelp = false

    private var draftText: String {
        app.draftTexts[chat.id] ?? ""
    }

    /// The composer text belongs to this chat and is synced through the hub
    /// (v9 §1). The store debounces `draft.set` and flushes on disappear.
    private var text: Binding<String> {
        Binding(
            get: { app.draftTexts[chat.id] ?? "" },
            set: { app.setDraftText($0, for: chat.id) }
        )
    }

    private var slashRows: [SlashCommand] {
        SlashCommands.menu(for: draftText, engineCommands: chat.session?.commands ?? [])
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// v10 §1: the Proteus command the composer text is prefixed with, when it
    /// takes an argument that can be cancelled.
    private var commandPrefix: String? {
        if draftText.hasPrefix("/queue ") { return "/queue" }
        if draftText.hasPrefix("/schedule ") { return "/schedule" }
        return nil
    }

    private var commandIcon: String {
        commandPrefix == "/schedule" ? "clock" : "arrow.right.to.line"
    }

    /// v10 §1: strip the command prefix but keep the rest as normal text.
    private func clearCommandPrefix() {
        guard let prefix = commandPrefix else { return }
        let rest = String(draftText.dropFirst(prefix.count + 1))
        app.setDraftText(rest, for: chat.id)
    }

    private struct ModeOption: Identifiable {
        let id: String
        let label: String
    }

    private static let modeOptions: [ModeOption] = [
        ModeOption(id: "default", label: "Ask"),
        ModeOption(id: "acceptEdits", label: "Accept edits"),
        ModeOption(id: "plan", label: "Plan"),
        ModeOption(id: "auto", label: "Auto"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            PendingStripView(chat: chat)

            if !slashRows.isEmpty {
                SlashMenuView(rows: slashRows) { command in
                    choose(command)
                }
            }

            if isLoadingImage || !attachments.isEmpty {
                attachmentStrip
            }

            if let prefix = commandPrefix {
                // v10 §1: × (or Esc) cancels the command, keeping the prompt.
                HStack(spacing: 5) {
                    Image(systemName: commandIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(prefix)
                        .font(.caption.monospaced())
                    Button {
                        clearCommandPrefix()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel \(prefix)")
                    Spacer()
                }
                .padding(.leading, 4)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(1, Self.maxPhotos - attachments.count),
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images]),
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .disabled(attachments.count >= Self.maxPhotos)
                .accessibilityLabel("Attach photos")

                TextField("Message", text: text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)

                if chat.isRunning {
                    Button {
                        app.interrupt()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 27))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .contextMenu {
                    if canSend {
                        Button {
                            queueCurrent()
                        } label: {
                            Label("Queue after this turn", systemImage: "text.append")
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCard(cornerRadius: 22)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onDisappear {
            // Chat switch, navigation pop: send the pending draft at once.
            app.flushDraft(for: chat.id)
        }
        .onKeyPress { press in
            // Hardware keyboard: Esc cancels the command prefix; Option-Return
            // queues the prompt.
            if press.key == .escape, commandPrefix != nil {
                clearCommandPrefix()
                return .handled
            }
            if press.key == .return && press.modifiers.contains(.option) {
                queueCurrent()
                return .handled
            }
            return .ignored
        }
        .background {
            // A focused text field can consume Option-Return as a newline
            // before `onKeyPress` sees it, so the same shortcut is registered
            // on an invisible button as a fallback.
            Button("Queue after this turn") {
                queueCurrent()
            }
            .keyboardShortcut(.return, modifiers: .option)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $showSchedule, onDismiss: {
            // v10 §1: any close that is not a confirmation cancels the
            // schedule; the "/schedule " text stays in the composer.
            scheduledText = ""
        }) {
            ScheduleSheet(title: "Schedule prompt", initialDate: nil) { date in
                app.queuePrompt(scheduledText, at: date, chatId: chat.id)
                app.discardDraft(for: chat.id)
            }
        }
        .sheet(isPresented: $showModelPicker) {
            SlashModelPickerSheet { id in
                app.setModel(id)
                app.discardDraft(for: chat.id)
                showModelPicker = false
            }
        }
        .sheet(isPresented: $showHelp) {
            SlashHelpSheet()
        }
        .confirmationDialog("Permission mode", isPresented: $showModeDialog, titleVisibility: .visible) {
            ForEach(Self.modeOptions) { option in
                Button(option.label) {
                    app.setMode(option.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: app.pendingComposerImages[chat.id]?.count ?? 0) { _, _ in
            takeFileImages()
        }
        .onAppear { takeFileImages() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            loadPhotos(items)
        }
    }

    /// Images attached from the file browser (hub `fs.read` image data).
    private func takeFileImages() {
        guard let images = app.pendingComposerImages[chat.id], !images.isEmpty else { return }
        app.pendingComposerImages[chat.id] = nil
        for image in images where attachments.count < Self.maxPhotos {
            guard let data = Data(base64Encoded: image.data),
                  let photo = ImageDownsampler.process(data: data) else { continue }
            attachments.append(photo)
        }
    }

    /// Load picked photos one at a time (so only one full-size image is in
    /// memory), downscale each, and append it to the strip.
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        isLoadingImage = true
        Task { @MainActor in
            defer { isLoadingImage = false }
            for item in items where attachments.count < Self.maxPhotos {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let photo = await Task.detached(priority: .userInitiated, operation: {
                          ImageDownsampler.process(data: data)
                      }).value else {
                    app.errorText = "Could not read that photo."
                    continue
                }
                attachments.append(photo)
            }
        }
    }

    // MARK: - Sending and commands (v9 §3)

    private func send() {
        let raw = draftText
        if let parsed = SlashCommands.parse(raw), SlashCommands.isProteusCommand(parsed.command) {
            handleProteus(parsed.command, argument: parsed.argument)
            return
        }
        // Engine commands and ordinary prompts are sent unchanged.
        guard canSend else { return }
        let images = attachments.map(\.image)
        app.sendMessage(text: raw, images: images)
        app.discardDraft(for: chat.id)
        attachments = []
    }

    private func handleProteus(_ command: String, argument: String) {
        switch command {
        case "/queue":
            guard !argument.isEmpty else {
                app.errorText = "Type the prompt to queue: /queue <text>"
                return
            }
            app.queuePrompt(argument, chatId: chat.id)
            app.discardDraft(for: chat.id)

        case "/schedule":
            guard !argument.isEmpty else {
                app.errorText = "Type the prompt to schedule: /schedule <text>"
                return
            }
            scheduledText = argument
            showSchedule = true

        case "/model":
            if argument.isEmpty {
                app.discardDraft(for: chat.id)
                showModelPicker = true
            } else if let id = matchModel(argument) {
                app.setModel(id)
                app.discardDraft(for: chat.id)
            } else {
                app.errorText = "No available model matches “\(argument)”."
            }

        case "/mode":
            app.discardDraft(for: chat.id)
            showModeDialog = true

        case "/stop":
            app.interrupt()
            app.discardDraft(for: chat.id)

        case "/rename":
            guard !argument.isEmpty, let session = chat.session else {
                app.errorText = "Type the new title: /rename <title>"
                return
            }
            app.rename(session, title: argument)
            app.discardDraft(for: chat.id)

        case "/new":
            createNewChat()

        case "/help":
            app.discardDraft(for: chat.id)
            showHelp = true

        default:
            break
        }
    }

    /// Picking a row of the `/` menu. Queue/schedule/rename leave the command
    /// in the composer so the argument can be typed; engine commands are
    /// inserted and later sent as text.
    private func choose(_ command: SlashCommand) {
        switch command.group {
        case .engine:
            app.setDraftText(command.name + " ", for: chat.id)
        case .proteus:
            switch command.name {
            case "/model":
                app.discardDraft(for: chat.id)
                showModelPicker = true
            case "/mode":
                app.discardDraft(for: chat.id)
                showModeDialog = true
            case "/help":
                app.discardDraft(for: chat.id)
                showHelp = true
            case "/stop":
                app.interrupt()
                app.discardDraft(for: chat.id)
            case "/new":
                createNewChat()
            default:
                app.setDraftText(command.name + " ", for: chat.id)
            }
        }
    }

    private func queueCurrent() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.queuePrompt(trimmed, chatId: chat.id)
        app.discardDraft(for: chat.id)
    }

    private func createNewChat() {
        guard let session = chat.session else { return }
        let cwd = session.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else {
            app.errorText = "This chat has no folder."
            return
        }
        let model = app.defaultModelForNewChat(project: session.project)
        if app.createChat(cwd: cwd, model: model, text: "", project: session.project) {
            app.discardDraft(for: chat.id)
        }
    }

    /// `/model <name>`: the first available exact id/label match, else the
    /// first substring match.
    private func matchModel(_ query: String) -> String? {
        let models = (app.modelMenu.sections + app.modelMenu.more)
            .flatMap(\.models)
            .filter(\.available)
        let q = query.lowercased()
        if let exact = models.first(where: {
            $0.id.lowercased() == q || $0.label.lowercased() == q
        }) {
            return exact.id
        }
        return models.first {
            $0.id.lowercased().contains(q) || $0.label.lowercased().contains(q)
        }?.id
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { photo in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            attachments.removeAll { $0.id == photo.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove photo")
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                if isLoadingImage {
                    ProgressView()
                        .frame(width: 64, height: 64)
                }
            }
            .padding(8)
        }
        .glassCard(cornerRadius: 12)
    }
}

/// One photo ready to send, with a small thumbnail for the strip.
struct PhotoAttachment: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: ImageIn
    let thumbnail: UIImage
}

enum ImageDownsampler {
    /// Decode straight to a small bitmap with ImageIO (never the full-size
    /// image), then JPEG + base64. Longest side at most 1600 px, quality 0.8.
    static func process(data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.8) -> PhotoAttachment? {
        guard let jpeg = jpegData(data: data, maxDimension: maxDimension, quality: quality),
              let thumb = thumbnail(data: data, maxDimension: 160) else { return nil }
        return PhotoAttachment(
            image: ImageIn(mediaType: "image/jpeg", data: jpeg.base64EncodedString()),
            thumbnail: thumb
        )
    }

    static func jpegBase64(data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.8) -> String? {
        jpegData(data: data, maxDimension: maxDimension, quality: quality)?.base64EncodedString()
    }

    private static func jpegData(data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let image = thumbnail(data: data, maxDimension: maxDimension) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // Flatten transparency onto white so PNGs with alpha stay readable.
        let flattened = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return flattened.jpegData(compressionQuality: quality)
    }

    private static func thumbnail(data: Data, maxDimension: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
