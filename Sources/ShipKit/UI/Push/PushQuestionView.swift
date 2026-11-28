#if !os(tvOS)
import SwiftUI

/// What a tapped push presents: the feedback form, the question sheet, or what a status update is about.
struct PushPresentationView: View {
    let presentation: PushPresentation

    var body: some View {
        switch presentation {
        case .feedback(_, let prompt):
            FeedbackSheet(category: .idea, prompt: prompt)
        case .question(let payload):
            PushQuestionSheet(payload: payload)
        case .update(let target):
            UpdateSheet(target: target)
        }
    }
}

/// Shows the feedback conversation or feature request a status update push is about.
struct UpdateSheet: View {
    let target: ShipKitUpdateTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("common.done")) { dismiss() }
                    }
                }
        }
        .shipKitTint()
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .feedbackThread(let id?):
            UpdateThreadLoader(threadID: id)
        case .feedbackThread(nil):
            ShipKit.FeedbackInboxView()
        case .featureRequest(let id?):
            UpdateRequestLoader(requestID: id)
        case .featureRequest(nil):
            ShipKit.RequestBoardView()
        }
    }
}

private struct UpdateThreadLoader: View {
    let threadID: String
    @State private var thread: FeedbackThread?
    @State private var failed: String?
    @State private var missing = false

    var body: some View {
        Group {
            if let thread {
                FeedbackThreadView(thread: thread) { self.thread = $0 }
            } else if missing {
                EmptyStateView(systemImage: "bubble.left.and.exclamationmark.bubble.right", title: L("statusUpdate.unavailable"), message: nil)
            } else if let failed {
                ErrorBanner(message: failed) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L("inbox.title"))
        .skInlineTitle()
        .task { await load() }
    }

    private func load() async {
        guard let engine = ShipKit.engine else {
            missing = true
            return
        }
        failed = nil
        do {
            thread = try await engine.thread(threadID).0
        } catch ShipKitError.server(let status, _, _) where status == 404 {
            missing = true
        } catch {
            failed = errorMessage(error)
        }
    }
}

private struct UpdateRequestLoader: View {
    let requestID: String
    @StateObject private var store = RequestBoardStore()

