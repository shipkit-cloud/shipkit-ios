import PhotosUI
import SwiftUI
import UIKit

private struct DraftAttachment: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
}

extension ShipKit {
    /// The feedback form. Present it from your own UI (or use `FeedbackLink` / `FeedbackButton`).
    ///
    /// Shows the form designed in the dashboard when one is published, and the standard form
    /// otherwise (also offline, before the first snapshot arrives).
    public struct FeedbackView: View {
        private enum Phase: Equatable {
            case editing, sending, sent, queued
        }

        @Environment(\.dismiss) private var dismiss
        @ObservedObject private var model = ShipKitModel.shared
        @State private var form: FeedbackForm
        @State private var category: FeedbackCategory
        @State private var values = FeedbackForm.Values()
        @State private var attachments: [DraftAttachment] = []
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var redacting: DraftAttachment?
        @State private var phase: Phase = .editing
        @State private var errorText: String?
        @State private var previousScreen: UIImage?
        @State private var appeared = false
        @State private var triedToSend = false
        @FocusState private var focused: String?
        private let prompt: String?

        public init(category: FeedbackCategory = .bug) {
            self.init(category: category, prompt: nil)
        }

        /// `prompt` is the developer's question from a feedback push, shown above the form.
        init(category: FeedbackCategory, prompt: String?) {
            let form = FeedbackForm.resolve(ShipKit.engine?.snapshot?.feedbackForm, config: ShipKit.config.feedback)
            _form = State(initialValue: form)
            let hasCategory = form.visibleFields.contains { $0.kind == .category }
            _category = State(initialValue: hasCategory ? category : form.defaultCategory)
            var values = FeedbackForm.Values()
            values.texts["email"] = ShipKit.engine?.identity.email ?? ""
            _values = State(initialValue: values)
            self.prompt = prompt
        }

        private var config: ShipKitConfig.Feedback { ShipKit.config.feedback }

        private var emailField: FeedbackForm.Field? { form.visibleFields.first { $0.kind == .email } }

        private var emailIsValid: Bool {
            let text = values.text("email")
            return emailField == nil || text.isEmpty || FeedbackForm.isValidEmail(text)
        }

        private var missing: Set<String> { Set(form.missingRequired(values)) }

        private var canSend: Bool {
            phase == .editing && missing.isEmpty && emailIsValid && form.hasContent(values)
        }

        private var maxAttachments: Int {
            form.visibleFields.first { $0.kind == .screenshots }?.max ?? config.maxAttachments
        }

