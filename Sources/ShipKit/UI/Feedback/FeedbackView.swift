import PhotosUI
import SwiftUI
import UIKit

private struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
}

extension ShipKit {
    /// The feedback form. Present it from your own UI (or use `FeedbackLink` / `FeedbackButton`).
    public struct FeedbackView: View {
        private enum Phase: Equatable {
            case editing, sending, sent, queued
        }

        @Environment(\.dismiss) private var dismiss
        @ObservedObject private var model = ShipKitModel.shared
        @State private var category: FeedbackCategory
        @State private var rating: Int?
        @State private var message = ""
        @State private var email: String
        @State private var attachments: [DraftAttachment] = []
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var redacting: DraftAttachment?
        @State private var phase: Phase = .editing
        @State private var errorText: String?
        @State private var previousScreen: UIImage?
        @State private var appeared = false
        @FocusState private var messageFocused: Bool
        private let prompt: String?

        public init(category: FeedbackCategory = .bug) {
            self.init(category: category, prompt: nil)
        }

        /// `prompt` is the developer's question from a feedback push, shown above the form.
        init(category: FeedbackCategory, prompt: String?) {
            _category = State(initialValue: category)
            _email = State(initialValue: ShipKit.engine?.identity.email ?? "")
            self.prompt = prompt
        }

        private var config: ShipKitConfig.Feedback { ShipKit.config.feedback }

