#if !os(tvOS)
import SwiftUI

extension ShipKit {
    /// The user's feedback conversations. Push it inside a `NavigationStack`.
    public struct FeedbackInboxView: View {
        @State private var threads: [FeedbackThread] = []
        @State private var loaded = false
        @State private var errorText: String?

        public init() {}

        public var body: some View {
            List {
                if let errorText, threads.isEmpty {
                    ErrorBanner(message: errorText) { Task { await load() } }
                        .listRowBackground(Color.clear)
                } else if loaded, threads.isEmpty {
                    EmptyStateView(systemImage: "tray", title: L("inbox.empty.title"), message: L("inbox.empty.message"))
                        .listRowBackground(Color.clear)
                }
                ForEach(threads) { thread in
                    NavigationLink {
                        FeedbackThreadView(thread: thread) { updated in
                            if let index = threads.firstIndex(where: { $0.id == updated.id }) {
                                threads[index] = updated
                            }
                        }
                    } label: {
                        ThreadRow(thread: thread)
                    }
                }
            }
            .overlay {
                if !loaded, errorText == nil { ProgressView() }
            }
            .navigationTitle(L("inbox.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ShipKit.FeedbackView()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(L("inbox.new"))
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .shipKitTint()
        }

        private func load() async {
            guard let engine = ShipKit.engine else {
                errorText = L("error.generic")
                return
            }
            do {
                threads = try await engine.threads()
                errorText = nil
            } catch is CancellationError {
                return
            } catch {
                errorText = errorMessage(error)
            }
            loaded = true
        }
    }
}

private struct ThreadRow: View {
    let thread: FeedbackThread

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: thread.category.symbol)
                .font(.title3)
                .foregroundStyle(ShipKit.theme.primaryColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.category.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Formatting.relative(thread.updatedAt ?? thread.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(thread.preview)
                    .font(.subheadline)
                    .foregroundStyle(thread.unread > 0 ? .primary : .secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusChip(text: thread.status.title, color: thread.status == .resolved ? .green : .secondary)
                    if let fixedIn = thread.fixedIn {
                        StatusChip(text: L("inbox.fixedIn", fixedIn), color: .green)
                    }
                    Spacer()
                    CountBadge(count: thread.unread)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FeedbackThreadView: View {
    let thread: FeedbackThread
    let onUpdate: (FeedbackThread) -> Void

    @State private var current: FeedbackThread?
    @State private var messages: [FeedbackMessage] = []
    @State private var reply = ""
    @State private var sending = false
    @State private var loaded = false
    @State private var errorText: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let fixedIn = (current ?? thread).fixedIn {
                        Label(L("inbox.fixedIn.banner", fixedIn), systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.vertical, 6)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let errorText, messages.isEmpty {
                        ErrorBanner(message: errorText) { Task { await load() } }
                    }
                }
                .padding()
            }
            .overlay {
                if !loaded, errorText == nil { ProgressView() }
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .shipKitDismissesKeyboard()
        .navigationTitle((current ?? thread).category.title)
        .skInlineTitle()
        .task { await load() }
        .shipKitTint()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L("inbox.reply.placeholder"), text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.skSecondaryBackground))
                .focused($composerFocused)
            Button(action: send) {
                if sending {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
            }
            .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(L("inbox.reply.send"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .skBarBackground()
    }

    private func load() async {
        guard let engine = ShipKit.engine else { return }
        do {
            let (updated, loadedMessages) = try await engine.thread(thread.id)
            current = updated
            messages = loadedMessages
            errorText = nil
            onUpdate(updated)
            _ = await engine.refreshUnread()
        } catch is CancellationError {
            return
        } catch {
            errorText = errorMessage(error)
        }
        loaded = true
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine = ShipKit.engine else { return }
        sending = true
        Task {
            do {
                let message = try await engine.reply(threadID: thread.id, body: text)
                messages.append(message)
                reply = ""
            } catch {
                errorText = errorMessage(error)
            }
            sending = false
        }
    }
}

private struct MessageBubble: View {
    let message: FeedbackMessage

    private var isUser: Bool { message.author == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    Text(message.authorName ?? L("inbox.developer"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !message.body.isEmpty {
                    Text(message.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(isUser ? ShipKit.theme.userBubbleTextColor : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isUser ? ShipKit.theme.primaryColor : ShipKit.theme.developerBubbleColor)
                        )
                        .textSelection(.enabled)
                }
                ForEach(message.attachments) { attachment in
                    AttachmentImage(id: attachment.id)
                }
                Text(Formatting.relative(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}
#endif
