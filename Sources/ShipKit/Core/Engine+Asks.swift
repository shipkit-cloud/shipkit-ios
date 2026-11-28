import Foundation

struct AskState: Sendable {
    /// Asks this install has seen, newest last. The server knows too, but a "shown" report can wait offline.
    var seen: [String]
    /// Asks presented since launch, tests included, so one is never shown twice in a session.
    var presented: Set<String> = []
    /// One flush at a time, so an answer is never posted twice.
    var flushing = false

    init(preferences: Preferences, persistent: Bool) {
        seen = persistent ? (preferences.decode([String].self, .askSeen) ?? []) : []
    }
}

extension Engine {
    static let askSeenLimit = 50
    static let askOutboxLimit = 30

    /// The ask this install may be shown now, or `nil`. Never makes a request.
    func pendingAsk(now: Date = Date()) -> ShipKitAsk? {
        guard let ask = snapshot?.ask else { return nil }
        if let endsAt = ask.endsAt, endsAt <= now { return nil }
        if currentVersionStatus.isBlocking { return nil }
        let (seen, presented) = askState.withLock { (Set($0.seen), $0.presented) }
        if presented.contains(ask.id) { return nil }
        // A test from the dashboard shows even to an install that opted out or saw it before.
        if ask.isTest { return ask }
        guard pushAsksEnabled, !seen.contains(ask.id) else { return nil }
        return ask
    }

    func markAskShown(_ ask: ShipKitAsk) {
        let seen = askState.withLock { state -> [String]? in
            state.presented.insert(ask.id)
            guard !ask.isTest, !state.seen.contains(ask.id) else { return nil }
            state.seen = Array((state.seen + [ask.id]).suffix(Self.askSeenLimit))
            return state.seen
        }
        if let seen, configuration.persistent { preferences.encode(seen, .askSeen) }
        record(AskEvent(askID: ask.id, kind: .shown, at: Date(), test: ask.isTest, appVersion: runningVersionString))
    }

    func dismissAsk(_ ask: ShipKitAsk) {
        record(AskEvent(askID: ask.id, kind: .dismissed, at: Date(), test: ask.isTest, appVersion: runningVersionString))
    }

    /// Sends the answer. One that fails because the device is offline is kept and sent with the
    /// next refresh, so the user still sees it as sent.
    func answerAsk(_ ask: ShipKitAsk, answer: PushAnswer) async throws {
        let event = AskEvent(askID: ask.id, kind: .answered, at: Date(), test: ask.isTest, appVersion: runningVersionString, value: answer.value, text: answer.text)
        do {
            try await post(event, api: client())
        } catch let error as ShipKitError where error.isTransient && configuration.persistent {
            enqueue(event)
        }
    }

    var pendingAskEvents: [AskEvent] {
        preferences.decode([AskEvent].self, .askOutbox) ?? []
    }

    /// Sends what waited offline, oldest first. Stops at the first transient failure.
    func flushAskOutbox() async {
        guard configuration.persistent, configuration.networkEnabled else { return }
        guard !pendingAskEvents.isEmpty, askState.withLock({ state in
            defer { state.flushing = true }
            return !state.flushing
        }) else { return }
        defer { askState.withLock { $0.flushing = false } }
        let initial = pendingAskEvents
        var pending = initial
        while let event = pending.first {
            do {
                try await post(event, api: api)
            } catch let error as ShipKitError where error.isTransient {
                break
            } catch {
                // Rejected (the ask was deleted, or the answer no longer fits it); nothing to retry.
            }
            pending.removeFirst()
        }
        // Events recorded while this ran were appended to the stored list; keep them.
        let added = pendingAskEvents.filter { !initial.contains($0) }
        preferences.encode(Array((pending + added).suffix(Self.askOutboxLimit)), .askOutbox)
    }

    private func record(_ event: AskEvent) {
        guard configuration.networkEnabled else { return }
        guard configuration.persistent else {
            Task { try? await post(event, api: api) }
            return
        }
        enqueue(event)
        Task { await flushAskOutbox() }
    }

    private func enqueue(_ event: AskEvent) {
        let pending = pendingAskEvents.filter { $0 != event } + [event]
        preferences.encode(Array(pending.suffix(Self.askOutboxLimit)), .askOutbox)
    }

    private func post(_ event: AskEvent, api: APIClient) async throws {
        let at = ISO8601.string(from: event.at)
        let path = "v1/asks/\(event.askID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.askID)"
        switch event.kind {
        case .shown, .dismissed:
            try await api.perform("POST", "\(path)/events", body: AskEventBody(event: event.kind.rawValue, at: at, test: event.test, appVersion: event.appVersion))
        case .answered:
            var context = makeContext()
            if let version = event.appVersion { context.appVersion = version }
            try await api.perform("POST", "\(path)/answer", body: AskAnswerBody(value: event.value, text: event.text, at: at, test: event.test, context: context))
        }
    }
}
