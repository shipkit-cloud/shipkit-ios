#if !os(tvOS)
import SwiftUI

extension ShipKit {
    /// The in-app ask waiting for this install, or `nil`. Read from the cached snapshot: it never
    /// makes a request and never shows anything.
    ///
    /// Use it to draw your own entry point, such as a "We have a question" row, and call
    /// `presentPendingAsk(showsInvite: false)` when it's tapped.
    @MainActor
    public static var pendingAsk: ShipKitAsk? {
        engine?.pendingAsk()
    }

    /// Shows the pending in-app ask as a sheet and returns once the user is done with it.
    ///
    /// ShipKit never calls this itself. Call it at a moment that suits your app, such as after the
    /// user finished a task, not while they're in the middle of one. It returns `.notShown` right
    /// away when nothing is pending, the user turned off questions from the developer, a version
    /// rule blocks the app, or another sheet from ShipKit is on screen. Each install is asked a
    /// given question once; "Not now" counts.
    ///
    /// - Parameter showsInvite: Pass `false` when the user already tapped something of yours to
    ///   get here, to skip the "Got a minute?" step and open the question directly.
    @MainActor
    @discardableResult
    public static func presentPendingAsk(showsInvite: Bool = true) async -> ShipKitAskResult {
        await AskPresenter.shared.present(showsInvite: showsInvite)
    }
}

/// Same switch as `ShipKitPushAsksToggle`: it turns off push questions and in-app asks alike.
/// Use whichever name reads better in an app that has no push campaigns.
public typealias ShipKitAsksToggle = ShipKitPushAsksToggle

extension View {
    /// Shows the pending in-app ask when this view appears, and again when `isActive` turns `true`
    /// while it's on screen. Placing the modifier is how your app picks the moment: an ask that
    /// arrives while the view is already showing waits for the next time.
    ///
    /// ```swift
    /// OrderConfirmationView()
    ///     .shipKitAsk()
    /// ```
    ///
    /// - Parameters:
    ///   - isActive: Set to `false` while the screen is busy (loading, editing) to hold the ask back.
    ///   - onFinish: Called with how the ask ended, or `.notShown` when there was nothing to show.
    public func shipKitAsk(isActive: Bool = true, onFinish: (@MainActor (ShipKitAskResult) -> Void)? = nil) -> some View {
        modifier(ShipKitAskModifier(isActive: isActive, onFinish: onFinish))
    }
}

struct ShipKitAskModifier: ViewModifier {
    let isActive: Bool
    let onFinish: (@MainActor (ShipKitAskResult) -> Void)?
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { schedule() }
            .onDisappear {
                task?.cancel()
                task = nil
            }
            .onChange(of: isActive) { active in
                if active { schedule() }
            }
    }

    private func schedule() {
        guard isActive, task == nil else { return }
        task = Task { @MainActor in
            // Let the screen's own transition finish; a sheet presented during it gets dropped.
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled, isActive {
                let result = await ShipKit.presentPendingAsk()
                onFinish?(result)
            }
            task = nil
        }
    }
}

/// Presents one ask at a time over the top-most screen and reports how it ended.
@MainActor
final class AskPresenter {
    static let shared = AskPresenter()
    private var active: String?

    func present(showsInvite: Bool) async -> ShipKitAskResult {
        guard let engine = ShipKit.engine, let ask = engine.pendingAsk(), active == nil else { return .notShown }
        let model = ShipKitModel.shared
        guard !model.gateSheetVisible, model.pendingPush == nil, PlatformApp.isActive, let host = PushPresenter.topViewController() else {
            return .notShown
        }
        active = ask.id
        defer { active = nil }
        return await withCheckedContinuation { continuation in
            let finish = Once<ShipKitAskResult> { continuation.resume(returning: $0) }
            PushPresenter.present(compact: showsInvite, from: host) { expand in
                AskSheet(ask: ask, showsInvite: showsInvite, expand: expand, finish: finish.call)
            }
        }
    }
}

/// Calls its block once, however often it's asked to.
@MainActor
final class Once<Value> {
    private var block: ((Value) -> Void)?
    init(_ block: @escaping (Value) -> Void) { self.block = block }
    func call(_ value: Value) {
        block?(value)
        block = nil
    }
}

/// "Got a minute?" with Take part / Not now, then the question or the feedback form.
struct AskSheet: View {
    private enum Phase { case invite, answer }

    let ask: ShipKitAsk
    let expand: @MainActor () -> Void
    let finish: @MainActor (ShipKitAskResult) -> Void
    @State private var phase: Phase
    @State private var answered = false
    @Environment(\.dismiss) private var dismiss

    init(ask: ShipKitAsk, showsInvite: Bool, expand: @escaping @MainActor () -> Void, finish: @escaping @MainActor (ShipKitAskResult) -> Void) {
        self.ask = ask
        self.expand = expand
        self.finish = finish
        _phase = State(initialValue: showsInvite ? .invite : .answer)
    }

    var body: some View {
        // A ZStack, not a Group: a Group would pass onAppear/onDisappear to each phase.
        ZStack {
            switch phase {
            case .invite: invite
            case .answer: answer
            }
        }
        .shipKitTint()
        .onAppear { ShipKit.engine?.markAskShown(ask) }
        .onDisappear {
            if !answered { ShipKit.engine?.dismissAsk(ask) }
            finish(answered ? .answered : .dismissed)
        }
    }

    private var invite: some View {
        VStack(spacing: 14) {
            Image(systemName: ask.kind == .feedback ? "bubble.left.and.text.bubble.right" : "questionmark.bubble")
                .font(.system(size: 40))
                .foregroundStyle(ShipKit.theme.primaryColor)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Text(ask.title ?? L("ask.invite.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(ask.body ?? L(ask.kind == .feedback ? "ask.invite.body.feedback" : "ask.invite.body"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("ask.invite.accept")) {
                expand()
                withAnimation { phase = .answer }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button(L("ask.invite.decline")) { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(ShipKit.theme.primaryColor)
                .padding(.vertical, 6)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var answer: some View {
        switch ask.kind {
        case .question:
            PushQuestionSheet(payload: ask.payload) { answer in
                guard let engine = ShipKit.engine else { throw ShipKitError.notConfigured }
                try await engine.answerAsk(ask, answer: answer)
                answered = true
            }
        case .feedback:
            FeedbackSheet(category: .idea, prompt: ask.feedbackPrompt, ask: ask) { answered = true }
        }
    }
}

extension ShipKitAsk {
    /// The question in the form the question sheet takes.
    var payload: PushPayload {
        var payload = PushPayload(object: ["c": id, "kind": "question"])
        payload.title = title
        payload.body = body
        if let question {
            payload.question = PushQuestion(prompt: question.prompt, type: PushQuestion.Kind(rawValue: question.type.rawValue), choices: question.choices)
        }
        return payload
    }
}
#endif