        public var body: some View {
            Group {
                switch phase {
                case .sent, .queued:
                    confirmation
                case .editing, .sending:
                    formView
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

        private var formView: some View {
            Form {
                if let prompt {
                    Section {
                        Text(prompt)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }

                ForEach(form.visibleFields) { field in
                    section(for: field)
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
                        Button(form.submitLabel ?? L("feedback.send"), action: send)
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

        // MARK: - Fields

        /// Built-in labels of the standard form, used when the dashboard left a label empty.
        private func title(_ field: FeedbackForm.Field) -> String {
            if let label = field.label, !label.isEmpty { return label }
            switch field.id {
            case "category": return L("feedback.category")
            case "rating": return L("feedback.rating")
            case "message": return L("feedback.message")
            // The standard form's label already says "optional"; a custom form decides that itself.
            case "email": return form.isCustom ? L("feedback.email.label") : L("feedback.email")
            case "screenshots": return L("feedback.attachments")
            default: return field.id
            }
        }

        /// Marks optional questions on a custom form. The standard form keeps its own wording.
        private func header(_ field: FeedbackForm.Field) -> String {
            let text = title(field)
            guard form.isCustom, !field.required, field.kind != .category, field.kind != .screenshots else { return text }
            return L("feedback.field.optional", text)
        }

        @ViewBuilder
        private func footer(_ field: FeedbackForm.Field, fallback: String? = nil) -> some View {
            let help = field.help ?? fallback
            let showMissing = triedToSend && missing.contains(field.id)
            if help != nil || showMissing {
                VStack(alignment: .leading, spacing: 4) {
                    if let help { Text(help) }
                    if showMissing { Text(L("feedback.required.hint")).foregroundStyle(.red) }
                }
            }
        }

        @ViewBuilder
        private func section(for field: FeedbackForm.Field) -> some View {
            switch field.kind {
            case .category:
                Section {
                    Picker(title(field), selection: $category) {
                        ForEach(FeedbackCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(category)
                        }
                    }
                } footer: {
                    footer(field)
                }
            case .rating:
                Section {
                    HStack {
                        Text(header(field))
                        Spacer()
                        StarPicker(rating: ratingBinding(field.id))
                    }
                } footer: {
                    footer(field)
                }
            case .longText:
                Section {
                    ZStack(alignment: .topLeading) {
                        if values.text(field.id).isEmpty && (values.texts[field.id] ?? "").isEmpty {
                            Text(field.placeholder ?? (field.id == "message" ? placeholder : ""))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: textBinding(field.id, max: field.maxLength ?? 5000))
                            .frame(minHeight: field.id == "message" ? 140 : 90)
                            .focused($focused, equals: field.id)
                    }
                } header: {
                    Text(header(field))
                } footer: {
                    footer(field)
                }
            case .text:
                Section {
                    TextField(field.placeholder ?? "", text: textBinding(field.id, max: field.maxLength ?? 500))
                        .focused($focused, equals: field.id)
                } header: {
                    Text(header(field))
                } footer: {
                    footer(field)
                }
            case .choice:
                Section {
                    ForEach(field.options) { option in
                        let selected = values.choices[field.id] == option.id
                        Button {
                            values.choices[field.id] = selected && !field.required ? nil : option.id
                        } label: {
                            HStack {
                                Text(option.label).foregroundStyle(Color.primary)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(ShipKit.theme.primaryColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                } header: {
                    Text(header(field))
                } footer: {
                    footer(field)
                }
            case .email:
                Section {
                    TextField(field.placeholder ?? L("feedback.email.placeholder"), text: textBinding(field.id, max: 256))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: field.id)
                } header: {
                    Text(header(field))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.help ?? L(field.updates ? "feedback.email.footer.updates" : "feedback.email.footer"))
                        if !emailIsValid { Text(L("feedback.error.email")).foregroundStyle(.red) }
                        if triedToSend && missing.contains(field.id) { Text(L("feedback.required.hint")).foregroundStyle(.red) }
                    }
                }
            case .screenshots:
                attachmentsSection(title: title(field), help: field.help)
            case .unknown:
                EmptyView()
            }
        }

        private func textBinding(_ id: String, max: Int) -> Binding<String> {
            Binding(
                get: { values.texts[id] ?? "" },
                set: { values.texts[id] = String($0.prefix(max)) }
            )
        }

        private func ratingBinding(_ id: String) -> Binding<Int?> {
            Binding(
                get: { values.ratings[id] },
                set: { values.ratings[id] = $0 }
            )
        }

        private var placeholder: String {
            switch category {
            case .bug: return L("feedback.placeholder.bug")
            case .idea: return L("feedback.placeholder.idea")
            case .question: return L("feedback.placeholder.question")
            case .praise: return L("feedback.placeholder.praise")
            }
        }

        private func attachmentsSection(title: String, help: String?) -> some View {
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
                if attachments.count < maxAttachments {
                    let photoTitle = L("feedback.attach.photo")
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: max(maxAttachments - attachments.count, 1),
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
                Text(title)
            } footer: {
                if !attachments.isEmpty {
                    Text(L("feedback.attachments.redactHint"))
                } else if let help {
                    Text(help)
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
                Text(form.thanksTitle ?? L("feedback.sent.title"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(phase == .queued ? L("feedback.queued.message") : (form.thanksMessage ?? L("feedback.sent.message")))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
        }

        private func loadPhotos(_ items: [PhotosPickerItem]) async {
            for item in items where attachments.count < maxAttachments {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    attachments.append(DraftAttachment(image: image))
                }
            }
            photoItems = []
        }

        private func send() {
            triedToSend = true
            guard canSend, let engine = ShipKit.engine else {
                if ShipKit.engine == nil { errorText = L("error.generic") }
                return
            }
            focused = nil
            phase = .sending
            let has = { (kind: FeedbackForm.Field.Kind, id: String) in form.visibleFields.contains { $0.kind == kind && $0.id == id } }
            let payloads = has(.screenshots, "screenshots") ? attachments.compactMap { ImageEncoding.payload(for: $0.image) } : []
            let text = has(.longText, "message") ? values.text("message") : ""
            let category = form.visibleFields.contains { $0.kind == .category } ? self.category : form.defaultCategory
            let rating = has(.rating, "rating") ? values.ratings["rating"] : nil
            let typedEmail = values.text("email")
            let email = emailField != nil && !typedEmail.isEmpty ? typedEmail : nil
            // The standard form sends exactly what older SDKs sent, so the message stays required there.
            let answers = form.isCustom ? form.answers(values) : nil
            let formRev = form.rev
            Task {
                do {
                    let result = try await engine.submitFeedback(
                        category: category, rating: rating, message: text, email: email, images: payloads,
                        answers: answers, formRev: formRev
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
