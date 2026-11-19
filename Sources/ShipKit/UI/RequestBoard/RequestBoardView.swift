import SwiftUI

private enum BoardSegment: String, CaseIterable, Identifiable {
    case open, planned, inProgress, done

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .open: return FeatureRequest.Status.open.title
        case .planned: return FeatureRequest.Status.planned.title
        case .inProgress: return FeatureRequest.Status.inProgress.title
        case .done: return FeatureRequest.Status.done.title
        }
    }

    func contains(_ request: FeatureRequest) -> Bool {
        switch self {
        case .open: return request.status == .open || request.status == .pending
        case .planned: return request.status == .planned
        case .inProgress: return request.status == .inProgress
        case .done: return request.status == .done
        }
    }
}

@MainActor
final class RequestBoardStore: ObservableObject {
    @Published var requests: [FeatureRequest] = []
    @Published var loaded = false
    @Published var errorText: String?
    @Published var voting: Set<String> = []

    func load() async {
        guard let engine = ShipKit.engine else {
            errorText = L("error.generic")
            return
        }
        do {
            requests = try await engine.requests()
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = errorMessage(error)
        }
        loaded = true
    }

    func toggleVote(_ request: FeatureRequest) async {
        guard let engine = ShipKit.engine, !voting.contains(request.id) else { return }
        voting.insert(request.id)
        defer { voting.remove(request.id) }
        let wantsVote = !request.voted
        update(request.id) {
            $0.voted = wantsVote
            $0.votes += wantsVote ? 1 : -1
        }
        do {
            let result = try await engine.vote(requestID: request.id, on: wantsVote)
            update(request.id) {
                $0.votes = result.votes
                $0.voted = result.voted
            }
        } catch {
            update(request.id) {
                $0.voted = request.voted
                $0.votes = request.votes
            }
            errorText = errorMessage(error)
        }
    }

    func update(_ id: String, _ change: (inout FeatureRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }

    func request(_ id: String) -> FeatureRequest? {
        requests.first { $0.id == id }
    }
}

extension ShipKit {
    /// Feature request board with voting and comments. Push it inside a `NavigationStack`.
    public struct RequestBoardView: View {
        @StateObject private var store = RequestBoardStore()
        @State private var segment: BoardSegment = .open
        @State private var creating = false

        public init() {}

        private var visible: [FeatureRequest] {
            store.requests
                .filter { segment.contains($0) }
                .sorted { $0.votes == $1.votes ? ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) : $0.votes > $1.votes }
        }