        private var canSend: Bool {
            phase == .editing && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public var body: some View {
            Group {
                switch phase {
                case .sent, .queued:
                    confirmation
                case .editing, .sending:
                    form
                }
            }
            .shipKitDismissesKeyboard()
            .navigationTitle(L("feedback.title"))
            .navigationBarTitleDisplayMode(.inline)
            .shipKitTint()
            .onAppear {
                guard !appeared else { return }
                appeared = true
                if config.attachScreenshot { previousScreen = ScreenCapture.screenBeforeFeedback() }
            }
        }

        private var form: some View {
            Form {
                if let prompt {
                    Section {
                        Text(prompt)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker(L("feedback.category"), selection: $category) {
                        ForEach(FeedbackCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(category)
                        }
                    }
                    if config.showsRating {
                        HStack {
                            Text(L("feedback.rating"))
                            Spacer()
                            StarPicker(rating: $rating)
                        }
                    }
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .frame(minHeight: 140)
                            .focused($messageFocused)
                    }
                } header: {
                    Text(L("feedback.message"))
                }

                if config.attachScreenshot {
                    attachmentsSection
                }

                if config.asksForEmail {
                    Section {
                        TextField(L("feedback.email.placeholder"), text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text(L("feedback.email"))
                    } footer: {
                        Text(L("feedback.email.footer"))
                    }
                }

                Section {
                    DisclosureGroup(L("feedback.disclosure.details")) {
                        ForEach(contextRows, id: \.0) { row in
                            LabeledContent(row.0, value: row.1)
                                .font(.footnote)
                        }
                    }
                } footer: {
                    Text(L("feedback.disclosure"))
                }
            }
            .disabled(phase == .sending)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .sending {
                        ProgressView()
                    } else {
                        Button(L("feedback.send"), action: send)
                            .disabled(!canSend)
                    }
                }
            }
            .alert(L("feedback.error.title"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .sheet(item: $redacting) { attachment in
                RedactEditor(image: attachment.image) { redacted in
                    if let index = attachments.firstIndex(where: { $0.id == attachment.id }) {
                        attachments[index].image = redacted
                    }
                }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
        }

        private var placeholder: String {
            switch category {
            case .bug: return L("feedback.placeholder.bug")
            case .idea: return L("feedback.placeholder.idea")
            case .question: return L("feedback.placeholder.question")
            case .praise: return L("feedback.placeholder.praise")
            }
        }

        private var attachmentsSection: some View {
            Section {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(attachments) { attachment in
                                thumbnail(attachment)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                if attachments.count < config.maxAttachments {
                    let photoTitle = L("feedback.attach.photo")
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: max(config.maxAttachments - attachments.count, 1),
                        matching: .images
                    ) {
                        Label(photoTitle, systemImage: "photo.on.rectangle")
                    }
                    Button {
                        if let image = previousScreen ?? ScreenCapture.captureKeyWindow() {
                            attachments.append(DraftAttachment(image: image))
                        }
                    } label: {
                        Label(L("feedback.attach.screen"), systemImage: "camera.viewfinder")
                    }
                }
            } header: {
                Text(L("feedback.attachments"))
            } footer: {
                if !attachments.isEmpty {
                    Text(L("feedback.attachments.redactHint"))
                }
            }
        }

        private func thumbnail(_ attachment: DraftAttachment) -> some View {
            Image(uiImage: attachment.image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        attachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel(L("feedback.attachment.remove"))
                }
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
                .onTapGesture { redacting = attachment }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(L("redact.title"))
        }

        private var contextRows: [(String, String)] {
            guard let context = ShipKit.engine?.makeContext() else { return [] }
            var rows: [(String, String)] = [
                (L("context.appVersion"), "\(context.appVersion) (\(context.build))"),
                (L("context.os"), "iOS \(context.osVersion ?? "")"),
                (L("context.device"), context.device ?? ""),
                (L("context.locale"), context.locale ?? ""),
                (L("context.installID"), context.stableId)
            ]
            if let userId = context.userId { rows.append((L("context.userID"), userId)) }
            return rows
        }

        private var confirmation: some View {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: phase == .queued ? "tray.and.arrow.up" : "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(ShipKit.theme.primaryColor)
                Text(L("feedback.sent.title"))
                    .font(.title2.bold())
                Text(L(phase == .queued ? "feedback.queued.message" : "feedback.sent.message"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
        }

        private func loadPhotos(_ items: [PhotosPickerItem]) async {
            for item in items where attachments.count < config.maxAttachments {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    attachments.append(DraftAttachment(image: image))
                }
            }
            photoItems = []
        }

        private func send() {
            guard canSend, let engine = ShipKit.engine else {
                if ShipKit.engine == nil { errorText = L("error.generic") }
                return
            }
            messageFocused = false
            phase = .sending
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let payloads = attachments.compactMap { ImageEncoding.payload(for: $0.image) }
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = self.category
            let rating = config.showsRating ? self.rating : nil
            let email = config.asksForEmail && !trimmedEmail.isEmpty ? trimmedEmail : nil
            Task {
                do {
                    let result = try await engine.submitFeedback(
                        category: category, rating: rating, message: text, email: email, images: payloads
                    )
                    switch result {
                    case .sent: phase = .sent
                    case .queued: phase = .queued
                    }
                    _ = await engine.refreshUnread()
                } catch {
                    phase = .editing
                    errorText = errorMessage(error)
                }
            }
        }
    }
}

struct StarPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = rating == value ? nil : value
                } label: {
                    Image(systemName: value <= (rating ?? 0) ? "star.fill" : "star")
                        .foregroundStyle(value <= (rating ?? 0) ? Color.yellow : Color.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("feedback.rating.stars", value))
                .accessibilityAddTraits(value == rating ? .isSelected : [])
            }
        }
    }
}

enum ImageEncoding {
    static let maxBytes = 5 * 1024 * 1024
    static let maxDimension: CGFloat = 2048

    /// Downscales and JPEG-encodes an image to fit the 5 MB upload limit.
    static func payload(for image: UIImage) -> ImagePayload? {
        let scaled = downscale(image)
        for quality in [0.8, 0.6, 0.4, 0.25] as [CGFloat] {
            if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return ImagePayload(data: data, contentType: "image/jpeg")
            }
        }
        return nil
    }

    private static func downscale(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension else { return image }
        let factor = maxDimension / longest
        let size = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