    var body: some View {
        Group {
            if store.request(requestID) != nil {
                RequestDetailView(store: store, requestID: requestID)
            } else if store.loaded {
                EmptyStateView(systemImage: "lightbulb", title: L("statusUpdate.unavailable"), message: nil)
            } else if let errorText = store.errorText {
                ErrorBanner(message: errorText) { Task { await store.load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await store.load() }
    }
}

/// Answers a question push: yes/no, 1–5 stars, one of a few choices, or free text.
struct PushQuestionSheet: View {
    private enum Phase: Equatable {
        case loading, answering, sending, sent, unavailable
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payload: PushPayload
    @State private var phase: Phase
    @State private var yesNo: String?
    @State private var score: Int?
    @State private var choice: String?
    @State private var answerText = ""
    @State private var comment = ""
    @State private var errorText: String?
    @State private var loadError: String?
    @FocusState private var textFocused: Bool
    /// Sends the answer somewhere else than the push delivery (an in-app ask).
    private let submit: (@MainActor (PushAnswer) async throws -> Void)?

    init(payload: PushPayload, submit: (@MainActor (PushAnswer) async throws -> Void)? = nil) {
        _payload = State(initialValue: payload)
        _phase = State(initialValue: payload.question?.isComplete == true ? .answering : .loading)
        self.submit = submit
    }

    private var type: PushQuestion.Kind? { payload.question?.type }

    private var trimmedComment: String? {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var answer: PushAnswer? {
        switch type {
        case .yesno?: return yesNo.map { PushAnswer(value: .string($0), text: trimmedComment) }
        case .scale?: return score.map { PushAnswer(value: .int($0), text: trimmedComment) }
        case .choice?: return choice.map { PushAnswer(value: .string($0), text: trimmedComment) }
        case .text?:
            let text = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : PushAnswer(value: nil, text: text)
        case nil: return nil
        }
    }

    var body: some View {
        NavigationStack {
            content
                .shipKitDismissesKeyboard()
                .navigationTitle(L("question.title"))
                .skInlineTitle()
                .toolbar {
                    if phase != .sent {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("common.cancel")) { dismiss() }
                        }
                    }
                    if phase == .answering || phase == .sending {
                        ToolbarItem(placement: .confirmationAction) {
                            if phase == .sending {
                                ProgressView()
                            } else {
                                Button(L("feedback.send"), action: send)
                                    .disabled(answer == nil)
                            }
                        }
                    }
                }
        }
        .shipKitTint()
        .interactiveDismissDisabled(phase == .sending)
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            if let loadError {
                ErrorBanner(message: loadError) {
                    phase = .loading
                    Task { await loadIfNeeded() }
                }
            } else {
                EmptyStateView(systemImage: "questionmark.bubble", title: L("question.unavailable"), message: nil)
            }
        case .sent:
            confirmation
        case .answering, .sending:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                Text(payload.displayPrompt)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } footer: {
                if payload.answered {
                    Text(L("question.answered"))
                }
            }

            switch type {
            case .yesno?: yesNoSection
            case .scale?: scaleSection
            case .choice?: choiceSection
            case .text?: textSection
            case nil: EmptyView()
            }

            if type != .text {
                Section {
                    TextField(L("question.comment.placeholder"), text: $comment, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text(L("question.comment"))
                }
            }
        }
        .disabled(phase == .sending)
        .alert(L("feedback.error.title"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var yesNoSection: some View {
        Section {
            HStack(spacing: 12) {
                yesNoButton("yes", title: L("push.action.yes"), symbol: "hand.thumbsup")
                yesNoButton("no", title: L("push.action.no"), symbol: "hand.thumbsdown")
            }
            .padding(.vertical, 4)
        }
    }

    private func yesNoButton(_ value: String, title: String, symbol: String) -> some View {
        let selected = yesNo == value
        return Button {
            yesNo = value
        } label: {
            Label(title, systemImage: selected ? "\(symbol).fill" : symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(selected ? Color.white : ShipKit.theme.primaryColor)
                .background(
                    RoundedRectangle(cornerRadius: ShipKit.theme.cornerRadius, style: .continuous)
                        .fill(selected ? ShipKit.theme.primaryColor : ShipKit.theme.primaryColor.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var scaleSection: some View {
        Section {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                ForEach(1...5, id: \.self) { value in
                    Button {
                        score = value
                    } label: {
                        Image(systemName: value <= (score ?? 0) ? "star.fill" : "star")
                            .font(.largeTitle)
                            .foregroundStyle(value <= (score ?? 0) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("feedback.rating.stars", value))
                    .accessibilityAddTraits(value == score ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }

    private var choiceSection: some View {
        Section {
            ForEach(payload.question?.choices ?? [], id: \.self) { option in
                Button {
                    choice = option
                } label: {
                    HStack {
                        Text(option)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if choice == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(ShipKit.theme.primaryColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == option ? .isSelected : [])
            }
        }
    }

    private var textSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if answerText.isEmpty {
                    Text(L("question.answer.placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $answerText)
                    .frame(minHeight: 140)
                    .focused($textFocused)
            }
        } header: {
            Text(L("question.answer"))
        }
    }

    private var confirmation: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(ShipKit.theme.primaryColor)
            Text(L("feedback.sent.title"))
                .font(.title2.bold())
            Text(L("question.sent.message"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(L("common.done")) { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
    }

    private func loadIfNeeded() async {
        guard phase == .loading else { return }
        guard let engine = ShipKit.engine, let id = payload.deliveryID else {
            phase = .unavailable
            return
        }
        do {
            payload = payload.merged(with: try await engine.pushDelivery(id))
            loadError = nil
            phase = payload.question?.isComplete == true ? .answering : .unavailable
        } catch {
            // Without the full question, a known type and something to show is still answerable.
            if let type, type != .choice || (payload.question?.choices.count ?? 0) >= 2, !payload.displayPrompt.isEmpty {
                phase = .answering
            } else {
                loadError = errorMessage(error)
                phase = .unavailable
            }
        }
    }

    private func send() {
        guard let answer, let engine = ShipKit.engine, submit != nil || payload.deliveryID != nil else {
            errorText = L("error.generic")
            return
        }
        textFocused = false
        phase = .sending
        Task {
            do {
                if let submit {
                    try await submit(answer)
                } else if let id = payload.deliveryID {
                    try await engine.answerPush(id, answer: answer)
                }
                phase = .sent
            } catch {
                phase = .answering
                errorText = errorMessage(error)
            }
        }
    }
}

/// A settings row that lets people turn off questions, feedback requests and messages from the
/// developer. Place it inside a `Form` or `List`.
///
/// App Review guideline 4.5.4 requires an in-app way to opt out of promotional notifications.
public struct ShipKitPushAsksToggle: View {
    private let title: String?
    private let footer: String?
    @ObservedObject private var model = ShipKitModel.shared
    @State private var pending: Bool?
    @State private var saving = false
    @State private var errorText: String?

    public init(_ title: String? = nil, footer: String? = nil) {
        self.title = title
        self.footer = footer
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { pending ?? model.pushAsksEnabled },
            set: { update($0) }
        )
    }

    public var body: some View {
        Section {
            Toggle(title ?? L("push.asks.title"), isOn: isOn)
                .disabled(saving)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(footer ?? L("push.asks.footer"))
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .shipKitTint()
        .task {
            try? await ShipKit.engine?.refreshPushPreferences()
            model.reload()
        }
    }

    private func update(_ enabled: Bool) {
        pending = enabled
        saving = true
        Task {
            do {
                try await ShipKit.setPushAsks(enabled)
                errorText = nil
            } catch {
                errorText = errorMessage(error)
            }
            model.reload()
            pending = nil
            saving = false
        }
    }
}

/// A settings row that lets people turn off status updates about feedback and feature requests
/// they sent or voted for. Place it inside a `Form` or `List`.
public struct ShipKitPushUpdatesToggle: View {
    private let title: String?
    private let footer: String?
    @ObservedObject private var model = ShipKitModel.shared
    @State private var pending: Bool?
    @State private var saving = false
    @State private var errorText: String?

    public init(_ title: String? = nil, footer: String? = nil) {
        self.title = title
        self.footer = footer
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { pending ?? model.pushUpdatesEnabled },
            set: { update($0) }
        )
    }

    public var body: some View {
        Section {
            Toggle(title ?? L("push.updates.title"), isOn: isOn)
                .disabled(saving)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(footer ?? L("push.updates.footer"))
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
        .shipKitTint()
        .task {
            try? await ShipKit.engine?.refreshPushPreferences()
            model.reload()
        }
    }

    private func update(_ enabled: Bool) {
        pending = enabled
        saving = true
        Task {
            do {
                try await ShipKit.setPushUpdates(enabled)
                errorText = nil
            } catch {
                errorText = errorMessage(error)
            }
            model.reload()
            pending = nil
            saving = false
        }
    }
}
#endif