        public var body: some View {
            List {
                Section {
                    Picker(L("requests.title"), selection: $segment) {
                        ForEach(BoardSegment.allCases) { segment in
                            Text(segment.title).tag(segment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let errorText = store.errorText, store.requests.isEmpty {
                    ErrorBanner(message: errorText) { Task { await store.load() } }
                        .listRowBackground(Color.clear)
                } else if store.loaded, visible.isEmpty {
                    EmptyStateView(systemImage: "lightbulb", title: L("requests.empty.title"), message: L("requests.empty.message"))
                        .listRowBackground(Color.clear)
                }

                ForEach(visible) { request in
                    NavigationLink {
                        RequestDetailView(store: store, requestID: request.id)
                    } label: {
                        RequestRow(request: request, busy: store.voting.contains(request.id)) {
                            Task { await store.toggleVote(request) }
                        }
                    }
                }
            }
            .overlay {
                if !store.loaded, store.errorText == nil { ProgressView() }
            }
            .navigationTitle(L("requests.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L("requests.new"))
                }
            }
            .sheet(isPresented: $creating) {
                NewRequestSheet { created in
                    store.requests.insert(created, at: 0)
                    segment = .open
                }
            }
            .refreshable { await store.load() }
            .task { if !store.loaded { await store.load() } }
            .shipKitTint()
        }
    }
}

struct VoteButton: View {
    let votes: Int
    let voted: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: voted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                    .font(.caption)
                Text("\(votes)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 48, height: 52)
            .foregroundStyle(voted ? Color.white : ShipKit.theme.primaryColor)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(voted ? ShipKit.theme.primaryColor : ShipKit.theme.primaryColor.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(L(voted ? "requests.vote.remove" : "requests.vote"))
        .accessibilityValue("\(votes)")
    }
}

private struct RequestRow: View {
    let request: FeatureRequest
    let busy: Bool
    let vote: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VoteButton(votes: request.votes, voted: request.voted, busy: busy || request.status == .pending, action: vote)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(.headline)
                if !request.description.isEmpty {
                    Text(request.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if request.status == .pending {
                        StatusChip(text: L("requests.pending"), color: .orange)
                    }
                    if let version = request.linkedVersion {
                        StatusChip(text: L("requests.linkedVersion", version), color: .green)
                    }
                    if request.comments > 0 {
                        Label("\(request.comments)", systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct RequestDetailView: View {
    @ObservedObject var store: RequestBoardStore
    let requestID: String

    @State private var comments: [RequestComment] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let request = store.request(requestID) {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        VoteButton(
                            votes: request.votes,
                            voted: request.voted,
                            busy: store.voting.contains(request.id) || request.status == .pending
                        ) {
                            Task { await store.toggleVote(request) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(request.title).font(.title3.bold())
                            HStack {
                                StatusChip(
                                    text: request.status == .pending ? L("requests.pending") : request.status.title,
                                    color: request.status == .done ? .green : ShipKit.theme.primaryColor
                                )
                                if let version = request.linkedVersion {
                                    StatusChip(text: L("requests.linkedVersion", version), color: .green)
                                }
                            }
                        }
                    }
                    if !request.description.isEmpty {
                        Text(request.description)
                            .textSelection(.enabled)
                    }
                }
            }

            Section(L("requests.comments")) {
                if loaded, comments.isEmpty {
                    Text(L("requests.comments.empty"))
                        .foregroundStyle(.secondary)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.authorName ?? L(comment.author == .developer ? "inbox.developer" : "requests.comment.user"))
                                .font(.caption.weight(.semibold))
                            if comment.author == .developer {
                                StatusChip(text: L("requests.comment.team"), color: ShipKit.theme.primaryColor)
                            }
                            Spacer()
                            Text(Formatting.relative(comment.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(comment.body)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("requests.comment.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
                Button(action: send) {
                    if sending {
                        ProgressView().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L("inbox.reply.send"))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .alert(L("feedback.error.title"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadComments() }
        .shipKitTint()
    }

    private func loadComments() async {
        guard let engine = ShipKit.engine else { return }
        do {
            comments = try await engine.comments(requestID: requestID)
        } catch is CancellationError {
            return
        } catch {
            errorText = errorMessage(error)
        }
        loaded = true
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine = ShipKit.engine else { return }
        sending = true
        Task {
            do {
                let comment = try await engine.comment(requestID: requestID, body: text)
                comments.append(comment)
                draft = ""
                store.update(requestID) { $0.comments += 1 }
            } catch {
                errorText = errorMessage(error)
            }
            sending = false
        }
    }
}

private struct NewRequestSheet: View {
    let onCreated: (FeatureRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var email = ShipKit.engine?.identity.email ?? ""
    @State private var sending = false
    @State private var errorText: String?

    private var canSubmit: Bool {
        !sending && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("requests.new.titleField"), text: $title)
                    ZStack(alignment: .topLeading) {
                        if details.isEmpty {
                            Text(L("requests.new.descriptionField"))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $details).frame(minHeight: 120)
                    }
                } footer: {
                    Text(L("requests.new.footer"))
                }
                if ShipKit.config.feedback.asksForEmail {
                    Section {
                        TextField(L("feedback.email.placeholder"), text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text(L("feedback.email"))
                    } footer: {
                        Text(L("requests.new.emailFooter"))
                    }
                }
            }
            .disabled(sending)
            .shipKitDismissesKeyboard()
            .navigationTitle(L("requests.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button(L("requests.new.submit"), action: submit).disabled(!canSubmit)
                    }
                }
            }
            .alert(L("feedback.error.title"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button(L("common.ok"), role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .shipKitTint()
    }

    private func submit() {
        guard canSubmit, let engine = ShipKit.engine else { return }
        sending = true
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = self.details.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let created = try await engine.createRequest(title: title, description: details, email: trimmedEmail.isEmpty ? nil : trimmedEmail)
                onCreated(created)
                dismiss()
            } catch {
                errorText = errorMessage(error)
            }
            sending = false
        }
    }
}
